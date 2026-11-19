// High performance video from libsharing for Android's MediaCodec (third_party/README.md, "High performance"): the
// stream's parameter sets become the decoder's codec specific data, its length-prefixed access units Annex B. Written
// for aOS's Android app on 2026-11-19 after Open Screen Sharing's VideoDecoder (GPL-3.0, nekohasekai).

package dev.marquart.aos.screen

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentLinkedQueue

enum class VideoCodec(val mime: String) {
    HEVC("video/hevc"), H264("video/avc");
}

/** What `onVideoFormat` said: the codec, its parameter sets (raw NAL units), the canvas height, chroma, HDR. */
data class VideoFormatInfo(
    val codec: VideoCodec,
    val parameterSets: List<ByteArray>,
    val height: Int,
    val chromaFormat: Int,
    val hdr: Boolean,
) {
    override fun equals(other: Any?): Boolean = other is VideoFormatInfo && codec == other.codec && height == other.height &&
        chromaFormat == other.chromaFormat && hdr == other.hdr && parameterSets.size == other.parameterSets.size &&
        parameterSets.indices.all { parameterSets[it].contentEquals(other.parameterSets[it]) }

    override fun hashCode(): Int = codec.hashCode() * 31 + height
}

/** One access unit: length-prefixed NAL units (converted to Annex B in place when it is queued). */
class VideoUnit(
    val data: ByteArray,
    val timestamp: Long,
    val clockRate: Int,
    val sync: Boolean,
    val discontinuity: Boolean,
)

object VideoStream {
    private val startCode = byteArrayOf(0, 0, 0, 1)

    /**
     * Replaces each 4-byte big-endian NAL length with the start code 00 00 00 01, in place (same size, one pass).
     * False when a length runs past the end (a broken unit).
     */
    fun toAnnexB(data: ByteArray): Boolean {
        var i = 0
        while (i + 4 <= data.size) {
            val n = (data[i].toInt() and 0xff shl 24) or (data[i + 1].toInt() and 0xff shl 16) or
                (data[i + 2].toInt() and 0xff shl 8) or (data[i + 3].toInt() and 0xff)
            if (n < 0 || i + 4L + n > data.size) return false
            data[i] = 0; data[i + 1] = 0; data[i + 2] = 0; data[i + 3] = 1
            i += 4 + n
        }
        return i == data.size
    }

    /** NAL unit type of a raw NAL unit. */
    fun nalType(codec: VideoCodec, nal: ByteArray): Int = if (nal.isEmpty()) -1 else when (codec) {
        VideoCodec.HEVC -> (nal[0].toInt() shr 1) and 0x3f
        VideoCodec.H264 -> nal[0].toInt() and 0x1f
    }

    /**
     * MediaCodec's codec specific data: HEVC one buffer with VPS, SPS and PPS; H.264 `csd-0` the SPS and `csd-1` the
     * PPS; each NAL unit after a start code.
     */
    fun codecSpecificData(codec: VideoCodec, parameterSets: List<ByteArray>): List<ByteArray> = when (codec) {
        VideoCodec.HEVC -> listOf(joined(parameterSets))
        VideoCodec.H264 -> {
            val sps = parameterSets.filter { nalType(codec, it) == 7 }
            val pps = parameterSets.filter { nalType(codec, it) == 8 }
            if (sps.isEmpty() || pps.isEmpty()) listOf(joined(parameterSets)) else listOf(joined(sps), joined(pps))
        }
    }

    private fun joined(units: List<ByteArray>): ByteArray {
        val out = ByteArray(units.sumOf { it.size + 4 })
        var at = 0
        for (unit in units) {
            startCode.copyInto(out, at)
            unit.copyInto(out, at + 4)
            at += unit.size + 4
        }
        return out
    }

    fun presentationTimeUs(timestamp: Long, clockRate: Int): Long {
        if (clockRate <= 0) return 0
        // Exact for the whole 64-bit count (a double loses microseconds after a few days of ticks)
        return timestamp / clockRate * 1_000_000 + timestamp % clockRate * 1_000_000 / clockRate
    }

