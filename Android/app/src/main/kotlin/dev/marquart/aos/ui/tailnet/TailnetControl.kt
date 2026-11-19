package dev.marquart.aos.ui.tailnet

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * aOS's own Tailscale node as Settings > Connection and pairing see it: set it up, sign in (the URL opens in a Custom
 * Tab), reconnect, sign out. The app built with the Go library has one (src/tailnet, `TailnetControls`); without it
 * there is none and the views leave it out.
 */
interface TailnetControl {
    /** The node's state as it last reported it (null before it started). */
    val info: StateFlow<TailnetInfo?>
    val isSetUp: Boolean
    fun setUp()
    /** Asks for a sign-in URL (it comes with the next state). */
    fun signIn()
    fun reconnect()
    fun signOut()
}

data class TailnetInfo(
    /** NoState, NeedsLogin, NeedsMachineAuth, Stopped, Starting, Running */
    val backendState: String,
    val tailnet: String = "",
    val dnsName: String = "",
    val addresses: List<String> = emptyList(),
    /** As the node says it (ISO 8601), empty when it doesn't expire. */
    val keyExpiry: String = "",
    val error: String = "",
    val authUrl: String? = null,
    val isRunning: Boolean = backendState == "Running",
    val needsLogin: Boolean = backendState == "NeedsLogin",
) {
    val needsApproval: Boolean get() = backendState == "NeedsMachineAuth"

    companion object {
        /** Only Tailscale's own https pages are opened as the sign-in page. */
        fun signInPage(url: String?): String? {
            val text = url?.trim() ?: return null
            val uri = runCatching { java.net.URI(text) }.getOrNull() ?: return null
            val host = uri.host?.lowercase() ?: return null
            if (uri.scheme != "https") return null
            return if (host == "tailscale.com" || host.endsWith(".tailscale.com")) text else null
        }

        fun addresses(text: String): List<String> = text.split(',', ' ', '\n').map { it.trim() }.filter { it.isNotEmpty() }
    }
}

/** For the demo and the tests: a node whose state is set from outside. */
class FakeTailnetControl(initial: TailnetInfo? = null, setUp: Boolean = initial != null) : TailnetControl {
    override val info = MutableStateFlow(initial)
    override var isSetUp: Boolean = setUp
        private set

    override fun setUp() {
        isSetUp = true
        if (info.value == null) info.value = TailnetInfo("NeedsLogin", authUrl = "https://login.tailscale.com/a/demo")
    }

    override fun signIn() = Unit
    override fun reconnect() = Unit
    override fun signOut() {
        isSetUp = false
        info.value = null
    }
}
