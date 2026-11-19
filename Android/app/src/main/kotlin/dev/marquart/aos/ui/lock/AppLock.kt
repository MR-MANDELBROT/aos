package dev.marquart.aos.ui.lock

import dev.marquart.aos.store.SettingsStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/**
 * "Unlock to open aOS" (iOS AppLock): locked at launch and after the chosen time in the background. Unlocking and
 * turning the lock on go through the biometric prompt (the views run it and report back here); a phone without a
 * screen lock can't lock the app, so it doesn't block.
 */
class AppLock(private val settings: SettingsStore, private val clock: () -> Long = System::currentTimeMillis) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** The settings as they were last read (the lock decides synchronously). */
    @Volatile private var requireUnlock: Boolean
    @Volatile private var autoLockMinutes: Int

    private val _isLocked: MutableStateFlow<Boolean>
    val isLocked: StateFlow<Boolean>

    /** Why the last unlock didn't work (shown on the lock screen); null after a cancel. */
    private val _failed = MutableStateFlow(false)
    val failed: StateFlow<Boolean> = _failed.asStateFlow()

    private var backgroundedAt: Long? = null

    init {
        // The lock must be there before the first frame: one short read of the settings at start.
        val current = runBlocking(Dispatchers.IO) { settings.current() }
        requireUnlock = current.requireUnlock
        autoLockMinutes = current.autoLockMinutes
        _isLocked = MutableStateFlow(requireUnlock)
        isLocked = _isLocked.asStateFlow()
        scope.launch {
            settings.settings.collect {
                requireUnlock = it.requireUnlock
                autoLockMinutes = it.autoLockMinutes
                if (!it.requireUnlock) _isLocked.value = false
            }
        }
    }

    val isRequired: Boolean get() = requireUnlock

    fun onBackground() {
        if (backgroundedAt == null) backgroundedAt = clock()
    }

    fun onForeground() {
        val since = backgroundedAt
        backgroundedAt = null
        if (!requireUnlock || since == null) return
        if (clock() - since >= autoLockMinutes * 60_000L) _isLocked.value = true
    }

    /** What the prompt said. */
    fun unlocked(outcome: Biometrics.Outcome) {
        when (outcome) {
            Biometrics.Outcome.SUCCESS, Biometrics.Outcome.UNAVAILABLE -> {
                _isLocked.value = false
                _failed.value = false
            }
            Biometrics.Outcome.CANCELLED -> _failed.value = false
            Biometrics.Outcome.FAILED -> _failed.value = true
        }
    }

    /** Turning the lock on needs a successful prompt first (nobody locks the owner out by accident). */
    suspend fun setRequired(required: Boolean, outcome: Biometrics.Outcome? = null): Boolean {
        if (required && outcome != Biometrics.Outcome.SUCCESS) return false
        requireUnlock = required
        settings.update { it.copy(requireUnlock = required) }
        return true
    }

    suspend fun setAutoLockMinutes(minutes: Int) {
        autoLockMinutes = minutes
        settings.update { it.copy(autoLockMinutes = minutes) }
    }

    /** The demo's lock screen. */
    fun lockNow() {
        _isLocked.value = true
    }

    companion object {
        val AUTO_LOCK_CHOICES = listOf(0, 1, 5, 15, 60)
    }
}
