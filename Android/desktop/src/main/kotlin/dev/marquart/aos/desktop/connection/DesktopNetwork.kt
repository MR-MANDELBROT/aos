package dev.marquart.aos.desktop.connection

import dev.marquart.aos.connection.NetworkMonitor
import dev.marquart.aos.connection.NetworkPath
import dev.marquart.aos.connection.ResolvedService
import dev.marquart.aos.connection.ServiceDiscovery
import dev.marquart.aos.core.TailnetAddress
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import javax.jmdns.JmDNS
import javax.jmdns.ServiceEvent
import javax.jmdns.ServiceListener
import kotlin.coroutines.resume

/**
 * The computer's network, polled (the JVM has no change notifications): the interfaces that are up with an address
 * that isn't loopback, link-local or a tailnet's. A change of that set is a new network for the connection (it checks
 * the Mac at once); none at all is "offline". The Tailscale app counts as on when an interface has a tailnet address
 * (100.64.0.0/10, fd7a:115c:a1e0::/48).
 */
class PollingNetworkMonitor(private val intervalMillis: Long = 3_000) : NetworkMonitor {
    private val _path = MutableStateFlow(read())
    override val path: StateFlow<NetworkPath> = _path
    private var job: Job? = null

    override fun start() {
        if (job != null) return
        job = CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            while (isActive) {
                delay(intervalMillis)
                val now = read()
                if (now != _path.value) _path.value = now
            }
        }
    }

    override fun stop() {
        job?.cancel()
        job = null
    }

    override fun tailscaleVpnActive(): Boolean = interfaces().any { (_, addresses) -> addresses.any { isTailnet(it) } }

    companion object {
        private fun interfaces(): List<Pair<NetworkInterface, List<InetAddress>>> = runCatching {
            NetworkInterface.getNetworkInterfaces().toList().filter { runCatching { it.isUp && !it.isLoopback }.getOrDefault(false) }
                .map { it to it.inetAddresses.toList() }
        }.getOrDefault(emptyList())

        fun isTailnet(address: InetAddress): Boolean = TailnetAddress.isTailnetHost(address.hostAddress.substringBefore('%'))

        /** What identifies the network now: the interfaces with a usable address, and those addresses. */
        fun read(): NetworkPath {
            val usable = interfaces().mapNotNull { (nif, addresses) ->
                val own = addresses.filter { !it.isLinkLocalAddress && !it.isLoopbackAddress && !isTailnet(it) }
                if (own.isEmpty()) null else nif.name + "=" + own.map { it.hostAddress.substringBefore('%') }.sorted().joinToString(",")
            }.sorted()
            return NetworkPath(satisfied = usable.isNotEmpty(), interfaceId = usable.joinToString(" ").ifEmpty { null })
        }
    }
}

/**
 * Bonjour with JmDNS: browses `_aos-pair._tcp` (the Mac's pairing listener) and `_ssh._tcp`, on the interface of the
 * default route (JmDNS takes one address; the first IPv4 address of an interface that is up is the usual choice).
 */
class JmdnsDiscovery : ServiceDiscovery {
    override suspend fun find(type: String, name: String?, timeoutMillis: Long, orOnlyOne: Boolean): ResolvedService? =
        withContext(Dispatchers.IO) {
            val address = localAddress() ?: return@withContext null
            val jmdns = runCatching { JmDNS.create(address) }.getOrNull() ?: return@withContext null
            try {
                val fullType = if (type.endsWith(".local.")) type else type.trimEnd('.') + ".local."
                val found = LinkedHashMap<String, ResolvedService>()
                val wanted = withTimeoutOrNull(timeoutMillis) {
                    suspendCancellableCoroutine { continuation ->
                        val listener = object : ServiceListener {
                            override fun serviceAdded(event: ServiceEvent) {
                                event.dns.requestServiceInfo(event.type, event.name, 3_000)
                            }
                            override fun serviceRemoved(event: ServiceEvent) {}
                            override fun serviceResolved(event: ServiceEvent) {
                                val info = event.info
                                val host = info.inet4Addresses.firstOrNull()?.hostAddress ?: info.inetAddresses.firstOrNull()?.hostAddress
                                    ?: info.server?.trimEnd('.') ?: return
                                val service = ResolvedService(info.name, host, info.port)
                                synchronized(found) { found[info.name] = service }
                                if (name != null && info.name == name && continuation.isActive) continuation.resume(service)
                            }
                        }
                        jmdns.addServiceListener(fullType, listener)
                        continuation.invokeOnCancellation { jmdns.removeServiceListener(fullType, listener) }
                    }
                }
                wanted ?: synchronized(found) { if (orOnlyOne && found.size == 1) found.values.first() else null }
            } finally {
                runCatching { jmdns.close() }
            }
        }

    private fun localAddress(): InetAddress? = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback && !it.isVirtual && it.supportsMulticast() }
            .flatMap { it.inetAddresses.toList() }
            .firstOrNull { it is Inet4Address && !it.isLinkLocalAddress && !PollingNetworkMonitor.isTailnet(it) }
    }.getOrNull()
}
