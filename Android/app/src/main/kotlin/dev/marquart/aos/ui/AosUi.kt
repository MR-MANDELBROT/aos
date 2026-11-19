package dev.marquart.aos.ui

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import dev.marquart.aos.connection.NetworkMonitor
import dev.marquart.aos.keys.KeyProvider
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.store.SettingsStore
import dev.marquart.aos.ui.demo.DemoOptions
import dev.marquart.aos.ui.lock.AppLock
import dev.marquart.aos.ui.overview.ActionState
import dev.marquart.aos.ui.tailnet.TailnetControl
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.MainScope

/**
 * What the views share besides the model: the settings, the lock, the keys (Settings > SSH key), aOS's Tailscale, the
 * pages pushed on the Overview and in Settings, and pairing. One per activity; the demo makes its own.
 */
class AosUi(
    context: Context,
    val model: AppModel,
    val settings: SettingsStore,
    val lock: AppLock,
    val keys: KeyProvider,
    /** aOS's own Tailscale (null when the app is built without it). */
    val tailnet: TailnetControl?,
    val network: NetworkMonitor,
    val demo: DemoOptions? = null,
) {
    val isDemo: Boolean get() = demo != null

    /** Lives as long as the activity's UI (actions that outlive a page). */
    val scope: CoroutineScope = MainScope()

    /** The chats' actions, one at a time, shared by the list and a chat's page. */
    val chatActions = ActionState(scope, context.applicationContext)

    val overview = PageStack<OverviewPage>()
    val settingsPages = PageStack<SettingsPage>()

    /** Pairing is shown (over everything but the lock), with the link that opened the app if there was one. */
    var pairing by mutableStateOf<PairingStart?>(null)

    fun startPairing(link: String? = null) {
        pairing = PairingStart(link)
    }

    data class PairingStart(val link: String?)
}

/** The pages the Overview pushes. */
sealed interface OverviewPage {
    data object Chats : OverviewPage
    data class Chat(val id: String) : OverviewPage
    data object Apps : OverviewPage
    data object Routines : OverviewPage
}

/** The pages Settings pushes. */
sealed interface SettingsPage {
    data class Mac(val id: String) : SettingsPage
    data object Connection : SettingsPage
    data object DeviceKey : SettingsPage
    data object About : SettingsPage
    data object Acknowledgements : SettingsPage
    data class License(val kind: LicenseKind) : SettingsPage
    data object Routines : SettingsPage
    data object Terminal : SettingsPage
    data object Screen : SettingsPage
}

enum class LicenseKind { GPL3, OPEN_SCREEN_SHARING, APACHE2, TAILSCALE_BSD3 }

/** Pages pushed on a tab, the newest last. */
class PageStack<T> {
    val pages = mutableStateListOf<T>()
    val top: T? get() = pages.lastOrNull()

    fun push(page: T) {
        pages.add(page)
    }

    fun pop() {
        if (pages.isNotEmpty()) pages.removeAt(pages.lastIndex)
    }

    fun set(vararg new: T) {
        pages.clear()
        pages.addAll(new)
    }
}

val LocalAosUi = staticCompositionLocalOf<AosUi> { error("No AosUi") }
