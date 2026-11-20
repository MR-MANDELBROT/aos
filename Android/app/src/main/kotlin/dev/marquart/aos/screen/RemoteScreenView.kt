// Based on Open Screen Sharing by nekohasekai (GPL-3.0); Android/app/src/main/assets/open-screen-sharing/LICENSE,
// COPYING. Ported for aOS's Android app on 2026-11-19 from iOS/ThirdParty/OpenScreenSharing
// (SessionUI/RemoteScreenView.swift, ScreenInput.swift, KeyInputProxy.swift): the picture's view with fingers, a mouse,
// a hardware keyboard and the on-screen keyboard.

package dev.marquart.aos.screen

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.opengl.GLSurfaceView
import android.text.Editable
import android.text.InputType
import android.text.Selection
import android.view.HapticFeedbackConstants
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.PointerIcon
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

@SuppressLint("ViewConstructor")
class RemoteScreenView(context: Context) : GLSurfaceView(context) {
    private val density = resources.displayMetrics.density
    val viewport = Viewport()
    val renderer = ScreenRenderer(this, density)
    private val gestures = TouchGestures(GestureSink(), density)
    private val clipboardManager = context.getSystemService(ClipboardManager::class.java)

    var session: SessionModel? = null
        set(value) {
            if (field === value) return
            field?.let {
                it.pictureSink = null
                it.clipboard = null
                it.setVideoSurface(null)
            }
            field = value
            renderer.session = value
            value?.pictureSink = renderer
            value?.clipboard = clipboard
            value?.onForgetTypedText = { forgetTypedText() }
            videoSurface?.let { value?.setVideoSurface(it) }
            imageSizeChanged()
        }

    var touchMode: TouchMode
        get() = gestures.mode
        set(value) {
            gestures.mode = value
        }

    /** The on-screen keyboard came or went (the key row follows it). */
    var onKeyboardVisible: (Boolean) -> Unit = {}
    var keyboardVisible = false
        private set
    private var keyboardTop: Float? = null
    private var videoSurface: android.view.Surface? = null

    private val clipboard = object : ClipboardBridge {
        override fun read(): String? = try {
            clipboardManager?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
        } catch (_: Exception) {
            null
        }

        override fun write(text: String) {
            clipboardManager?.setPrimaryClip(ClipData.newPlainText("Mac", text))
        }
    }
    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener { session?.sendChangedClipboard() }

    init {
        setEGLContextClientVersion(3)
        preserveEGLContextOnPause = true
        setRenderer(renderer)
        renderMode = RENDERMODE_WHEN_DIRTY
        isFocusable = true
        isFocusableInTouchMode = true
        // With a hardware keyboard Android tints the focused view (its default focus highlight): not the Mac's picture.
        defaultFocusHighlightEnabled = false
        renderer.onVideoSurface = { surface ->
            videoSurface = surface
            session?.setVideoSurface(surface)
        }
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            val ime = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
            val visible = insets.isVisible(WindowInsetsCompat.Type.ime()) && ime > 0
            keyboardTop = if (visible) (height - ime).toFloat() else null
            if (visible != keyboardVisible) {
                keyboardVisible = visible
                if (!visible) wantsKeyboard = false
                onKeyboardVisible(visible)
            }
            updateLift()
            insets
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        clipboardManager?.addPrimaryClipChangedListener(clipListener)
        pointerIcon = PointerIcon.getSystemIcon(context, PointerIcon.TYPE_NULL)
        requestFocus()
    }

