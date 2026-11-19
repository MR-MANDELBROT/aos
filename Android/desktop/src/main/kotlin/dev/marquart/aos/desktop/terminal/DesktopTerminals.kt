package dev.marquart.aos.desktop.terminal

import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.desktop.store.Prefs
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.terminal.MacSessionList
import dev.marquart.aos.terminal.MacTerminal
import dev.marquart.aos.terminal.SessionMemory
import dev.marquart.aos.terminal.TerminalDemo
import dev.marquart.aos.terminal.TerminalFontSize
import dev.marquart.aos.ui.platform.Platform
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.swing.Swing

/** The terminal's settings on the desktop (terminal.json): the font size and the session each Mac showed last. */
class DesktopTerminalSettings(private val prefs: Prefs?) : SessionMemory {
    private val memory = HashMap<String, String>()
    private val _fontSize = MutableStateFlow(prefs?.int("fontSize", TerminalFontSize.STANDARD) ?: TerminalFontSize.STANDARD)
    val fontSize: StateFlow<Int> = _fontSize.asStateFlow()

    fun setFontSize(size: Int) {
        _fontSize.value = size.coerceIn(TerminalFontSize.MIN, TerminalFontSize.MAX)
        prefs?.set("fontSize", _fontSize.value)
    }

    override fun holderId(macId: String): String? = prefs?.string("holder.$macId") ?: memory[macId]
    override fun setHolderId(macId: String, id: String?) {
        if (prefs != null) prefs.set("holder.$macId", id) else if (id == null) memory.remove(macId) else memory[macId] = id
    }
}

/**
 * One `MacTerminal` per Mac for the life of the app (the screen survives leaving the tab), each with JediTerm as its
 * screen (Android: TerminalController with Termux's). They run on the Swing thread, like Android's on the main thread.
 */
class DesktopTerminals(val model: AppModel, val settings: DesktopTerminalSettings) {
    private val terminals = HashMap<String, MacTerminal>()
    val sessions = MacSessionList()

    /** The Mac whose terminal is on screen (null: the session list). */
    val showing = MutableStateFlow<String?>(null)

    /** Dark colors for new terminals (the window's theme). */
    @Volatile var dark = true

    fun existing(macId: String): MacTerminal? = terminals[macId]

    fun terminal(mac: PairedMac): MacTerminal {
        terminals[mac.id]?.let {
            it.setTitle(mac.name)
            return it
        }
        lateinit var jedi: JediTermScreen
        val terminal = MacTerminal(mac.id, mac.name, settings, Dispatchers.Swing,
            macConnection = { model.connection.value?.takeIf { it.mac.value.id == mac.id } },
            makeScreen = { events -> JediTermScreen(events, settings.fontSize.value, dark).also { jedi = it } })
        jedi.onResize = { columns, rows -> terminal.resized(columns, rows) }
        terminal.setFontSize(settings.fontSize.value)
        terminal.clipboard = { text -> Platform.current.copyToClipboard(text, "Terminal") }
        terminals[mac.id] = terminal
        return terminal
    }

    fun screenOf(terminal: MacTerminal): JediTermScreen = terminal.screen as JediTermScreen

    fun setFontSize(size: Int) {
        settings.setFontSize(size)
        terminals.values.forEach {
            it.setFontSize(settings.fontSize.value)
            screenOf(it).setFontSize(settings.fontSize.value)
            it.showFontSize()
        }
    }

    /** "Open Terminal" (the Overview) or New Session: a new session on the Mac, shown. */
    fun openNew(mac: PairedMac) {
        val t = terminal(mac)
        if (model.demo != null) t.showDemo(TerminalDemo.TEXT, "3fa9c1d2") else t.startNewSession()
        showing.value = mac.id
    }

    fun open(mac: PairedMac, sessionId: String) {
        val t = terminal(mac)
        if (model.demo != null) t.showDemo(TerminalDemo.TEXT, sessionId) else t.switchTo(sessionId)
        showing.value = mac.id
    }

    companion object {
        private val all = HashMap<AppModel, DesktopTerminals>()

        fun of(model: AppModel): DesktopTerminals = synchronized(all) {
            all.getOrPut(model) {
                DesktopTerminals(model, DesktopTerminalSettings(if (model.demo != null) null else Prefs.named("terminal")))
            }
        }
    }
}
