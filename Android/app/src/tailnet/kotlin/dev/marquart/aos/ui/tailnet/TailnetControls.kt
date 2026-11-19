package dev.marquart.aos.ui.tailnet

import dev.marquart.aos.connection.EmbeddedTailnet
import dev.marquart.aos.connection.TailnetDialer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

/** Built with the Go library: Settings > Connection controls `EmbeddedTailnet`. */
object TailnetControls {
    fun of(dialer: TailnetDialer): TailnetControl? = (dialer as? EmbeddedTailnet)?.let(::EmbeddedTailnetControl)
}

private class EmbeddedTailnetControl(private val node: EmbeddedTailnet) : TailnetControl {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override val info: StateFlow<TailnetInfo?> = node.state.map { s ->
        s?.let {
            TailnetInfo(
                backendState = it.backendState ?: "", tailnet = it.tailnet ?: "", dnsName = (it.dnsName ?: "").trimEnd('.'),
                addresses = TailnetInfo.addresses(it.addresses ?: ""), keyExpiry = it.keyExpiry ?: "", error = it.error ?: "",
                authUrl = runCatching { it.authURL() }.getOrNull()?.takeIf { url -> url.isNotEmpty() },
                isRunning = runCatching { it.isRunning }.getOrDefault(false),
                needsLogin = runCatching { it.needsLogin() }.getOrDefault(false),
            )
        }
    }.stateIn(scope, SharingStarted.Eagerly, null)

    override val isSetUp: Boolean get() = node.isSetUp
    override fun setUp() = node.setUp()
    override fun signIn() = node.login()
    override fun reconnect() = node.reconnect()
    override fun signOut() = node.signOut()
}
