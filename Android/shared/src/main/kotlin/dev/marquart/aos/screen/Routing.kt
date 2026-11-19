// Where a screen is reached and in what size: aOS's routing (iOS/Sources/Screen/ScreenSession.swift, DirectPath.swift)
// and the display sizes (Open Screen Sharing's VirtualDisplayMode, GPL-3.0, nekohasekai; AOSRFB's DisplayRequest).
// Written for aOS's Android app on 2026-11-19.

package dev.marquart.aos.screen

import dev.marquart.aos.core.SSHRoute
import dev.marquart.aos.core.ScreenTarget
import dev.marquart.aos.core.TailnetAddress
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** A display size in points and its pixels per point (OSS's VirtualDisplayMode). */
data class DisplayMode(val width: Int, val height: Int, val density: Int) {
    val pixelWidth: Int get() = width * density
    val pixelHeight: Int get() = height * density

    fun alignedToWidthMultiple(multiple: Int): DisplayMode {
        if (multiple <= 1) return this
        var mode = this
        while (mode.pixelWidth % multiple != 0 && mode.width > 1) mode = mode.copy(width = mode.width - 1)
        return mode
    }

    companion object {
        const val MINIMUM_LONG_SIDE = 800.0
        const val MINIMUM_SHORT_SIDE = 525.0
        val resolutionScales = listOf(1.0, 1.25, 1.5, 1.75, 2.0)
        const val DEFAULT_RESOLUTION_SCALE = 1.0

        /**
         * The display for a picture area of `width` by `height` points (dp): the same shape, grown until the long side
         * has 800 and the short one 525 points, times the resolution; two pixels per point on a dense screen (screen
         * sharing asks for two, as macOS's own viewer does).
         */
        fun matching(width: Double, height: Double, screenScale: Double, resolutionScale: Double = 1.0): DisplayMode? {
            if (width < 1 || height < 1) return null
            val density = if (screenScale >= 2) 2 else 1
            val w = width * resolutionScale
            val h = height * resolutionScale
            val grow = max(1.0, max(MINIMUM_LONG_SIDE / max(w, h), MINIMUM_SHORT_SIDE / min(w, h)))
            return DisplayMode(floor(w * grow + 0.001).toInt(), floor(h * grow + 0.001).toInt(), density)
        }

        /** The largest side a virtual display may get on this screen (the area at the highest resolution). */
        fun largestSide(width: Double, height: Double, screenScale: Double): Int =
            matching(width, height, screenScale, resolutionScales.last())?.let { max(it.pixelWidth, it.pixelHeight) } ?: 0

        /** "Native", "1.25×", as OSS names them. */
        fun resolutionTitle(scale: Double, native: String): String =
            if (scale == 1.0) native else String.format(Locale.ROOT, "%s×", scale.toBigDecimal().stripTrailingZeros().toPlainString())
    }
}

/** The workspace's display as aOS's `display` request carries it ("1200x2400@2"): AOSRFB's DisplayRequest. */
data class DisplayRequest(val width: Int, val height: Int, val scale: Int) {
    override fun toString() = "${width}x$height@$scale"

    /** Within what the workspace takes: even pixel counts, no side above 4096 pixels, the shape kept. */
    fun clamped(): DisplayRequest {
        var w = max(width, 1).toDouble()
        var h = max(height, 1).toDouble()
        val s = if (scale == 2) 2 else 1
        val largest = MAXIMUM_PIXELS.toDouble()
        if (max(w, h) > largest) {
            val f = largest / max(w, h)
            w *= f
            h *= f
        }
        val minimum = 320.0 * s
        w = max(w, minimum)
        h = max(h, minimum)
        return DisplayRequest((w / 2).toInt() * 2, (h / 2).toInt() * 2, s)
    }

    companion object {
        const val MAXIMUM_PIXELS = 4096

        /** The workspace's display for a picture area: sized as OSS sizes the Mac's virtual display. */
        fun forArea(area: ScreenArea): DisplayRequest? =
            DisplayMode.matching(area.width, area.height, area.screenScale, area.resolutionScale)
                ?.let { DisplayRequest(it.pixelWidth, it.pixelHeight, it.density).clamped() }
    }
}

/** The area a session shows its picture in: dp, the screen's pixels per dp, the resolution scale. */
data class ScreenArea(val width: Double, val height: Double, val screenScale: Double, val resolutionScale: Double)

/** How a session reaches its screen. */
sealed class ScreenPath {
    /** Through the SSH connection: standard mode, TCP only. */
    data object Tunnel : ScreenPath()

    /** Straight to the Mac's screen sharing at its address: high performance with the virtual display. */
    data class Direct(val host: String, val network: ScreenNetwork) : ScreenPath()

    val isDirect: Boolean get() = this is Direct
}

/** OSS's network quality on the direct path: the same network, or the internet (a tailnet). */
enum class ScreenNetwork { LOCAL_NETWORK, INTERNET }

/** The direct path to the Mac's screen sharing (iOS/Sources/Screen/DirectPath.swift). */
object DirectPath {
    const val SCREEN_SHARING_PORT = 5900

    sealed class Candidate {
        data class Address(val host: String) : Candidate()
        /** SSH doesn't reach an address in a network (a relay on this phone, for example). */
        data object NoAddress : Candidate()
        /** SSH goes through aOS's own Tailscale node and the Tailscale app's VPN is off. */
        data object TailnetWithoutVpn : Candidate()
    }

    /** Where to try the Mac directly: the address SSH reached by its way (`remote`: the address it connected to). */
    fun candidate(route: SSHRoute, remote: String?, tailnetHosts: List<String>, systemVpn: Boolean): Candidate = when (route) {
        is SSHRoute.Tailnet -> if (!systemVpn) Candidate.TailnetWithoutVpn
            else Candidate.Address(tailnetHosts.firstOrNull { TailnetAddress.isTailnetIPv4(it) } ?: route.host)
        is SSHRoute.Host -> when {
            remote != null && usable(remote) -> Candidate.Address(remote)
            usable(route.host) -> Candidate.Address(route.host)
            else -> Candidate.NoAddress
        }
        is SSHRoute.Bonjour -> if (remote != null && usable(remote)) Candidate.Address(remote) else Candidate.NoAddress
    }

    /** An address libsharing can dial: not this phone, a link-local IPv6 address only with its interface. */
    private fun usable(host: String): Boolean = host.isNotEmpty() && !isLoopback(host) && !(isLinkLocalIPv6(host) && '%' !in host)

    fun isLinkLocalIPv6(host: String): Boolean {
        val bare = host.substringBefore('%')
        if (':' !in bare) return false
        val first = bare.substringBefore(':').ifEmpty { return false }.toIntOrNull(16) ?: return false
        return first and 0xffc0 == 0xfe80
    }

    fun isLoopback(host: String): Boolean {
        val h = host.lowercase(Locale.ROOT)
        if (h == "localhost") return true
        val v4 = h.split('.')
        if (v4.size == 4 && v4.all { it.toIntOrNull() in 0..255 }) return v4[0] == "127"
        if (':' in h) return h.substringBefore('%').let { it == "::1" || it == "0:0:0:0:0:0:0:1" }
        return false
    }

    /** The tailnet counts as the internet (one band, 4:2:0), everything else as the local network. */
    fun network(host: String): ScreenNetwork = if (TailnetAddress.isTailnetHost(host)) ScreenNetwork.INTERNET else ScreenNetwork.LOCAL_NETWORK

    /** Whether the Mac answers on `host:port` within `timeoutMillis` (a TCP connection, closed right away). Blocks. */
    fun reachable(host: String, port: Int, timeoutMillis: Int = 1500): Boolean = try {
        Socket().use { it.connect(InetSocketAddress(host, port), timeoutMillis); true }
    } catch (_: Exception) {
        false
    }

    /** The IP address a host name or literal stands for (no lookup for literals). */
    fun literal(host: String): String? = try {
        val address = InetAddress.getByName(host.substringBefore('%'))
        when (address) {
            is Inet4Address -> address.hostAddress
            is Inet6Address -> address.hostAddress?.substringBefore('%')?.let { if ('%' in host) it + "%" + host.substringAfter('%') else it }
            else -> null
        }
    } catch (_: Exception) {
        null
    }
}

/** Why the Mac went through SSH although the phone's size was wanted (the card says so). */
enum class TunnelReason { NO_ADDRESS, TAILNET_WITHOUT_VPN, UNREACHABLE, NO_HIGH_PERFORMANCE, FAILED }

/** Stable ids for a paired Mac's two screens (what a session remembers is kept under them, and the last pictures). */
object ScreenIds {
    fun of(target: ScreenTarget, macId: String): String = named("${target.raw}\n$macId")

    /** A name-based UUID (SHA-256, version 5 style), the same derivation as the iPhone's. */
    fun named(name: String): String {
        val bytes = MessageDigest.getInstance("SHA-256").digest("aos-screen\n$name".toByteArray()).copyOf(16)
        bytes[6] = ((bytes[6].toInt() and 0x0f) or 0x50).toByte()
        bytes[8] = ((bytes[8].toInt() and 0x3f) or 0x80).toByte()
        var msb = 0L
        var lsb = 0L
        for (i in 0 until 8) msb = (msb shl 8) or (bytes[i].toLong() and 0xff)
        for (i in 8 until 16) lsb = (lsb shl 8) or (bytes[i].toLong() and 0xff)
        return UUID(msb, lsb).toString().uppercase(Locale.ROOT)
    }
}
