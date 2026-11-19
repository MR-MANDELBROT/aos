package dev.marquart.aos.screen

import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** libsharing's high performance stream for MediaCodec: Annex B units, codec specific data, timestamps. */
class VideoTests {
    private fun b(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    @Test fun lengthPrefixedUnitsBecomeAnnexBInPlace() {
        // Two NAL units: 3 bytes and 2 bytes, each after a 4-byte big-endian length
        val data = b(0, 0, 0, 3, 0x65, 0x88, 0x84, 0, 0, 0, 2, 0x41, 0x9a)
        assertTrue(VideoStream.toAnnexB(data))
        assertContentEquals(b(0, 0, 0, 1, 0x65, 0x88, 0x84, 0, 0, 0, 1, 0x41, 0x9a), data)
    }

    @Test fun aLengthPastTheEndIsABrokenUnit() {
        assertFalse(VideoStream.toAnnexB(b(0, 0, 0, 9, 1, 2)))
        assertFalse(VideoStream.toAnnexB(b(0, 0, 0, 1, 7, 0, 0)))
        assertTrue(VideoStream.toAnnexB(ByteArray(0)))
    }

    @Test fun h264HasItsSPSAndPPSInTwoBuffers() {
        val sps = b(0x67, 0x42, 0xc0, 0x1f)
        val pps = b(0x68, 0xce, 0x3c, 0x80)
        val csd = VideoStream.codecSpecificData(VideoCodec.H264, listOf(sps, pps))
        assertEquals(2, csd.size)
        assertContentEquals(b(0, 0, 0, 1, 0x67, 0x42, 0xc0, 0x1f), csd[0])
        assertContentEquals(b(0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80), csd[1])
        assertEquals(7, VideoStream.nalType(VideoCodec.H264, sps))
    }

    @Test fun hevcHasVPSSPSAndPPSInOneBuffer() {
        val vps = b(0x40, 0x01, 0x0c)
        val sps = b(0x42, 0x01, 0x01)
        val pps = b(0x44, 0x01, 0xc1)
        val csd = VideoStream.codecSpecificData(VideoCodec.HEVC, listOf(vps, sps, pps))
        assertEquals(1, csd.size)
        assertContentEquals(b(0, 0, 0, 1, 0x40, 0x01, 0x0c, 0, 0, 0, 1, 0x42, 0x01, 0x01, 0, 0, 0, 1, 0x44, 0x01, 0xc1), csd[0])
        assertEquals(listOf(32, 33, 34), listOf(vps, sps, pps).map { VideoStream.nalType(VideoCodec.HEVC, it) })
    }

    @Test fun timestampsAreInTheStreamsClock() {
        assertEquals(1_000_000L, VideoStream.presentationTimeUs(24_000, 24_000))
        // A continuous 64-bit count far into a session doesn't overflow
        assertEquals(10_000_000_000_000_500L, VideoStream.presentationTimeUs(240_000_000_000_012L, 24_000))
        assertEquals(0L, VideoStream.presentationTimeUs(5, 0))
    }

    @Test fun formatsCompareByTheirParameterSets() {
        val a = VideoFormatInfo(VideoCodec.HEVC, listOf(b(1, 2), b(3)), 1080, 1, false)
        assertEquals(a, VideoFormatInfo(VideoCodec.HEVC, listOf(b(1, 2), b(3)), 1080, 1, false))
        assertFalse(a == VideoFormatInfo(VideoCodec.HEVC, listOf(b(1, 2), b(4)), 1080, 1, false))
    }
}
