package dev.marquart.aos.terminal

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The terminal's settings and the session each Mac's terminal showed last (iOS AppSettings' terminal part and the
 * UserDefaults key `terminal.session.<target>`). SharedPreferences of their own ("terminal"): read synchronously when a
 * terminal is made, nothing secret in them, excluded from backups like everything of the app.
 */
class TerminalSettings private constructor(context: Context) : SessionMemory {
    private val prefs = context.applicationContext.getSharedPreferences("terminal", Context.MODE_PRIVATE)

    private val _fontSize = MutableStateFlow(prefs.getInt(FONT_SIZE, TerminalFontSize.STANDARD).coerceIn(TerminalFontSize.MIN, TerminalFontSize.MAX))
    private val _arrowKeys = MutableStateFlow(
        runCatching { TerminalArrowKeys.valueOf(prefs.getString(ARROW_KEYS, null) ?: "") }.getOrDefault(TerminalArrowKeys.PAD))
    private val _swipeArrows = MutableStateFlow(prefs.getBoolean(SWIPE_ARROWS, true))
    private val _keepConnected = MutableStateFlow(prefs.getBoolean(KEEP_CONNECTED, true))
    private val _keepScreenOn = MutableStateFlow(prefs.getBoolean(KEEP_SCREEN_ON, false))

    /** sp, 8 to 28. */
    val fontSize: StateFlow<Int> = _fontSize.asStateFlow()

    /** The arrows in the middle of the key bar: the swipe pad or four keys. */
    val arrowKeys: StateFlow<TerminalArrowKeys> = _arrowKeys.asStateFlow()

    /** Swiping on the terminal sends arrow keys (TerminalSwipe). */
    val swipeArrows: StateFlow<Boolean> = _swipeArrows.asStateFlow()

    /** While a terminal is open, a foreground service keeps the connection when the app is in the background. */
    val keepConnected: StateFlow<Boolean> = _keepConnected.asStateFlow()

    /** The screen stays on while a terminal is open and connected. */
    val keepScreenOn: StateFlow<Boolean> = _keepScreenOn.asStateFlow()

    fun setFontSize(size: Int) {
        val clamped = size.coerceIn(TerminalFontSize.MIN, TerminalFontSize.MAX)
        _fontSize.value = clamped
        prefs.edit().putInt(FONT_SIZE, clamped).apply()
    }

    fun setArrowKeys(arrows: TerminalArrowKeys) {
        _arrowKeys.value = arrows
        prefs.edit().putString(ARROW_KEYS, arrows.name).apply()
    }

    fun setSwipeArrows(on: Boolean) {
        _swipeArrows.value = on
        prefs.edit().putBoolean(SWIPE_ARROWS, on).apply()
    }

    fun setKeepConnected(on: Boolean) {
        _keepConnected.value = on
        prefs.edit().putBoolean(KEEP_CONNECTED, on).apply()
    }

    fun setKeepScreenOn(on: Boolean) {
        _keepScreenOn.value = on
        prefs.edit().putBoolean(KEEP_SCREEN_ON, on).apply()
    }

    /** The notification permission was asked for once (Android 13+); not again from the terminal. */
    var askedForNotifications: Boolean
        get() = prefs.getBoolean(ASKED_NOTIFICATIONS, false)
        set(value) = prefs.edit().putBoolean(ASKED_NOTIFICATIONS, value).apply()

    override fun holderId(macId: String): String? = prefs.getString(SESSION + macId, null)

    override fun setHolderId(macId: String, id: String?) {
        prefs.edit().apply { if (id == null) remove(SESSION + macId) else putString(SESSION + macId, id) }.apply()
    }

    companion object {
        @Volatile private var instance: TerminalSettings? = null

        /** One per process (the settings page and the terminals see the same values). */
        fun get(context: Context): TerminalSettings = instance ?: synchronized(this) {
            instance ?: TerminalSettings(context.applicationContext).also { instance = it }
        }

        private const val FONT_SIZE = "fontSize"
        private const val ARROW_KEYS = "arrowKeys"
        private const val SWIPE_ARROWS = "swipeArrows"
        private const val KEEP_CONNECTED = "keepConnected"
        private const val KEEP_SCREEN_ON = "keepScreenOn"
        private const val ASKED_NOTIFICATIONS = "askedNotifications"
        private const val SESSION = "session."
    }
}
