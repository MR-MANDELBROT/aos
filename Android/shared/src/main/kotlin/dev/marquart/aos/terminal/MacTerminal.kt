package dev.marquart.aos.terminal

import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.core.TermAttach
import dev.marquart.aos.core.TermNote
import dev.marquart.aos.core.TermNoteFilter
import dev.marquart.aos.ssh.SessionChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.takeWhile
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicLong

/** Remembers which session on the Mac the terminal showed last, per Mac (kept across launches of the app). */
interface SessionMemory {
    fun holderId(macId: String): String?
    fun setHolderId(macId: String, id: String?)
}

class MemorySessionMemory : SessionMemory {
    private val ids = java.util.concurrent.ConcurrentHashMap<String, String>()
    override fun holderId(macId: String): String? = ids[macId]
    override fun setHolderId(macId: String, id: String?) {
        if (id == null) ids.remove(macId) else ids[macId] = id
    }
}

/**
 * The terminal on the paired Mac (iOS Sources/Terminal/TerminalSession.swift): one of the Mac's sessions at a time,
 * which outlive the connection (`aos-companion term attach`, core TerminalAttach.kt). When the connection drops (the app
 * in the background, a new network, the Mac asleep) the shell keeps running on the Mac, and the terminal attaches again
 * by itself as soon as the Mac is reachable, getting exactly the output it missed. "New Session" starts another shell
 * there, switching shows another one (the one before keeps running). This phone names itself when it attaches (its
 * phone id), so a newer connection of its own replaces an older one without a word: only another device "takes" a
 * session.
 *
 * The screen is a terminal emulator (`TerminalScreen`: Termux's on Android, JediTerm's on the desktop), fed here; it
 * lives as long as this object, so its contents survive leaving the screen and coming back (the view only shows it).
 * Everything runs on `dispatcher` (the main thread in the app); the public methods may be called from any thread.
 */
