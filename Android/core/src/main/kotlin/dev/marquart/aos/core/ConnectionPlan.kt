package dev.marquart.aos.core

import kotlinx.serialization.Serializable
import java.net.Inet6Address
import java.net.InetAddress
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.UUID

/**
 * A Mac this phone is paired with. Nothing in it is secret (the pinned host key is public); it is kept in the app's
 * store. Field for field the iPhone's `PairedMac`.
 */
@Serializable
data class PairedMac(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    /** Names and addresses from the pairing code, tried in this order. */
    val hosts: List<String>,
    val sshPort: Int = 22,
    val user: String,
    /** The Mac's SSH host key (`ssh-ed25519 AAAA...`), pinned at pairing. */
    val hostKey: String,
    val hostKeyFingerprint: String,
    /** Path of `aos-companion` on the Mac. */
    val companionPath: String = CompanionCommand.DEFAULT_PATH,
    /** When it was paired, Unix milliseconds. */
    val pairedAt: Long = System.currentTimeMillis(),
    /** The address that worked last time; tried first. */
    val lastHost: String? = null,
    /** How the phone reaches the Mac on the go, from the pairing code (null: paired before the choice existed). */
    val way: String? = null,
    /** The Mac's tailnet addresses and names from the pairing code (`t`); older pairings: none. */
    val tailnetHosts: List<String>? = null,
    /** The tailnet the Mac is in. */
    val tailnetName: String? = null,
) {
    val reachWay: ReachWay? get() = ReachWay.from(way)

    /** The hosts in the order to try: the one that worked last time first. */
    val hostsToTry: List<String>
        get() = if (lastHost != null && lastHost in hosts) listOf(lastHost) + hosts.filter { it != lastHost } else hosts
}

/** Tailscale's address ranges and names (AOSKit `TailnetAddress`). */
object TailnetAddress {
    /** 100.64.0.0/10 (the shared address space Tailscale takes its IPv4 addresses from). */
    fun isTailnetIPv4(text: String): Boolean {
        val parts = text.split('.')
        if (parts.size != 4) return false
        val bytes = parts.map { p -> if (p.isEmpty() || p.length > 3 || !p.all(Char::isDigit)) return false else p.toInt() }
        if (bytes.any { it > 255 }) return false
        return bytes[0] == 100 && (bytes[1] and 0xC0) == 64
    }

    /** fd7a:115c:a1e0::/48 (Tailscale's IPv6 range). */
    fun isTailnetIPv6(text: String): Boolean {
        val bare = text.substringBefore('%')
        if (!bare.contains(':') || !bare.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' || it == ':' || it == '.' }) return false
        val address = try {
            InetAddress.getByName(bare)
        } catch (_: Exception) {
            return false
        }
        if (address !is Inet6Address) return false
        val b = address.address
        return b[0] == 0xfd.toByte() && b[1] == 0x7a.toByte() && b[2] == 0x11.toByte() && b[3] == 0x5c.toByte() &&
            b[4] == 0xa1.toByte() && b[5] == 0xe0.toByte()
    }

    /** A tailnet address, or a MagicDNS name (under ts.net or the tailnet's own suffix). */
    fun isTailnetHost(host: String, suffix: String? = null): Boolean {
        val lower = host.lowercase()
        if (isTailnetIPv4(lower) || isTailnetIPv6(lower)) return true
        if (lower.endsWith(".ts.net")) return true
        if (!suffix.isNullOrEmpty() && lower.endsWith("." + suffix.lowercase())) return true
        return false
    }
}

/** Where one SSH attempt to the Mac goes. */
sealed class SSHRoute {
    abstract val host: String

    /** A name or address over the phone's own network: the Mac's local addresses, or its tailnet addresses through the
     *  Tailscale app's VPN on this phone. */
    data class Host(override val host: String) : SSHRoute()

    /** A tailnet address or MagicDNS name, through aOS's own Tailscale node in this app (`TailnetDialer`). */
    data class Tailnet(override val host: String) : SSHRoute()

    /** The Mac's SSH server found over Bonjour/NSD (`_ssh._tcp`), by the Mac's name. */
    data class Bonjour(override val host: String) : SSHRoute()

    /** Through a tailnet (aOS's node, or the Tailscale app's VPN). */
    val isTailnet: Boolean
        get() = when (this) {
            is Tailnet -> true
            is Host -> TailnetAddress.isTailnetHost(host)
            is Bonjour -> false
        }
}

/**
 * The order the phone tries the Mac in (Docs/COMPANION.md, "Connecting"): the same network first (the address that
 * worked last time first among them), then the tailnet (aOS's own node in this app, then the Tailscale app's VPN), then
 * Bonjour. The attempts start one after the other, a moment apart, and the first complete SSH login wins.
 */
object ConnectionPlan {
    fun routes(mac: PairedMac, embeddedNode: Boolean, systemVPN: Boolean): List<SSHRoute> {
        val tailnet = tailnetHosts(mac)
        val local = mac.hosts.filter { host ->
            !TailnetAddress.isTailnetHost(host) && tailnet.none { it.equals(host, ignoreCase = true) }
        }.toMutableList()
        val last = mac.lastHost
        if (last != null) {
            val index = local.indexOf(last)
            if (index > 0) {
                local.removeAt(index)
                local.add(0, last)
            }
        }
        val routes = mutableListOf<SSHRoute>()
        local.mapTo(routes) { SSHRoute.Host(it) }
        if (embeddedNode) tailnet.mapTo(routes) { SSHRoute.Tailnet(it) }
        if (systemVPN) tailnet.mapTo(routes) { SSHRoute.Host(it) }
        routes += SSHRoute.Bonjour(mac.name)
        return routes
    }

    /** The Mac's tailnet hosts: from the pairing code, or for a Mac paired before it said so, the tailnet addresses and
     *  names among its hosts (IPv4 first). */
    fun tailnetHosts(mac: PairedMac): List<String> {
        mac.tailnetHosts?.takeIf { it.isNotEmpty() }?.let { return it }
        val found = mac.hosts.filter { TailnetAddress.isTailnetHost(it) }
        return found.filter(TailnetAddress::isTailnetIPv4) + found.filterNot(TailnetAddress::isTailnetIPv4)
    }
}

/** ISO 8601 dates with or without fractional seconds, as the Mac writes them. */
object Iso8601 {
    fun parse(text: String): Instant? = try {
        OffsetDateTime.parse(text, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant()
    } catch (_: Exception) {
        null
    }

    /** Whole seconds, UTC, `Z` (Swift's `ISO8601FormatStyle()`). */
    fun format(instant: Instant): String = DateTimeFormatter.ISO_INSTANT.format(instant.truncatedTo(ChronoUnit.SECONDS))
}
