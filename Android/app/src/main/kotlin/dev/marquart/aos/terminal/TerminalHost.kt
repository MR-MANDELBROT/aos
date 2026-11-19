package dev.marquart.aos.terminal

import android.annotation.SuppressLint
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.PopupMenu
import android.widget.TextView
import com.termux.terminal.RemoteTerminalSessions
import com.termux.terminal.TerminalColors
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import com.termux.terminal.TextStyle
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient
import dev.marquart.aos.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * The terminal as an Android view (iOS AOSTerminalView): Termux's TerminalView showing the MacTerminal's emulator through
 * a session without a process (RemoteTerminalSessions), with this app's touch handling on top. A swipe sends arrow keys
 * (TerminalSwipe's rule), a pinch changes the font size, a long press on a web address offers to open or copy it (any
 * other long press selects, with Termux's Copy / Paste / More), a tap shows the keyboard. Typed text goes through the
 * key bar's sticky modifiers. One per screen; the MacTerminal outlives it.
 */
@SuppressLint("ViewConstructor")
class TerminalHost(context: Context, val terminal: MacTerminal, private val settings: TerminalSettings) : FrameLayout(context) {
    val view = TerminalView(context, null)
    private val density = resources.displayMetrics.density
    private val handler = Handler(Looper.getMainLooper())
    private var scope: CoroutineScope? = null
    private var appliedFontSize = 0
    private var released = false

    /** Swiping on the terminal sends arrow keys (the setting). */
    var swipeArrows = true

    /** Text selection is under way (Termux's copy mode): no swipes then. */
    private var selecting = false

    private val sessionClient = object : TerminalSessionClient by QuietSessionClient {
        override fun onCopyTextToClipboard(session: TerminalSession, text: String?) {
            if (text.isNullOrEmpty()) return
            terminal.clipboard(text)
            terminal.show(MacTerminal.Notice.Kind.COPIED)
            performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        }

        override fun onPasteTextFromClipboard(session: TerminalSession?) {
            pasteFromClipboard()
        }
    }

    /** Where the link menu opens (moved to the finger). */
    private val anchor = View(context)

    /** While swiping: a small circle above the finger with the arrow being sent. */
    private val swipeHint = TextView(context).apply {
        gravity = Gravity.CENTER
        textSize = 24f
        setTextColor(Color.WHITE)
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(0xcc5856d6.toInt())
        }
        visibility = GONE
        elevation = 6 * resources.displayMetrics.density
    }

    private val session: TerminalSession = RemoteTerminalSessions.create(terminal.emulator, sessionClient, terminal::send)

    init {
        view.setTerminalViewClient(Client())
        view.isFocusable = true
        view.isFocusableInTouchMode = true
        view.keepScreenOn = false
        applyFontSize(terminal.fontSize.value)
        addView(view, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(swipeHint, LayoutParams(dp(52), dp(52)))
        addView(anchor, LayoutParams(1, 1))
        applyColors()
        view.attachSession(session)
        terminal.onScreenChanged = { view.onScreenUpdated() }
        terminal.onClearSelection = { if (view.isSelectingText) view.stopTextSelectionMode() }
        view.setOnCreateContextMenuListener { menu, _, _ ->
            // Termux's "More…" after a selection: the selected text if it is a link, and copying.
            val link = view.storedSelectedText?.let(TerminalText::singleLink)
            if (link != null) menu.add(R.string.term_open_link).setOnMenuItemClickListener { open(link); true }
            menu.add(R.string.term_copy_screen).setOnMenuItemClickListener { terminal.copyScreen(view.topRow); true }
            menu.add(R.string.term_copy_last_output).setOnMenuItemClickListener { terminal.copyLastOutput(); true }
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        this.scope = scope
        scope.launch { terminal.fontSize.collect(::applyFontSize) }
        scope.launch { settings.swipeArrows.collect { swipeArrows = it } }
        view.onScreenUpdated()
        // As on the iPhone: the terminal takes the keys when it appears (a hardware keyboard types into it at once).
        post { showKeyboard() }
    }

    override fun onDetachedFromWindow() {
        scope?.cancel()
        scope = null
        stopSwipe()
        super.onDetachedFromWindow()
    }

    /** The view is gone for good (its screen left): its session's input thread ends. The terminal keeps running. */
    fun release() {
        if (released) return
        released = true
        if (view.isSelectingText) view.stopTextSelectionMode()
        RemoteTerminalSessions.close(session)
        if (terminal.onScreenChanged != null) terminal.onScreenChanged = null
        terminal.onClearSelection = null
    }

    override fun onConfigurationChanged(newConfig: Configuration?) {
        super.onConfigurationChanged(newConfig)
        applyColors()
    }

    // Look

    private fun applyFontSize(size: Int) {
        if (size == appliedFontSize) return
        appliedFontSize = size
        val px = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, size.toFloat(), resources.displayMetrics)
        view.setTextSize(px.toInt())
    }

    /** The app's light or dark look: background and text like the rest of the app, the 256 colors as xterm's. */
    private fun applyColors() {
        val dark = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        val background = if (dark) 0xff000000.toInt() else 0xffffffff.toInt()
        val foreground = if (dark) 0xffe8e8ea.toInt() else 0xff1c1c1e.toInt()
        val cursor = if (dark) 0xffd0d0d4.toInt() else 0xff3c3c43.toInt()
        val defaults = TerminalColors.COLOR_SCHEME.mDefaultColors
        val current = terminal.emulator.mColors.mCurrentColors
        for ((index, color) in listOf(TextStyle.COLOR_INDEX_FOREGROUND to foreground,
            TextStyle.COLOR_INDEX_BACKGROUND to background, TextStyle.COLOR_INDEX_CURSOR to cursor)) {
            defaults[index] = color
            current[index] = color
        }
        setBackgroundColor(background)
        view.invalidate()
    }

    // Keyboard

    private val inputMethods get() = context.getSystemService(InputMethodManager::class.java)

    fun showKeyboard() {
        view.requestFocus()
        inputMethods?.showSoftInput(view, 0)
    }

    fun hideKeyboard() {
        inputMethods?.hideSoftInputFromWindow(view.windowToken, 0)
    }

    private fun pasteFromClipboard() {
        val clip = context.getSystemService(ClipboardManager::class.java)?.primaryClip ?: return
        if (clip.itemCount == 0) return
        val text = clip.getItemAt(0).coerceToText(context)?.toString()
        if (!text.isNullOrEmpty()) terminal.paste(text)
    }

    private fun open(link: String) {
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(link)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Exception) {
        }
    }

    // Termux's view asks this for everything it doesn't decide itself

    private inner class Client : TerminalViewClient {
        override fun onScale(scale: Float): Float {
            // A pinch: a point bigger or smaller per step, shown like on the iPhone.
            if (scale in 0.9f..1.1f) return scale
            val size = (terminal.fontSize.value + if (scale > 1) 1 else -1).coerceIn(TerminalFontSize.MIN, TerminalFontSize.MAX)
            if (size != terminal.fontSize.value) {
                terminal.setFontSize(size)
                settings.setFontSize(size)
                applyFontSize(size)
                terminal.showFontSize()
                performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
            }
            return 1.0f
        }

        override fun onSingleTapUp(e: MotionEvent?) = showKeyboard()
        override fun shouldBackButtonBeMappedToEscape() = false
        override fun shouldEnforceCharBasedInput() = false
        override fun shouldUseCtrlSpaceWorkaround() = false
        override fun isTerminalViewSelected() = true
        override fun copyModeChanged(copyMode: Boolean) {
            selecting = copyMode
        }

        override fun onKeyDown(keyCode: Int, e: KeyEvent?, session: TerminalSession?): Boolean {
            // Backspace and Return with a modifier of the key bar on (the keyboard sends them as key events).
            return when (keyCode) {
                KeyEvent.KEYCODE_DEL -> terminal.typedKey(TerminalKey.Backspace)
                KeyEvent.KEYCODE_ENTER -> terminal.typedKey(TerminalKey.Enter)
                else -> false
            }
        }

        override fun onKeyUp(keyCode: Int, e: KeyEvent?) = false

        /** A long press on a web address offers it; anywhere else Termux selects text. */
        override fun onLongPress(event: MotionEvent): Boolean {
            val (column, row) = view.getColumnAndRow(event, true).let { it[0] to it[1] }
            val emulator = terminal.emulator
            val text = emulator.screen.getSelectedText(0, row, emulator.mColumns - 1, row, false, false)
            val link = TerminalText.linkAt(text, column)?.second ?: return false
            performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            anchor.x = event.x
            anchor.y = event.y
            PopupMenu(context, anchor, Gravity.NO_GRAVITY).apply {
                menu.add(link).isEnabled = false
                menu.add(R.string.term_open_link).setOnMenuItemClickListener { open(link); true }
                menu.add(R.string.term_copy_link).setOnMenuItemClickListener {
                    terminal.clipboard(link)
                    terminal.show(MacTerminal.Notice.Kind.LINK_COPIED)
                    true
                }
                show()
            }
            return true
        }

        override fun readControlKey() = false
        override fun readAltKey() = false
        override fun readShiftKey() = false
        override fun readFnKey() = false

        override fun onCodePoint(codePoint: Int, ctrlDown: Boolean, session: TerminalSession?): Boolean =
            terminal.typed(codePoint, ctrlDown)

        override fun onEmulatorSet() {
            val emulator = view.mEmulator ?: return
            terminal.resized(emulator.mColumns, emulator.mRows)
        }

        override fun logError(tag: String?, message: String?) {}
        override fun logWarn(tag: String?, message: String?) {}
        override fun logInfo(tag: String?, message: String?) {}
        override fun logDebug(tag: String?, message: String?) {}
        override fun logVerbose(tag: String?, message: String?) {}
        override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) {}
        override fun logStackTrace(tag: String?, e: Exception?) {}
    }

    // Swiping for arrow keys (TerminalSwipe has the rule; iOS ArrowSwipeRecognizer)

    private enum class Swipe { NONE, POSSIBLE, ARROWS, FAILED }

    private var swipe = Swipe.NONE
    private var startX = 0f
    private var startY = 0f
    private var startTime = 0L
    private var dx = 0f
    private var dy = 0f
    private var velocity: VelocityTracker? = null
    private var swipeKey: TerminalKey? = null

    private val repeat = object : Runnable {
        override fun run() {
            val key = swipeKey ?: return
            sendSwipeArrow(key)
            handler.postDelayed(this, (ArrowPad.repeatInterval(kotlin.math.hypot(dx, dy)) * 1000).toLong())
        }
    }

    private fun decideSwipe(): TerminalSwipe.Decision? {
        if (!swipeArrows || selecting || view.isSelectingText) return TerminalSwipe.Decision.NONE
        velocity?.computeCurrentVelocity(1000)
        val vy = (velocity?.yVelocity ?: 0f) / density
        // "At the end": not scrolled back (full-screen programs have no scrollback, so there always).
        val atEnd = view.topRow == 0
        return TerminalSwipe.decide(dx, dy, vy, (SystemClock.uptimeMillis() - startTime) / 1000.0, atEnd)
    }

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                stopSwipe()
                velocity = VelocityTracker.obtain().also { it.addMovement(event) }
                startX = event.x
                startY = event.y
                startTime = event.eventTime
                dx = 0f
                dy = 0f
                // The screen's edges belong to Android's back gesture.
                val screenX = event.rawX / density
                val screenWidth = resources.displayMetrics.widthPixels / density
                swipe = if (!swipeArrows || TerminalSwipe.inEdge(screenX, screenWidth)) Swipe.FAILED else Swipe.POSSIBLE
            }
            MotionEvent.ACTION_POINTER_DOWN -> swipe = Swipe.FAILED // a pinch or two fingers
            MotionEvent.ACTION_MOVE -> if (swipe == Swipe.POSSIBLE) {
                velocity?.addMovement(event)
                dx = (event.x - startX) / density
                dy = (event.y - startY) / density
                when (decideSwipe()) {
                    null -> Unit
                    TerminalSwipe.Decision.ARROWS -> {
                        swipe = Swipe.ARROWS
                        beginSwipe()
                        return true
                    }
                    else -> swipe = Swipe.FAILED
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> stopSwipe()
        }
        return false
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (swipe != Swipe.ARROWS) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_MOVE -> {
                dx = (event.x - startX) / density
                dy = (event.y - startY) / density
                followSwipe()
            }
            MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> stopSwipe()
        }
        return true
    }

    private fun beginSwipe() {
        parent?.requestDisallowInterceptTouchEvent(true)
        swipeHint.x = startX - dp(26)
        swipeHint.y = startY - dp(96)
        swipeHint.text = ""
        swipeHint.visibility = VISIBLE
        followSwipe()
    }

    /** Like the pad: the arrow for the direction from where the finger started; held, it repeats. */
    private fun followSwipe() {
        val key = ArrowPad.key(dx, dy)
        if (key == swipeKey) return
        swipeKey = key
        handler.removeCallbacks(repeat)
        swipeHint.text = when (key) {
            TerminalKey.Up -> "↑"
            TerminalKey.Down -> "↓"
            TerminalKey.Left -> "←"
            TerminalKey.Right -> "→"
            else -> ""
        }
        if (key == null) return
        sendSwipeArrow(key)
        handler.postDelayed(repeat, (ArrowPad.FIRST_REPEAT * 1000).toLong())
    }

    private fun sendSwipeArrow(key: TerminalKey) {
        performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        terminal.sendKey(key)
    }

    private fun stopSwipe() {
        handler.removeCallbacks(repeat)
        swipeKey = null
        swipe = Swipe.NONE
        velocity?.recycle()
        velocity = null
        swipeHint.visibility = GONE
    }

    private fun dp(value: Int) = (value * density).toInt()
}
