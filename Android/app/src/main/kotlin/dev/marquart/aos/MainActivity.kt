package dev.marquart.aos

import android.content.Intent
import android.content.res.Configuration
import android.view.KeyEvent
import android.view.KeyboardShortcutGroup
import android.view.Menu
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.terminal.TerminalController
import dev.marquart.aos.terminal.TerminalHost
import dev.marquart.aos.ui.keys.AppShortcut
import dev.marquart.aos.ui.layout.rememberWindowLayout
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import dev.marquart.aos.ui.AosRoot
import dev.marquart.aos.ui.AosUi
import dev.marquart.aos.ui.demo.Demo
import dev.marquart.aos.ui.demo.DemoOptions
import dev.marquart.aos.ui.demo.from
import dev.marquart.aos.ui.tabs.installSettingsSlots
import dev.marquart.aos.ui.tailnet.TailnetControls
import dev.marquart.aos.ui.theme.AosTheme
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * The only activity: the UI (ui/AosRoot.kt), the pairing links that open the app (aos-pair://...), and the requests
 * a notification opens. A FragmentActivity for the biometric prompt.
 */
class MainActivity : FragmentActivity() {
    private lateinit var ui: AosUi

    /** The demo's own light or dark (null: the system's). */
    private var demoDark: Boolean? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val graph = (application as AosApp).graph
        installSettingsSlots()
        // Debug builds: sample data from intent extras (ui/demo/Demo.kt), for screenshots without a Mac.
        val demo = DemoOptions.from(intent)
        val dark = demo?.dark
        demoDark = dark
        applySystemBars()
        // Kept across rotations (the pages pushed, pairing), made once per task.
        val holder = ViewModelProvider(this)[UiHolder::class.java]
        ui = holder.ui ?: (if (demo != null) Demo.makeUi(applicationContext, demo)
            else AosUi(applicationContext, graph.model, graph.settings, graph.lock, graph.keys, TailnetControls.of(graph.tailnet), graph.network))
            .also { holder.ui = it }
        if (savedInstanceState == null) handle(intent)
        TerminalHost.mayHoldFocus = holdsTerminalFocus
        // Nothing of the app in the recent apps' picture while it locks itself.
        if (Build.VERSION.SDK_INT >= 33 && demo == null) {
            lifecycleScope.launch { graph.settings.settings.collect { setRecentsScreenshotEnabled(!it.requireUnlock) } }
        }
        setContent {
            // The layout follows the window: its size class, the device's posture, the fold (ui/layout).
            AosTheme(dark = dark ?: isSystemInDarkTheme()) { AosRoot(ui, window = rememberWindowLayout(this)) }
        }
    }

    /** The system's bars over the app's own background, their icons light or dark like the app. */
    private fun applySystemBars() {
        val dark = demoDark
        if (dark == null) enableEdgeToEdge()
        else enableEdgeToEdge(
            statusBarStyle = if (dark) SystemBarStyle.dark(Color.TRANSPARENT) else SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT),
            navigationBarStyle = if (dark) SystemBarStyle.dark(Color.TRANSPARENT) else SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT),
        )
    }

    /**
     * Turning the device, resizing the window (split screen, freeform, a desktop window), folding, a keyboard that
     * comes or goes and light or dark don't restart the activity (the manifest's configChanges): Compose lays the
     * same UI out again, and the terminal's view and a running screen session stay as they are.
     */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        applySystemBars()
    }

    // Keyboard shortcuts (ui/keys/Shortcuts.kt)

    private var shortcutKeyDown: Int? = null

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            val shortcut = AppShortcut.match(event.keyCode, event.metaState)
            if (shortcut != null && perform(shortcut, repeated = event.repeatCount > 0)) {
                shortcutKeyDown = event.keyCode
                return true
            }
        } else if (event.action == KeyEvent.ACTION_UP && event.keyCode == shortcutKeyDown) {
            shortcutKeyDown = null
            return true
        }
        // While a terminal is on screen a hardware keyboard types into it, whatever was touched or clicked last (a key
        // of the bar, the session list beside it, the tabs): Tab, Esc and the arrows are the shell's, they don't move
        // the focus around the window. Sheets, menus and dialogs are windows of their own and keep their keys; the
        // lock and pairing are over the terminal and keep theirs.
        val terminal = TerminalHost.shown?.view
        if (terminal != null && !event.isSystem && terminal.isShown && !terminal.hasFocus() && terminalMayTakeKeys()) {
            // This key goes straight to it (Compose would still take a Tab or an arrow for the element that had the
            // focus); the next ones find it focused and take the usual way.
            terminal.requestFocus()
            return terminal.dispatchKeyEvent(event)
        }
        return super.dispatchKeyEvent(event)
    }

    private val holdsTerminalFocus: () -> Boolean = { terminalMayTakeKeys() }

    override fun onDestroy() {
        if (TerminalHost.mayHoldFocus === holdsTerminalFocus) TerminalHost.mayHoldFocus = { false }
        super.onDestroy()
    }

    private fun terminalMayTakeKeys(): Boolean =
        ::ui.isInitialized && ui.model.tab.value == AppModel.Tab.TERMINAL && !ui.lock.isLocked.value && ui.pairing == null

    /** Does what a shortcut says; false when it has nothing to do here (the key then goes where it would). */
    private fun perform(shortcut: AppShortcut, repeated: Boolean): Boolean {
        if (!::ui.isInitialized || ui.lock.isLocked.value || ui.pairing != null) return false
        val model = ui.model
        if (shortcut.needsTerminal) {
            if (model.tab.value != AppModel.Tab.TERMINAL) return false
            return TerminalController.of(this, model).perform(shortcut)
        }
        if (repeated) return true
        when (shortcut) {
            AppShortcut.OVERVIEW -> model.selectTab(AppModel.Tab.OVERVIEW)
            AppShortcut.TERMINAL -> model.selectTab(AppModel.Tab.TERMINAL)
            AppShortcut.SCREEN -> model.selectTab(AppModel.Tab.SCREEN)
            AppShortcut.SETTINGS -> model.selectTab(AppModel.Tab.SETTINGS)
            AppShortcut.NEW_SESSION -> if (model.macs.value.isNotEmpty()) model.openNewTerminal() else return false
            else -> return false
        }
        return true
    }

    override fun onProvideKeyboardShortcuts(data: MutableList<KeyboardShortcutGroup>, menu: Menu?, deviceId: Int) {
        super.onProvideKeyboardShortcuts(data, menu, deviceId)
        data.add(AppShortcut.group(this))
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        intent ?: return
        intent.data?.takeIf { it.scheme.equals("aos-pair", ignoreCase = true) }?.let { ui.startPairing(it.toString()) }
        val open = intent.getStringExtra(EXTRA_OPEN) ?: return
        intent.removeExtra(EXTRA_OPEN)
        val model = ui.model
        when {
            open.startsWith("question:") -> {
                val id = open.removePrefix("question:")
                model.questions.value.firstOrNull { it.id == id }?.let { model.present(it) }
                model.selectTab(AppModel.Tab.OVERVIEW)
            }
            open.startsWith("help:") -> {
                val id = open.removePrefix("help:")
                model.helpRequests.value.firstOrNull { it.id == id }?.let { model.showHelp(it) }
            }
        }
    }

    /** Holds the UI's state for the activity across configuration changes. */
    class UiHolder : ViewModel() {
        var ui: AosUi? = null

        override fun onCleared() {
            ui?.scope?.cancel()
        }
    }

    companion object {
        /** A request a notification opens: "question:<id>" or "help:<id>". */
        const val EXTRA_OPEN = "dev.marquart.aos.open"

        fun openQuestion(id: String) = "question:$id"
        fun openHelp(id: String) = "help:$id"
    }
}
