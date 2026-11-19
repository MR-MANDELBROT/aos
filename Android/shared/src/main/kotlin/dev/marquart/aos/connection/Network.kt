package dev.marquart.aos.connection

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow
import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream

// The interfaces the connection to the Mac needs from the platform. Android implementations: AndroidNetwork.kt
// (ConnectivityManager, NsdManager). Tests: plain fakes. aOS's own Tailscale node: `TailnetDialer`, implemented by the
// tailnet module (third_party/, Go) later.

/**
 * aOS's own Tailscale node in this app (the "aos" way, Docs/COMPANION.md "Connecting"): it listens on nothing; the app
 * dials the Mac's tailnet address through it and gets a connected byte stream, which carries the SSH connection (the
 * Mac's host key is checked the same way as on any other route).
 *
 * The tailnet module implements this (gomobile or a C library, like iOS's Tailnetkit: a dial returns one end of a socket
 * pair). Until then the app uses `NoTailnet`.
 */
interface TailnetDialer {
    /** The node is set up (signed in once); for the hints when the Mac isn't reachable. */
    val isSetUp: Boolean

    /** The node runs now and can dial. */
    val isRunning: Boolean

    /** Emits each time the node becomes ready: the Mac connection tries again at once. */
    val ready: Flow<Unit>

    /** Starts the node if it is set up (the app came to the foreground, the connection starts). */
    fun startIfSetUp() {}

    /** A TCP connection to `host:port` (a tailnet address or MagicDNS name) through the node. Throws when it fails. */
    suspend fun dial(host: String, port: Int, timeoutMillis: Long): TailnetConnection
}

/** One connection through the tailnet: a byte stream in each direction. Closing it ends the connection. */
interface TailnetConnection : Closeable {
    val input: InputStream
    val output: OutputStream
}

/** No node of aOS's own in this app (yet): tailnet routes through it are left out. */
object NoTailnet : TailnetDialer {
    override val isSetUp = false
    override val isRunning = false
    override val ready: Flow<Unit> = emptyFlow()
    override suspend fun dial(host: String, port: Int, timeoutMillis: Long): TailnetConnection =
        throw java.io.IOException("aOS's Tailscale isn't set up on this phone")
}

/** The phone's network as far as the connection cares. */
data class NetworkPath(
    /** There is a network that reaches anything at all. */
    val satisfied: Boolean,
    /** Which one (Wi-Fi, cellular, which interface): a change means the connection may be dead. */
    val interfaceId: String?,
)

interface NetworkMonitor {
    val path: StateFlow<NetworkPath>

    /** The Tailscale app's VPN is on: a VPN interface with an address in 100.64.0.0/10 or fd7a:115c:a1e0::/48. */
    fun tailscaleVpnActive(): Boolean

    fun start() {}
    fun stop() {}
}

/** A network that never changes (tests). */
class FixedNetworkMonitor(path: NetworkPath = NetworkPath(true, "test"), private val vpn: Boolean = false) : NetworkMonitor {
    override val path = MutableStateFlow(path)
    override fun tailscaleVpnActive() = vpn
}

/** A service found over NSD (Bonjour) and resolved. */
data class ResolvedService(val name: String, val host: String, val port: Int)

/** Bonjour/NSD: the Mac's pairing listener (`_aos-pair._tcp`) and its SSH server (`_ssh._tcp`). */
interface ServiceDiscovery {
    /**
     * Browses `type` for up to `timeoutMillis` and resolves the service named `name` (as soon as it shows up), or, when
     * none has that name and `orOnlyOne` is set, the only one found. Null when nothing fits.
     */
    suspend fun find(type: String, name: String?, timeoutMillis: Long, orOnlyOne: Boolean = true): ResolvedService?
}

/** No discovery (tests, or where NSD isn't available). */
object NoDiscovery : ServiceDiscovery {
    override suspend fun find(type: String, name: String?, timeoutMillis: Long, orOnlyOne: Boolean): ResolvedService? = null
}
