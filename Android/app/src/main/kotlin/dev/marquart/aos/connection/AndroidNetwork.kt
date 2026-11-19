package dev.marquart.aos.connection

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import dev.marquart.aos.core.TailnetAddress
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * The phone's network through ConnectivityManager: the default network (which one, and whether there is one at all), and
 * the VPNs (the Tailscale app's VPN counts when a VPN network has an address in 100.64.0.0/10 or fd7a:115c:a1e0::/48).
 */
class AndroidNetworkMonitor(context: Context) : NetworkMonitor {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val _path = MutableStateFlow(NetworkPath(satisfied = false, interfaceId = null))
    override val path: StateFlow<NetworkPath> = _path
    private val vpnNetworks = ConcurrentHashMap<Network, LinkProperties>()
    private var started = false

    private val defaultCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = update(network)
        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) = update(network)
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = update(network)
        override fun onLost(network: Network) {
            _path.value = NetworkPath(satisfied = false, interfaceId = null)
        }
    }

    private val vpnCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            vpnNetworks[network] = linkProperties
        }

        override fun onLost(network: Network) {
            vpnNetworks.remove(network)
        }
    }

    private fun update(network: Network) {
        val capabilities = connectivity.getNetworkCapabilities(network)
        val link = connectivity.getLinkProperties(network)
        val transport = when {
            capabilities == null -> "?"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }
        val satisfied = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true ||
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        _path.value = NetworkPath(satisfied, "$transport ${link?.interfaceName ?: ""} $network")
    }

    @Synchronized override fun start() {
        if (started) return
        started = true
        connectivity.registerDefaultNetworkCallback(defaultCallback)
        val vpn = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_VPN)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        connectivity.registerNetworkCallback(vpn, vpnCallback)
    }

    @Synchronized override fun stop() {
        if (!started) return
        started = false
        runCatching { connectivity.unregisterNetworkCallback(defaultCallback) }
        runCatching { connectivity.unregisterNetworkCallback(vpnCallback) }
    }

    override fun tailscaleVpnActive(): Boolean = vpnNetworks.values.any { link ->
        link.linkAddresses.any { address ->
            val host = address.address.hostAddress ?: ""
            TailnetAddress.isTailnetIPv4(host) || TailnetAddress.isTailnetIPv6(host)
        }
    }
}

/**
 * Bonjour through NsdManager: browses a service type, prefers a service named like the Mac, and resolves it to an
 * address and port. One resolve at a time (NsdManager's rule before Android 14).
 */
class NsdServiceDiscovery(context: Context) : ServiceDiscovery {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val executor = Executors.newSingleThreadExecutor()

    override suspend fun find(type: String, name: String?, timeoutMillis: Long, orOnlyOne: Boolean): ResolvedService? {
        val found = ConcurrentHashMap<String, NsdServiceInfo>()
        val named = CompletableDeferred<NsdServiceInfo>()
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                named.completeExceptionally(IllegalStateException("NSD $errorCode"))
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                found[info.serviceName] = info
                if (name != null && info.serviceName == name) named.complete(info)
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                found.remove(info.serviceName)
            }
        }
        val service = try {
            nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, listener)
            withTimeoutOrNull(timeoutMillis) { runCatching { named.await() }.getOrNull() }
                ?: if (orOnlyOne && found.size == 1) found.values.first() else null
        } finally {
            runCatching { nsd.stopServiceDiscovery(listener) }
        }
        return service?.let { resolve(it, timeoutMillis) }
    }

    private suspend fun resolve(info: NsdServiceInfo, timeoutMillis: Long): ResolvedService? {
        val result = CompletableDeferred<ResolvedService?>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val callback = object : NsdManager.ServiceInfoCallback {
                override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) { result.complete(null) }
                override fun onServiceUpdated(updated: NsdServiceInfo) {
                    val address = updated.hostAddresses.firstOrNull { it is java.net.Inet4Address } ?: updated.hostAddresses.firstOrNull()
                    address?.hostAddress?.let { result.complete(ResolvedService(updated.serviceName, it, updated.port)) }
                }
                override fun onServiceLost() {}
                override fun onServiceInfoCallbackUnregistered() {}
            }
            nsd.registerServiceInfoCallback(info, executor, callback)
            try {
                return withTimeoutOrNull(timeoutMillis) { result.await() }
            } finally {
                runCatching { nsd.unregisterServiceInfoCallback(callback) }
            }
        }
        @Suppress("DEPRECATION")
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) { result.complete(null) }
            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                @Suppress("DEPRECATION")
                val host = serviceInfo.host?.hostAddress
                result.complete(host?.let { ResolvedService(serviceInfo.serviceName, it, serviceInfo.port) })
            }
        })
        return withTimeoutOrNull(timeoutMillis) { result.await() }
    }
}