    /** Libsharing's decoder codec bits for what this phone decodes in hardware. */
    fun hardwareCodecs(): Set<VideoCodec> = try {
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { !it.isEncoder && (android.os.Build.VERSION.SDK_INT < 29 || it.isHardwareAccelerated) }
            .flatMap { info -> info.supportedTypes.mapNotNull { type -> VideoCodec.entries.firstOrNull { it.mime.equals(type, true) } } }
            .toSet()
    } catch (_: Exception) {
        emptySet()
    }

    /** Pixels a second the best hardware decoder manages for the codec (0: not known). */
    fun maximumPixelRate(): Long = try {
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { !it.isEncoder && it.isHardwareAccelerated }
            .flatMap { info -> info.supportedTypes.filter { it.equals(VideoCodec.HEVC.mime, true) || it.equals(VideoCodec.H264.mime, true) }.map { info.getCapabilitiesForType(it) } }
            .mapNotNull { caps -> caps.videoCapabilities?.let { v ->
                val w = v.supportedWidths.upper.coerceAtMost(3840)
                val h = v.getSupportedHeightsFor(w).upper.coerceAtMost(2160)
                (v.getSupportedFrameRatesFor(w, h).upper * w * h).toLong()
            } }
            .maxOrNull() ?: 0L
    } catch (_: Exception) {
        0L
    }
}

/**
 * Decodes the high performance stream onto a Surface (the renderer's SurfaceTexture) with MediaCodec in its
 * asynchronous mode. Formats and units come from libsharing's media thread and are only queued there; the codec runs
 * on its own thread. After a new format, a discontinuity or a decoder error it waits for a sync unit (and asks for a
 * keyframe).
 */
