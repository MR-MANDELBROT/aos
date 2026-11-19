// High performance video from libsharing for Android's MediaCodec (third_party/README.md, "High performance"): the
// stream's parameter sets become the decoder's codec specific data, its length-prefixed access units Annex B. Written
// for aOS's Android app on 2026-11-19 after Open Screen Sharing's VideoDecoder (GPL-3.0, nekohasekai).

package dev.marquart.aos.screen

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
}
