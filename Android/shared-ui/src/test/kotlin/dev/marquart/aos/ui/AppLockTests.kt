package dev.marquart.aos.ui

import dev.marquart.aos.ui.platform.PresenceOutcome
import dev.marquart.aos.store.AppSettings
import dev.marquart.aos.store.MemorySettingsStore
import dev.marquart.aos.ui.lock.AppLock
import kotlinx.coroutines.runBlocking
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** "Unlock to open aOS": locked at launch, again after the chosen time in the background. */
class AppLockTests {
    private var now = 1_000_000L

    @Test fun lockedAtLaunchOnlyWhenRequired() {
        assertFalse(AppLock(MemorySettingsStore()) { now }.isLocked.value)
        assertTrue(AppLock(MemorySettingsStore(AppSettings(requireUnlock = true))) { now }.isLocked.value)
    }

    @Test fun locksAgainAfterTheChosenMinutes() {
        val lock = AppLock(MemorySettingsStore(AppSettings(requireUnlock = true, autoLockMinutes = 5))) { now }
        lock.unlocked(PresenceOutcome.SUCCESS)
        assertFalse(lock.isLocked.value)
        lock.onBackground()
        now += 4 * 60_000
        lock.onForeground()
        assertFalse(lock.isLocked.value)
        lock.onBackground()
        now += 5 * 60_000
        lock.onForeground()
        assertTrue(lock.isLocked.value)
    }

    @Test fun unlockOutcomes() {
        val lock = AppLock(MemorySettingsStore(AppSettings(requireUnlock = true))) { now }
        lock.unlocked(PresenceOutcome.CANCELLED)
        assertTrue(lock.isLocked.value)
        assertFalse(lock.failed.value)
        lock.unlocked(PresenceOutcome.FAILED)
        assertTrue(lock.failed.value)
        // A phone without a screen lock can't lock the app: it doesn't block.
        lock.unlocked(PresenceOutcome.UNAVAILABLE)
        assertFalse(lock.isLocked.value)
    }

    @Test fun turningOnNeedsTheScreenLock() = runBlocking {
        val settings = MemorySettingsStore()
        val lock = AppLock(settings) { now }
        assertFalse(lock.setRequired(true, PresenceOutcome.CANCELLED))
        assertEquals(false, settings.current().requireUnlock)
        assertTrue(lock.setRequired(true, PresenceOutcome.SUCCESS))
        assertEquals(true, settings.current().requireUnlock)
        assertTrue(lock.setRequired(false))
        assertEquals(false, settings.current().requireUnlock)
    }
}