class VideoDecoder(
    private val onSize: (width: Int, height: Int) -> Unit,
    private val requestKeyframe: () -> Unit,
    /** The decoder can't go on (no decoder for the codec, failures in a row): fall back to standard mode. */
    private val onFailure: (String) -> Unit,
) {
    private val thread = HandlerThread("aos-video").apply { start() }
    private val handler = Handler(thread.looper)
    private val pending = ConcurrentLinkedQueue<VideoUnit>()
    private val freeInputs = ArrayDeque<Int>()
    private var codec: MediaCodec? = null
    private var format: VideoFormatInfo? = null
    private var surface: Surface? = null
    private var needsSync = true
    private var failures = ArrayDeque<Long>()
    private var released = false
    @Volatile var framesDecoded = 0L
        private set

    fun setSurface(newSurface: Surface?) = handler.post {
        if (released) return@post
        val old = surface
        surface = newSurface
        val c = codec
        when {
            newSurface == null -> stopCodec()
            c != null && old != null -> try {
                c.setOutputSurface(newSurface)
            } catch (e: Exception) {
                stopCodec()
                configure()
            }
            else -> configure()
        }
    }

    /** A (new) stream format: the decoder is set up again. */
    fun format(info: VideoFormatInfo) = handler.post {
        if (released || info == format && codec != null) return@post
        format = info
        stopCodec()
        configure()
    }

    fun unit(unit: VideoUnit) {
        if (released) return
        if (pending.size > 120) pending.clear().also { handler.post { needsSync = true; requestKeyframe() } }
        pending.add(unit)
        handler.post { feed() }
    }

    fun release() {
        released = true
        handler.post {
            stopCodec()
            thread.quitSafely()
        }
    }

    private fun configure() {
        val info = format ?: return
        val out = surface ?: return
        val c = try {
            MediaCodec.createDecoderByType(info.codec.mime)
        } catch (e: Exception) {
            onFailure("no ${info.codec.mime} decoder: ${e.message}")
            return
        }
        val media = MediaFormat.createVideoFormat(info.codec.mime, 1920, info.height.coerceAtLeast(16))
        VideoStream.codecSpecificData(info.codec, info.parameterSets).forEachIndexed { i, csd ->
            media.setByteBuffer("csd-$i", ByteBuffer.wrap(csd))
        }
        media.setInteger(MediaFormat.KEY_PRIORITY, 0)
        media.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        c.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                if (codec !== this@VideoDecoder.codec) return
                freeInputs.addLast(index)
                feed()
            }

            override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                if (codec !== this@VideoDecoder.codec) return
                try {
                    codec.releaseOutputBuffer(index, info.size > 0)
                    if (info.size > 0) framesDecoded++
                } catch (_: IllegalStateException) {
                }
            }

            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                if (codec !== this@VideoDecoder.codec) return
                Log.w(TAG, "decoder error: ${e.diagnosticInfo}")
                failed("decoder error ${e.errorCode}")
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                val w = if (format.containsKey("crop-right")) format.getInteger("crop-right") - format.getInteger("crop-left") + 1
                else format.getInteger(MediaFormat.KEY_WIDTH)
                val h = if (format.containsKey("crop-bottom")) format.getInteger("crop-bottom") - format.getInteger("crop-top") + 1
                else format.getInteger(MediaFormat.KEY_HEIGHT)
                onSize(w, h)
            }
        }, handler)
        try {
            c.configure(media, out, null, 0)
            c.start()
        } catch (e: Exception) {
            c.release()
            failed("configure: ${e.message}")
            return
        }
        codec = c
        freeInputs.clear()
        needsSync = true
        requestKeyframe()
    }

    private fun feed() {
        val c = codec ?: run {
            // Without a decoder (no surface yet): only the newest units matter, from a sync unit on.
            while (pending.size > 30) pending.poll()
            return
        }
        while (freeInputs.isNotEmpty()) {
            val unit = pending.poll() ?: return
            if (unit.discontinuity && !needsSync) {
                needsSync = true
                requestKeyframe()
            }
            if (needsSync && !unit.sync) continue
            if (!VideoStream.toAnnexB(unit.data)) {
                needsSync = true
                requestKeyframe()
                continue
            }
            needsSync = false
            val index = freeInputs.removeFirst()
            try {
                val buffer = c.getInputBuffer(index) ?: continue
                buffer.clear()
                if (unit.data.size > buffer.capacity()) {
                    freeInputs.addFirst(index)
                    needsSync = true
                    requestKeyframe()
                    continue
                }
                buffer.put(unit.data)
                c.queueInputBuffer(index, 0, unit.data.size, VideoStream.presentationTimeUs(unit.timestamp, unit.clockRate),
                    if (unit.sync) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            } catch (e: Exception) {
                failed("queue: ${e.message}")
                return
            }
        }
    }

    private fun failed(reason: String) {
        val now = SystemClock.elapsedRealtime()
        failures.addLast(now)
        while (failures.isNotEmpty() && now - failures.first() > 10_000) failures.removeFirst()
        stopCodec()
        if (failures.size >= 3) {
            onFailure(reason)
            return
        }
        configure()
    }

    private fun stopCodec() {
        val c = codec ?: return
        codec = null
        freeInputs.clear()
        try {
            c.stop()
        } catch (_: Exception) {
        }
        c.release()
    }

    companion object {
        private const val TAG = "aos-screen"
    }
}

/** Codec capabilities for libsharing's HighPerformanceOptions. */
object DecoderSupport {
    val codecs: Set<VideoCodec> by lazy { VideoStream.hardwareCodecs() }
    val maximumPixelRate: Long by lazy { VideoStream.maximumPixelRate() }
    fun profileLevels(codec: VideoCodec): Array<MediaCodecInfo.CodecProfileLevel> = try {
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { !it.isEncoder }
            .flatMap { i -> i.supportedTypes.filter { it.equals(codec.mime, true) }.flatMap { i.getCapabilitiesForType(it).profileLevels.toList() } }
            .toTypedArray()
    } catch (_: Exception) {
        emptyArray()
    }
}
