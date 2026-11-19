// The Mac's screen login behind the phone's lock: read once per connect after the fingerprint, the face or the screen
// lock (the iPhone's Face ID, ScreenSession.unlockLogin), kept in memory for that connect only. Written for aOS's
// Android app on 2026-11-19.

package dev.marquart.aos.screen

import android.app.KeyguardManager
import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import dev.marquart.aos.R
import dev.marquart.aos.core.PairedMac
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** The Mac's login after the phone's lock (null: none kept). Throws `UnlockCancelled` when the person cancels. */
suspend fun unlockMacLogin(context: Context, store: ScreenStore, mac: PairedMac): MacLogin? {
    if (!store.hasMacLogin(mac.id)) return null
    if (!isDeviceSecure(context)) throw IllegalStateException(context.getString(R.string.screen_set_screen_lock))
    authenticate(context, context.getString(R.string.screen_unlock_title, mac.name))
    return store.macLogin(mac.id)
}

/** Keeps a login just typed (it is used as it is for this connect). False: it couldn't be kept (no screen lock). */
suspend fun saveMacLogin(context: Context, store: ScreenStore, mac: PairedMac, login: MacLogin): Boolean {
    if (!isDeviceSecure(context)) {
        android.widget.Toast.makeText(context, R.string.screen_set_screen_lock, android.widget.Toast.LENGTH_LONG).show()
        return false
    }
    store.setMacLogin(mac.id, login)
    return true
}

private fun isDeviceSecure(context: Context): Boolean =
    context.getSystemService(KeyguardManager::class.java)?.isDeviceSecure == true

private suspend fun authenticate(context: Context, title: String) {
    val activity = context.findActivity() ?: throw IllegalStateException("no activity")
    suspendCancellableCoroutine { continuation ->
        val builder = BiometricPrompt.Builder(activity).setTitle(title)
        if (Build.VERSION.SDK_INT >= 30) {
            builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL)
        } else {
            @Suppress("DEPRECATION")
            builder.setDeviceCredentialAllowed(true)
        }
        val cancel = CancellationSignal()
        continuation.invokeOnCancellation { cancel.cancel() }
        builder.build().authenticate(cancel, activity.mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                if (continuation.isActive) continuation.resume(Unit)
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                if (!continuation.isActive) return
                if (errorCode == BiometricPrompt.BIOMETRIC_ERROR_CANCELED || errorCode == BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED) {
                    continuation.resumeWithException(UnlockCancelled())
                } else {
                    continuation.resumeWithException(IllegalStateException(errString.toString()))
                }
            }
        })
    }
}