    override fun onDetachedFromWindow() {
        clipboardManager?.removePrimaryClipChangedListener(clipListener)
        gestures.cancel()
        renderer.release()
        super.onDetachedFromWindow()
    }

    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        // Android lets an app read the clipboard only while it has the focus.
        if (hasWindowFocus) session?.sendChangedClipboard()
    }

    // The picture's place

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        imageSizeChanged()
        val session = session ?: return
        val metrics = resources.displayMetrics
        session.displayAreaChanged(
            ScreenArea(w / density.toDouble(), h / density.toDouble(), density.toDouble(), session.resolutionScale),
            metrics.widthPixels, metrics.heightPixels,
        )
    }

    /** The picture's size changed (or the session): fit it again. */
    fun imageSizeChanged() {
        val s = session
        viewport.layout(width.toFloat(), height.toFloat(), (s?.imageWidth ?: 0).toFloat(), (s?.imageHeight ?: 0).toFloat())
        updateLift()
    }

    fun fit() {
        viewport.fit()
        publish()
    }

    fun actualSize() {
        viewport.actualSize()
        publish()
    }

    /** Zooms onto a region of the picture (its pixels), as for a help request. */
    fun focus(x: Float, y: Float, w: Float, h: Float) {
        if (w <= 0 || h <= 0 || viewport.imageWidth <= 0) return
        val zoom = minOf(width / (w * 1.4f), height / (h * 1.4f)) / viewport.fitScale
        viewport.setZoom(zoom, x + w / 2, y + h / 2, width / 2f, height / 2f)
        session?.movePointer(x + w / 2, y + h / 2)
        publish()
    }

    private fun updateLift() {
        val s = session
        viewport.liftAbove(keyboardTop, s?.pointerY ?: 0f, 48f * density)
        publish()
    }

    private fun publish() {
        renderer.transform = PictureTransform(width.toFloat(), height.toFloat(), viewport.drawX, viewport.drawY, viewport.scale)
        requestRender()
    }

    private fun imageX(viewX: Float) = viewport.imagePointX(viewX)
    private fun imageY(viewY: Float) = viewport.imagePointY(viewY)

    // Fingers

    private inner class GestureSink : TouchGestures.Sink {
        override val isControlling: Boolean get() = session?.isControlling == true

        override fun movePointerBy(dx: Float, dy: Float, speed: Float) {
            val s = session ?: return
            // OSS: the finger's movement times the acceleration, in the picture's pixels (speed in dp a second).
            val gain = TouchGestures.pointerGain(speed / density)
            s.movePointerBy(dx * gain / viewport.scale, dy * gain / viewport.scale)
            keepPointerVisible()
        }

        override fun movePointerTo(x: Float, y: Float) {
            session?.movePointer(imageX(x), imageY(y))
            updateLift()
        }

        override fun press(button: Int) {
            session?.press(button)
        }

        override fun release(button: Int) {
            session?.release(button)
        }

        override fun click(button: Int) {
            session?.click(button)
        }

        override fun scroll(dx: Float, dy: Float, phase: ScrollPhase) {
            session?.scroll(dx / viewport.scale, dy / viewport.scale, phase)
        }

        override fun scrollEnded(velocityX: Float, velocityY: Float, cancelled: Boolean) {
            session?.scrollEnded(velocityX / viewport.scale, velocityY / viewport.scale, cancelled)
        }

        override fun zoom(factor: Float, fromX: Float, fromY: Float, toX: Float, toY: Float) {
            val anchorX = imageX(fromX)
            val anchorY = imageY(fromY)
            val zoom = viewport.zoom * factor
            if (zoom <= 1f) viewport.fit() else viewport.setZoom(zoom, anchorX, anchorY, toX, toY)
            updateLift()
        }

        override fun holdStarted() {
            performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        }
    }

    private fun keepPointerVisible() {
        val s = session ?: return
        if (viewport.zoom > 1f) viewport.keepVisible(s.pointerX, s.pointerY, 32f * density)
        updateLift()
    }

    private val holdRunnable = Runnable { gestures.hold(holdDownTime) }
    private var holdDownTime = 0L

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        session?.stopScrollMomentum()
        if (event.getToolType(0) == MotionEvent.TOOL_TYPE_MOUSE || event.isFromSource(InputDevice.SOURCE_MOUSE)) {
            return mouse(event)
        }
        val index = event.actionIndex
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                    requestFocus()
                    holdDownTime = event.eventTime
                    removeCallbacks(holdRunnable)
                    postDelayed(holdRunnable, gestures.holdDelayMillis)
                }
                gestures.down(event.getPointerId(index), event.getX(index), event.getY(index), event.eventTime)
            }
            MotionEvent.ACTION_MOVE -> {
                val moved = HashMap<Int, Pair<Float, Float>>()
                for (i in 0 until event.pointerCount) moved[event.getPointerId(i)] = event.getX(i) to event.getY(i)
                gestures.move(moved, event.eventTime)
            }
            MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_UP -> {
                removeCallbacks(holdRunnable)
                gestures.up(event.getPointerId(index), event.getX(index), event.getY(index), event.eventTime)
            }
            MotionEvent.ACTION_CANCEL -> {
                removeCallbacks(holdRunnable)
                gestures.cancel()
            }
        }
        return true
    }

    // A mouse or a trackpad of a keyboard case

    private fun mouse(event: MotionEvent): Boolean {
        val s = session ?: return true
        s.movePointer(imageX(event.x), imageY(event.y))
        var buttons = 0
        val state = event.buttonState
        if (state and MotionEvent.BUTTON_PRIMARY != 0) buttons = buttons or PointerButton.PRIMARY
        if (state and MotionEvent.BUTTON_SECONDARY != 0) buttons = buttons or PointerButton.SECONDARY
        if (state and MotionEvent.BUTTON_TERTIARY != 0) buttons = buttons or PointerButton.MIDDLE
        // A trackpad's tap comes without a button state
        if (state == 0 && event.actionMasked == MotionEvent.ACTION_DOWN) buttons = PointerButton.PRIMARY
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) buttons = 0
        s.setButtons(buttons)
        updateLift()
        return true
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        val s = session ?: return super.onGenericMotionEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_HOVER_MOVE, MotionEvent.ACTION_HOVER_ENTER -> {
                s.movePointer(imageX(event.x), imageY(event.y))
                return true
            }
            MotionEvent.ACTION_SCROLL -> {
                val v = event.getAxisValue(MotionEvent.AXIS_VSCROLL)
                val h = event.getAxisValue(MotionEvent.AXIS_HSCROLL)
                s.movePointer(imageX(event.x), imageY(event.y))
                s.scroll(-h * WHEEL_PIXELS, v * WHEEL_PIXELS, null)
                return true
            }
        }
        return super.onGenericMotionEvent(event)
    }

    override fun onResolvePointerIcon(event: MotionEvent, pointerIndex: Int): PointerIcon =
        PointerIcon.getSystemIcon(context, PointerIcon.TYPE_NULL)

    // Hardware keys

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean = key(keyCode, event, true) || super.onKeyDown(keyCode, event)
    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean = key(keyCode, event, false) || super.onKeyUp(keyCode, event)

    private fun key(keyCode: Int, event: KeyEvent, down: Boolean): Boolean {
        val s = session ?: return false
        if (AndroidKeys.isPhoneKey(keyCode)) return false
        val keyboard = s.keyboard
        if (event.deviceId == KeyCharacterMap.VIRTUAL_KEYBOARD || event.flags and KeyEvent.FLAG_SOFT_KEYBOARD != 0) {
            // The on-screen keyboard's keys (Return, Delete on an empty field, arrows): taps.
            if (!down) return true
            if (keyCode == KeyEvent.KEYCODE_DEL && input?.hasText == true) return false
            val key = when (keyCode) {
                KeyEvent.KEYCODE_DEL -> MacKey.BACKSPACE
                KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> MacKey.RETURN
                KeyEvent.KEYCODE_TAB -> MacKey.TAB
                KeyEvent.KEYCODE_ESCAPE -> MacKey.ESCAPE
                KeyEvent.KEYCODE_FORWARD_DEL -> MacKey.FORWARD_DELETE
                KeyEvent.KEYCODE_DPAD_LEFT -> MacKey.LEFT
                KeyEvent.KEYCODE_DPAD_RIGHT -> MacKey.RIGHT
                KeyEvent.KEYCODE_DPAD_UP -> MacKey.UP
                KeyEvent.KEYCODE_DPAD_DOWN -> MacKey.DOWN
                else -> null
            }
            if (key != null) {
                keyboard.typeKey(key)
                return true
            }
            val c = event.unicodeChar
            if (c != 0) keyboard.replaceText(0, String(Character.toChars(c)))
            return true
        }
        if (keyCode == KeyEvent.KEYCODE_CAPS_LOCK) {
            keyboard.capsLock(down)
            return true
        }
        if (!down) return keyboard.keyUp(keyCode)
        val held = AndroidKeys.heldModifiers(event.metaState)
        val typed = event.getUnicodeChar(event.metaState)
        val base = event.getUnicodeChar(event.metaState and (KeyEvent.META_CTRL_MASK or KeyEvent.META_ALT_MASK or KeyEvent.META_META_MASK).inv())
        val mapped = AndroidKeys.macKey(keyCode, held, typed, base, event.isCapsLockOn)
        return keyboard.keyDown(keyCode, held, mapped, repeat = event.repeatCount > 0)
    }

    // The on-screen keyboard

    private var input: ScreenInputConnection? = null

    /** The on-screen keyboard was asked for (its button): only then is the view a text editor, so a tap on the
     *  picture doesn't bring the keyboard up by itself. */
    private var wantsKeyboard = false

    fun showKeyboard(show: Boolean) {
        val imm = context.getSystemService(InputMethodManager::class.java) ?: return
        wantsKeyboard = show
        if (show) {
            requestFocus()
            imm.restartInput(this)
            imm.showSoftInput(this, 0)
        } else {
            imm.hideSoftInputFromWindow(windowToken, 0)
        }
    }

    /** The Mac's text cursor may have moved: what the keyboard typed so far no longer counts. */
    fun forgetTypedText() {
        val connection = input ?: return
        if (!connection.hasText) return
        connection.forget()
        context.getSystemService(InputMethodManager::class.java)?.restartInput(this)
    }

    override fun onCheckIsTextEditor(): Boolean = wantsKeyboard

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        // No editor until the keyboard is asked for: Android would bring it up by itself when the view gets the focus.
        if (!wantsKeyboard) return null
        // Plain keys: no suggestions, no autocorrection, no full-screen editor (what is typed goes to the Mac at once).
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or
            InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_ACTION_NONE
        outAttrs.initialSelStart = 0
        outAttrs.initialSelEnd = 0
        return ScreenInputConnection().also { input = it }
    }

    /**
     * What the on-screen keyboard types (KeyInputProxy): the field's text without what is still being composed is
     * compared with what was sent, and the difference goes to the Mac (backspaces, then the new text).
     */
    private inner class ScreenInputConnection : BaseInputConnection(this@RemoteScreenView, true) {
        private val text: Editable = Editable.Factory.getInstance().newEditable("")
        private var typed = ""

        val hasText: Boolean get() = text.isNotEmpty() || typed.isNotEmpty()

        override fun getEditable(): Editable = text

        override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean =
            super.commitText(text, newCursorPosition).also { changed() }

        override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean =
            super.setComposingText(text, newCursorPosition).also { changed() }

        override fun finishComposingText(): Boolean = super.finishComposingText().also { changed() }

        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
            if (text.isEmpty() && beforeLength > 0) {
                // Nothing typed here before the cursor: a backspace on the Mac.
                session?.keyboard?.replaceText(beforeLength.coerceAtMost(1), "")
                return true
            }
            return super.deleteSurroundingText(beforeLength, afterLength).also { changed() }
        }

        override fun performEditorAction(actionCode: Int): Boolean {
            session?.keyboard?.typeKey(MacKey.RETURN)
            return true
        }

        override fun performContextMenuAction(id: Int): Boolean {
            if (id == android.R.id.paste) {
                session?.sendClipboardToMac()
                session?.keyboard?.sendChord(KeyChord(listOf(ModifierKey.COMMAND), MacKey(9, 'v'.code)))
                return true
            }
            return super.performContextMenuAction(id)
        }

        private fun changed() {
            val composingStart = getComposingSpanStart(text)
            val composingEnd = getComposingSpanEnd(text)
            val now = if (composingStart in 0..composingEnd && composingEnd <= text.length)
                text.toString().removeRange(composingStart, composingEnd) else text.toString()
            if (now == typed) return
            val (deleting, inserting) = Keyboard.diff(typed, now)
            typed = now
            if (session?.keyboard?.replaceText(deleting, inserting) != true) forget()
            // Keep the field short: what was sent and isn't composing can go.
            if (composingStart < 0 && text.length > 64) forget()
        }

        fun forget() {
            typed = ""
            text.clear()
            Selection.setSelection(text, 0)
        }
    }

    companion object {
        /** A wheel notch scrolls this many picture pixels. */
        const val WHEEL_PIXELS = 40f
    }
}
