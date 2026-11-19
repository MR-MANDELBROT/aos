package dev.marquart.aos.terminal

import android.app.Activity
import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.core.util.Consumer
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import dev.marquart.aos.AosApp
import dev.marquart.aos.core.MacTermSession
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.core.TermAttach
import dev.marquart.aos.model.AppModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.WeakHashMap

/**
 * The app's terminals (iOS AppModel's terminal part and TerminalKeepAlive): one MacTerminal per paired Mac, made when
 * first needed and kept for the life of the process (its screen with it), the Mac's session list, the foreground service
 * that keeps the connection while a terminal is open, and links back from its notification. One per process:
 * `TerminalController.get(context)`.
 */
class TerminalController private constructor(private val app: Application, val model: AppModel) {
    val settings = TerminalSettings.get(app)

    /** The demo's model (the UI's screenshots): no service, no links. */
    private val isDemo get() = model.demo != null
    val sessions = MacSessionList()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val terminals = HashMap<String, MacTerminal>()
    private val _all = MutableStateFlow<List<MacTerminal>>(emptyList())

    /** The Mac (id) whose terminal the Terminal tab shows; null: the session list. */
    val showing = MutableStateFlow<String?>(null)

    private val _keptAlive = MutableStateFlow(false)

    /** The foreground service holds the connection (the app model doesn't drop it in the background meanwhile). */
    val keptAlive: StateFlow<Boolean> = _keptAlive.asStateFlow()

    init {
        // AppModel.onBackground: while a terminal keeps the app running, the connection stays.
        model.holdsConnectionInBackground = { _keptAlive.value }
        watchTerminals()
        // The font size from the settings page reaches the open terminals.
        scope.launch { settings.fontSize.collect { size -> terminals.values.forEach { it.setFontSize(size) } } }
        if (!isDemo) app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = watch(activity)
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }

    /** The Mac's terminal (made on first use; it remembers the session it showed last). */
    fun terminal(mac: PairedMac): MacTerminal {
        terminals[mac.id]?.let {
            it.setTitle(mac.name)
            return it
        }
        val terminal = MacTerminal(mac.id, mac.name, settings, Dispatchers.Main.immediate,
            macConnection = { model.connection.value?.takeIf { it.mac.value.id == mac.id } }, makeScreen = ::TermuxScreen)
        terminal.setFontSize(settings.fontSize.value)
        terminal.clipboard = { text ->
            val manager = app.getSystemService(ClipboardManager::class.java)
            manager?.setPrimaryClip(ClipData.newPlainText("Terminal", text))
        }
        terminals[mac.id] = terminal
        _all.value = terminals.values.toList()
        return terminal
    }

    fun existing(macId: String): MacTerminal? = terminals[macId]

    /** The terminal on screen with a new session on the Mac (the Overview's "Open Terminal"). */
    fun openNewTerminal(mac: PairedMac) {
        val terminal = terminal(mac)
        if (model.demo != null) terminal.showDemo(DEMO_TEXT, "3fa9c1d2") else terminal.startNewSession()
        showing.value = mac.id
    }

    /** Ends the terminal's session on the Mac (the notification's button): the connection first if it went. */
    fun endTerminal(macId: String) {
        val terminal = terminals[macId] ?: return
        scope.launch {
            val connection = model.connection.value
            if (connection?.ssh?.value?.isActive != true) {
                connection?.start()
                repeat(40) {
                    if (model.connection.value?.ssh?.value?.isActive == true) return@repeat
                    delay(250)
                }
            }
            terminal.endSession()
        }
    }

    // Keeping the connection in the background

    private fun watchTerminals() {
        scope.launch {
            @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
            _all.flatMapLatest { list ->
                if (list.isEmpty()) flowOf(emptyList()) else combine(list.map { t -> combine(t.phase, t.title) { _, _ -> t } }) { it.toList() }
            }.combine(settings.keepConnected) { list, keep -> list to keep }.collect { (list, keep) ->
                val open = list.filter { it.isOpen }
                if (isDemo) return@collect
                if (keep && open.isNotEmpty()) startService(open) else stopService()
            }
        }
    }

    private fun startService(open: List<MacTerminal>) {
        if (TerminalKeepAliveService.running) {
            TerminalKeepAliveService.update(app, open)
            _keptAlive.value = true
            return
        }
        // Android lets an app start a foreground service only from the foreground; a terminal opens there.
        if (!ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) return
        _keptAlive.value = TerminalKeepAliveService.start(app, open)
    }

    private fun stopService() {
        _keptAlive.value = false
        TerminalKeepAliveService.stop(app)
    }

    /** The open terminals, for the service's notification. */
    fun openTerminals(): List<MacTerminal> = terminals.values.filter { it.isOpen }

    internal fun serviceStopped() {
        _keptAlive.value = false
    }

    // Links from the notification

    private val watched = WeakHashMap<Activity, Boolean>()

    /** Listens for the notification's "open the terminal" on this activity (when it starts and when it is in front). */
    fun watch(activity: Activity) {
        if (isDemo) return
        val component = activity as? ComponentActivity ?: return
        if (watched.put(activity, true) != null) return
        handle(component.intent)
        component.addOnNewIntentListener(Consumer { handle(it) })
    }

    private fun handle(intent: Intent?) {
        if (intent?.action != ACTION_OPEN) return
        val macId = intent.getStringExtra(EXTRA_MAC) ?: return
        intent.action = null
        showing.value = macId
        model.selectTab(AppModel.Tab.TERMINAL)
    }

    companion object {
        const val ACTION_OPEN = "dev.marquart.aos.terminal.OPEN"
        const val EXTRA_MAC = "mac"

        private val controllers = WeakHashMap<AppModel, TerminalController>()

        /** The app's terminals (the app model's). */
        fun get(context: Context): TerminalController = of(context, (context.applicationContext as AosApp).graph.model)

        /** The terminals of this model (the app's, or the demo's own). */
        fun of(context: Context, model: AppModel): TerminalController = synchronized(controllers) {
            controllers.getOrPut(model) { TerminalController(context.applicationContext as Application, model) }
        }

        /** What the demo's terminal shows (iOS Demo.terminalText). */
        const val DEMO_TEXT = TerminalDemo.TEXT
    }
}