class MacTerminal(
    val macId: String,
    title: String,
    private val memory: SessionMemory,
    val dispatcher: CoroutineDispatcher,
    /** The Mac connection to attach through (the app's current one). */
    @Volatile var macConnection: () -> MacConnection? = { null },
    private val now: () -> Long = System::currentTimeMillis,
    /** Makes the emulator (Android: `::TermuxScreen`, desktop: JediTerm's). */
    makeScreen: (TerminalScreen.Events) -> TerminalScreen,
) {
    sealed class Phase {
        data object Idle : Phase()
        data object Connecting : Phase()
        data object Connected : Phase()

        /** The connection dropped; on the Mac the shell keeps running and the terminal attaches again by itself. */
        data object Reconnecting : Phase()
        data object Ended : Phase()

        /** `message`: what the Mac said, or why attaching failed; null: "The terminal on the Mac doesn't start." */
        data class Failed(val message: String?) : Phase()
    }

    /** Why the terminal ended. */
    enum class EndReason {
        /** The shell, or the connection to it, ended (a plain shell: an older aOS on the Mac). */
        CLOSED,

        /** The shell on the Mac exited. */
        EXITED,

        /** Someone ended the session (here, in the list, or on the Mac). */
        ENDED,

        /** Another device attached to the session. */
        TAKEN,
    }

    /** A short message over the terminal; the UI words it. */
    data class Notice(val kind: Kind, val size: Int = 0, val columns: Int = 0, val rows: Int = 0, val serial: Long = serials.incrementAndGet()) {
        enum class Kind {
            SESSION_WAS_NEW, UPDATE_AOS, AOS_MISSING, MAC_UNREACHABLE, SCREEN_COPIED, OUTPUT_COPIED, NO_OUTPUT, COPIED,
            LINK_COPIED, FONT_SIZE,
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

    private val _title = MutableStateFlow(title)
    private val _phase = MutableStateFlow<Phase>(Phase.Idle)
    private val _endReason = MutableStateFlow(EndReason.CLOSED)
    private val _holderId = MutableStateFlow(memory.holderId(macId)?.takeIf(TermAttach::isId))
    private val _holdsSession = MutableStateFlow(true)
    private val _notice = MutableStateFlow<Notice?>(null)
    private val _pendingPaste = MutableStateFlow<String?>(null)
    private val _fontSize = MutableStateFlow(TerminalFontSize.STANDARD)
    private val _modifiers = MutableStateFlow(emptyMap<Int, StickyModifiers.State>())
    private val _connectedSince = MutableStateFlow<Long?>(null)

    val title: StateFlow<String> = _title.asStateFlow()
    val phase: StateFlow<Phase> = _phase.asStateFlow()
    val endReason: StateFlow<EndReason> = _endReason.asStateFlow()

    /** The session on the Mac this terminal shows (kept across launches of the app). */
    val holderId: StateFlow<String?> = _holderId.asStateFlow()

    /** False when aOS on the Mac can't hold sessions (an older version): a plain shell then. */
    val holdsSession: StateFlow<Boolean> = _holdsSession.asStateFlow()
    val notice: StateFlow<Notice?> = _notice.asStateFlow()

    /** Text that would run as commands (no bracketed paste, line breaks in it): the screen asks first. */
    val pendingPaste: StateFlow<String?> = _pendingPaste.asStateFlow()

    /** The font size in sp (the screen keeps it in the settings). */
    val fontSize: StateFlow<Int> = _fontSize.asStateFlow()

    /** The key bar's modifiers, for showing them. */
    val modifierStates: StateFlow<Map<Int, StickyModifiers.State>> = _modifiers.asStateFlow()

    /** Since when the terminal is connected (for the notification). */
    val connectedSince: StateFlow<Long?> = _connectedSince.asStateFlow()

    /** Connecting, connected or reconnecting (iOS `isActive`). */
    val isOpen: Boolean get() = _phase.value.let { it == Phase.Connecting || it == Phase.Connected || it == Phase.Reconnecting }

    fun setTitle(title: String) {
        _title.value = title
    }

    // The screen

    private val events = object : TerminalScreen.Events {
        // What the emulator answers (cursor position reports, device attributes) goes to the Mac like typing.
        override fun reply(bytes: ByteArray) = send(bytes)
        override fun copyToClipboard(text: String) {
            clipboard(text)
        }
        override fun colorsChanged() {
            onScreenChanged?.invoke()
        }
    }

    /** The emulator the view shows (2000 lines of scrollback: enough for the last 256 KB the Mac replays). */
    val screen: TerminalScreen = makeScreen(events)

    /** The view's screen should be redrawn (it reads and clears the emulator's scroll counter). */
    @Volatile var onScreenChanged: (() -> Unit)? = null

    /** The view should drop its selection (the terminal started afresh, a key was sent). */
    @Volatile var onClearSelection: (() -> Unit)? = null

    /** Copies text to the clipboard (Android's, set by the controller). */
    @Volatile var clipboard: (String) -> Unit = {}

    /** Lines that scrolled off the top since the terminal began: a row's number that doesn't change as output comes. */
    private var scrolled = 0L

    /** Rows (in those numbers) where Return was pressed at the shell, for "Copy Last Output". */
    private val commandRows = ArrayDeque<Long>()

    /** The size the view last reported, in characters. */
    private var columns = 80
    private var rows = 24

    // The Mac's session

    /** The offset after the last output byte the screen has, and whether the screen has the session's output at all
     *  (not after a launch: then the next attach starts afresh). */
    private var received = 0L
    private var viewHasOutput = false
    private var filter = TermNoteFilter()

    /** The terminal should stay attached (until it shows another session or the session ends). */
    private var wantsAttached = false
    private var channel: SessionChannel? = null
    private var readJob: Job? = null
    private var writer: Channel<ByteArray>? = null
    private var reattach: Job? = null
    private var quickFailures = 0
    private var gotEndNote = false
    private var gotStartNote = false
    private var channelOpened = 0L

    /** Which channel is this terminal's: a new round after every drop and when it lets go. Output and notes of an older
     *  channel (one that lingers after a reconnect) are ignored: they are not this terminal's any more. */
    private var round = 0

    /** The round an attach is under way for (only one at a time). */
    private var attaching: Int? = null

    /** What the Mac wrote before the session started (why it didn't, if it doesn't). */
    private val beforeStart = ByteArrayOutputStream()

    private val modifiers = StickyModifiers()
    private var noticeJob: Job? = null

    private fun setPhase(new: Phase) {
        if (_phase.value == new) return
        _phase.value = new
        if (new == Phase.Connected && _connectedSince.value == null) _connectedSince.value = now()
        if (new == Phase.Ended || new == Phase.Idle || new is Phase.Failed) _connectedSince.value = null
    }

    private fun remember(holder: String?) {
        _holderId.value = holder
        memory.setHolderId(macId, holder)
    }

    // Connecting

    /** The terminal on the paired Mac, in the app's SSH connection: its session there, or a new one. */
    fun connect() {
        scope.launch {
            wantsAttached = true
            _endReason.value = EndReason.CLOSED
            quickFailures = 0
            attachToMac()
        }
    }

    /** Attaches to the Mac's session (or starts one), or waits for the Mac if it isn't reachable now. */
    private suspend fun attachToMac() {
        // Attached already, or an attach for this round is under way (two would start two new sessions).
        if (!wantsAttached || channel != null || attaching == round) return
        val current = currentCoroutineContext()[Job]
        if (reattach != current) reattach?.cancel()
        reattach = null
        val mac = macConnection()
        val ssh = mac?.ssh?.value
        if (mac == null || ssh == null || !ssh.isActive) {
            setPhase(if (viewHasOutput) Phase.Reconnecting else Phase.Connecting)
            waitForMac()
            return
        }
        if (_phase.value != Phase.Reconnecting) setPhase(Phase.Connecting)
        val mine = round
        attaching = mine
        try {
            val held = _holdsSession.value
            val shell = if (held) {
                val command = TermAttach.attach(mac.mac.value.companionPath, _holderId.value,
                    if (viewHasOutput) received else null, mac.phoneId)
                ssh.terminal(command, columns = maxOf(columns, 20), rows = maxOf(rows, 5))
            } else {
                ssh.shell(columns = maxOf(columns, 20), rows = maxOf(rows, 5))
            }
            // The terminal let go meanwhile, or shows another session now.
            if (!wantsAttached || mine != round || channel != null) {
                withContext(NonCancellable) { shell.close() }
                return
            }
            run(shell, held, mine)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (!wantsAttached || mine != round) return
            quickFailures++
            if (quickFailures >= 4) {
                wantsAttached = false
                setPhase(Phase.Failed(e.message))
                return
            }
            setPhase(if (viewHasOutput) Phase.Reconnecting else Phase.Connecting)
            waitForMac(quickFailures * 1000L)
        } finally {
            if (attaching == mine) attaching = null
        }
    }

    /** Waits until the app's connection to the Mac is up again (it reconnects by itself), then attaches. */
    private fun waitForMac(after: Long = 0) {
        reattach?.cancel()
        reattach = scope.launch {
            if (after > 0) delay(after)
            while (true) {
                if (!wantsAttached) return@launch
                val ssh = macConnection()?.ssh?.value
                if (ssh != null && ssh.isActive) {
                    attachToMac()
                    return@launch
                }
                delay(400)
            }
        }
    }

    /** Reads and writes the channel until it ends. */
    private fun run(shell: SessionChannel, held: Boolean, mine: Int) {
        stopWriting()
        channel = shell
        channelOpened = now()
        gotEndNote = false
        gotStartNote = false
        beforeStart.reset()
        filter = TermNoteFilter()
        // Input goes out in order through one coroutine.
        val input = Channel<ByteArray>(Channel.UNLIMITED)
        writer = input
        scope.launch {
            for (data in input) {
                try {
                    shell.write(data)
                } catch (_: Exception) {
                }
            }
        }
        // A plain shell is there at once; a held session once the Mac says where its output starts.
        if (!held) setPhase(Phase.Connected)
        readJob = scope.launch {
            try {
                shell.output.takeWhile { round == mine }.collect { chunk ->
                    if (held) receive(chunk) else feed(chunk)
                }
                channelEnded(null, held, mine)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                channelEnded(e, held, mine)
            }
        }
    }

    private fun receive(chunk: ByteArray) {
        for (piece in filter.feed(chunk)) {
            when (piece) {
                is TermNoteFilter.Piece.Bytes -> {
                    feed(piece.data)
                    received += piece.data.size
                    if (!gotStartNote && beforeStart.size() < 2048) {
                        beforeStart.write(piece.data, 0, minOf(piece.data.size, 2048 - beforeStart.size()))
                    }
                }
                is TermNoteFilter.Piece.Note -> handle(piece.note)
            }
        }
    }

    private fun handle(note: TermNote) {
        when (note) {
            is TermNote.Start -> {
                gotStartNote = true
                if (note.reset) startAfresh(note.prefix)
                received = note.from
                viewHasOutput = true
                remember(note.id)
                quickFailures = 0
                if (note.isNew && note.gone != null) show(Notice.Kind.SESSION_WAS_NEW)
                setPhase(Phase.Connected)
            }
            is TermNote.End -> when (note.why) {
                "taken" -> {
                    // Another device: it shows the session now.
                    gotEndNote = true
                    _endReason.value = EndReason.TAKEN
                    wantsAttached = false
                }
                // This phone attached again over another connection (an older channel never gets here): this one just
                // goes, and the terminal attaches again if it still has to.
                "replaced" -> Unit
                "lost" -> {
                    // The session's process on the Mac went away: the next attach starts a new one.
                    remember(null)
                    viewHasOutput = false
                }
                else -> {
                    gotEndNote = true
                    _endReason.value = if (note.why == "exited") EndReason.EXITED else EndReason.ENDED
                    wantsAttached = false
                    remember(null)
                    viewHasOutput = false
                }
            }
        }
    }

    private fun channelEnded(error: Throwable?, held: Boolean, mine: Int) {
        // An older channel ending is none of this terminal's business.
        if (mine != round) return
        channel = null
        stopWriting()
        round++
        if (!held) {
            if (_phase.value == Phase.Connected) setPhase(Phase.Ended)
            feed("\r\n".toByteArray())
            return
        }
        if (gotEndNote) {
            setPhase(Phase.Ended)
            return
        }
        if (!gotStartNote && error is SessionChannel.Failure.Exited) {
            // aOS on the Mac without terminal sessions (exit status 2: its usage), or not there (127): a plain shell.
            if (error.status == 2 || error.status == 127) {
                _holdsSession.value = false
                show(if (error.status == 2) Notice.Kind.UPDATE_AOS else Notice.Kind.AOS_MISSING)
                scope.launch { attachToMac() }
                return
            }
            // The Mac said why it doesn't start one (too many sessions, for example): trying again won't help.
            if (error.status == 1) {
                wantsAttached = false
                val said = error.text.ifEmpty { beforeStart.toByteArray().toString(Charsets.UTF_8) }.trim()
                setPhase(Phase.Failed(said.ifEmpty { null }))
                return
            }
        }
        if (!wantsAttached) return
        if (!gotStartNote && now() - channelOpened < 3000) quickFailures++
        if (quickFailures >= 4) {
            wantsAttached = false
            setPhase(Phase.Failed(error?.message))
            return
        }
        // The connection dropped: attach again when the Mac is reachable.
        setPhase(Phase.Reconnecting)
        waitForMac(if (quickFailures > 0) 1000L else 0L)
    }

    /** Lets go of the terminal: its channel closes. On the Mac the session keeps running; a plain shell ends. */
    fun disconnect() {
        scope.launch { disconnectNow() }
    }

    private fun disconnectNow() {
        wantsAttached = false
        round++
        reattach?.cancel()
        reattach = null
        readJob?.cancel()
        readJob = null
        val old = channel
        channel = null
        stopWriting()
        if (old != null) scope.launch(NonCancellable) { old.close() }
        if (isOpen) setPhase(if (_holdsSession.value && _holderId.value != null) Phase.Idle else Phase.Ended)
    }

    /** Ends the shell on the Mac (SIGHUP, like closing a terminal window); a plain shell just closes. */
    suspend fun endSession() = withContext(dispatcher) {
        val holder = _holderId.value
        if (!_holdsSession.value || holder == null) {
            disconnectNow()
            return@withContext
        }
        val mac = macConnection()
        val ssh = mac?.ssh?.value
        val command = mac?.let { TermAttach.end(it.mac.value.companionPath, holder) }
        if (ssh == null || !ssh.isActive || command == null) {
            show(Notice.Kind.MAC_UNREACHABLE)
            return@withContext
        }
        val wanted = wantsAttached
        wantsAttached = false
        reattach?.cancel()
        val ended = try {
            ssh.run(command, timeoutMillis = 10_000)
            true
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            false
        }
        if (!ended) {
            wantsAttached = wanted
            if (wanted && channel == null) waitForMac()
            show(Notice.Kind.MAC_UNREACHABLE)
            return@withContext
        }
        // The attached channel hears it too; without one the session is gone anyway.
        if (channel == null || !gotStartNote) {
            remember(null)
            viewHasOutput = false
            _endReason.value = EndReason.ENDED
            disconnectNow()
            setPhase(Phase.Ended)
        }
    }

    /** Shows another session on the Mac (from the list); the one before keeps running there. */
    fun switchTo(id: String) {
        scope.launch {
            if (!TermAttach.isId(id) || (id == _holderId.value && isOpen)) return@launch
            val same = id == _holderId.value
            disconnectNow()
            remember(id)
            // The same session again continues where the screen is; another one starts afresh.
            if (!same) viewHasOutput = false
            _holdsSession.value = true
            attachAgain()
        }
    }

    /** Starts another shell on the Mac and shows it; the one before keeps running there. */
    fun startNewSession() {
        // Connecting at once (so nothing else starts a second attach), also before the dispatcher runs.
        _phase.value = Phase.Connecting
        scope.launch {
            disconnectNow()
            forgetNow()
            _holdsSession.value = true
            attachAgain()
        }
    }

    /** Attaches from scratch: right away the terminal is "connecting" (so nothing else starts a second attach). */
    private fun attachAgain() {
        wantsAttached = true
        _endReason.value = EndReason.CLOSED
        quickFailures = 0
        setPhase(Phase.Connecting)
        scope.launch { attachToMac() }
    }

    /** The next connect starts a new session on the Mac (after this one ended). */
    fun forgetSession() {
        scope.launch { forgetNow() }
    }

    private fun forgetNow() {
        remember(null)
        viewHasOutput = false
    }

    /** Shows sample output (the demo), as the session `holder` of the demo's list. */
    fun showDemo(text: String, holder: String? = null) {
        scope.launch {
            if (holder != null) _holderId.value = holder
            setPhase(Phase.Connected)
            startAfresh(ByteArray(0))
            feed(text.toByteArray())
        }
    }

    private fun stopWriting() {
        writer?.close()
        writer = null
    }

    // The screen

    private fun feed(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        screen.append(bytes)
        scrolled += screen.scrollCounter
        val changed = onScreenChanged
        if (changed == null) screen.clearScrollCounter() else changed()
    }

    /** The Mac's session starts this terminal afresh (it had nothing, or missed more than the Mac keeps): everything
     *  goes, then the modes in effect where the replay begins. */
    private fun startAfresh(prefix: ByteArray) {
        onClearSelection?.invoke()
        commandRows.clear()
        feed("\u001bc\u001b[?25h".toByteArray())
        if (prefix.isNotEmpty()) feed(prefix)
    }

    /** The view's size in characters changed (the view resized the emulator already). */
    fun resized(columns: Int, rows: Int) {
        scope.launch {
            if (columns <= 0 || rows <= 0 || (columns == this@MacTerminal.columns && rows == this@MacTerminal.rows)) return@launch
            this@MacTerminal.columns = columns
            this@MacTerminal.rows = rows
            // Positions no longer fit.
            commandRows.clear()
            val current = channel ?: return@launch
            try {
                current.resize(columns, rows)
            } catch (_: Exception) {
            }
        }
    }

    // Input

    /** Bytes for the program (typed, a key, a paste, the emulator's answers). Dropped while no channel is open. */
    fun send(bytes: ByteArray) {
        scope.launch { sendNow(bytes) }
    }

    private fun sendNow(bytes: ByteArray) {
        val input = writer ?: return
        input.trySend(bytes)
        // Return at the shell: where the next command's output begins ("Copy Last Output").
        if (bytes.size == 1 && bytes[0] == 0x0d.toByte()) {
            commandRows += scrolled + screen.cursorRow
            while (commandRows.size > 200) commandRows.removeFirst()
        }
    }

    /** A key from the key bar (or the swipe), with the modifiers that are on. */
    fun sendKey(key: TerminalKey, extra: TerminalModifiers = TerminalModifiers.NONE) {
        scope.launch {
            val active = modifiers.active
            sendNow(TerminalKeyEncoder.bytes(key, active + extra, screen.cursorKeysApplicationMode))
            if (!active.isEmpty) {
                modifiers.consume()
                publishModifiers()
            }
            onClearSelection?.invoke()
        }
    }

    /** Typed text (the on-screen keyboard): the key bar's modifiers apply to it. False when none is on (the view sends
     *  it as it is). Called on the main thread. */
    fun typed(codePoint: Int, controlFromKeyboard: Boolean): Boolean {
        val active = modifiers.active
        if (active.isEmpty) return false
        val all = if (controlFromKeyboard) active + TerminalModifiers.CONTROL else active
        val key = if (codePoint == '\r'.code || codePoint == '\n'.code) TerminalKey.Enter else TerminalKey.Text(String(Character.toChars(codePoint)))
        scope.launch {
            sendNow(TerminalKeyEncoder.bytes(key, all, screen.cursorKeysApplicationMode))
            modifiers.consume()
            publishModifiers()
        }
        return true
    }

    /** Backspace or Return from the keyboard while a modifier is on: sent with it. False otherwise. */
    fun typedKey(key: TerminalKey): Boolean {
        if (modifiers.active.isEmpty) return false
        sendKey(key)
        return true
    }

    fun pressModifier(modifier: TerminalModifiers) {
        scope.launch {
            modifiers.press(modifier)
            publishModifiers()
        }
    }

    /** The modifier key went up: on for one key, locked, or off (see StickyModifiers). Seconds for the double tap. */
    fun releaseModifier(modifier: TerminalModifiers, cancelled: Boolean, onState: (StickyModifiers.State) -> Unit = {}) {
        val time = now() / 1000.0
        scope.launch {
            val state = modifiers.release(modifier, time, cancelled)
            publishModifiers()
            if (!cancelled) onState(state)
        }
    }

    /** The keyboard went away: the modifiers go too (as on the iPhone). */
    fun resetModifiers() {
        scope.launch {
            modifiers.reset()
            publishModifiers()
        }
    }

    private fun publishModifiers() {
        _modifiers.value = modifiers.snapshot()
    }

    // Copy, paste, font

    /** Pastes text: bracketed if the program asked for it; if not and the text has line breaks, the screen asks first. */
    fun paste(text: String) {
        scope.launch {
            val bracketed = bracketedPaste()
            if (PasteEncoder.runsLines(text, bracketed)) _pendingPaste.value = text else sendPaste(text, bracketed)
        }
    }

    /** After the person confirmed. */
    fun confirmPaste(text: String) {
        scope.launch {
            _pendingPaste.value = null
            sendPaste(text, bracketedPaste())
        }
    }

    fun cancelPaste() {
        _pendingPaste.value = null
    }

    private fun sendPaste(text: String, bracketed: Boolean) {
        onClearSelection?.invoke()
        sendNow(PasteEncoder.bytes(text, bracketed))
    }

    /** Whether the program asked for bracketed paste (`CSI ? 2004 h`). */
    private fun bracketedPaste(): Boolean = screen.bracketedPaste

    /** The rows of the scrollback and the screen, numbered like `commandRows`. */
    private fun allRows(): List<TerminalRowText> {
        val transcript = screen.transcriptRows
        return (-transcript until screen.rows).map { r ->
            TerminalRowText((scrolled + r).toInt(), screen.rowText(r), r > -transcript && screen.lineWraps(r - 1))
        }
    }

    /** The screen as text (what is visible at the end; `top`: the view's first row when scrolled back). */
    fun screenText(top: Int = 0): String {
        val transcript = screen.transcriptRows
        return TerminalText.joined((top until top + screen.rows).map { r ->
            TerminalRowText(r, screen.rowText(r), r > -transcript && screen.lineWraps(r - 1))
        })
    }

    /** The output of the last command (see `TerminalText.lastOutput`). */
    fun lastOutputText(): String? = TerminalText.lastOutput(allRows(), commandRows.map { it.toInt() },
        (scrolled + screen.cursorRow).toInt())

    fun copyScreen(top: Int = 0) {
        scope.launch {
            clipboard(screenText(top))
            show(Notice.Kind.SCREEN_COPIED)
        }
    }

    fun copyLastOutput() {
        scope.launch {
            val text = lastOutputText()
            if (text != null) {
                clipboard(text)
                show(Notice.Kind.OUTPUT_COPIED)
            } else {
                show(Notice.Kind.NO_OUTPUT)
            }
        }
    }

    /** A new font size (the view applies it and reports the new size in characters). */
    fun setFontSize(size: Int) {
        _fontSize.value = size.coerceIn(TerminalFontSize.MIN, TerminalFontSize.MAX)
    }

    /** From the menu or a pinch: shown as "13 pt · 80 × 24" once the view has laid out the new size. */
    fun showFontSize() {
        scope.launch { show(Notice.Kind.FONT_SIZE, _fontSize.value, screen.columns, screen.rows) }
    }

    fun show(kind: Notice.Kind, size: Int = 0, columns: Int = 0, rows: Int = 0) {
        _notice.value = Notice(kind, size, columns, rows)
        noticeJob?.cancel()
        noticeJob = scope.launch {
            delay(2400)
            _notice.value = null
        }
    }

    /** Runs `block` on the terminal's dispatcher (tests, the view's reads). */
    suspend fun <T> onTerminal(block: MacTerminal.() -> T): T = withContext(dispatcher) { block() }

    /** Ends everything (the Mac was unpaired). */
    fun close() {
        scope.launch {
            disconnectNow()
            scope.coroutineContext[Job]?.cancel()
        }
    }

    companion object {
        const val SCROLLBACK = 2000
        private val serials = AtomicLong()
    }
}
