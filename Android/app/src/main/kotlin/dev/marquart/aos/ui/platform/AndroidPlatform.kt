package dev.marquart.aos.ui.platform

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import dev.marquart.aos.BuildConfig
import dev.marquart.aos.ui.lock.Biometrics
import dev.marquart.aos.ui.pairing.CameraBox
import java.lang.ref.WeakReference

/** What the shared UI asks of Android (see Platform.kt). Made once by AosApp. */
class AndroidPlatform(private val app: Application) : Platform {
    /** The activity in front (the biometric prompt needs one). */
    private var activity = WeakReference<FragmentActivity>(null)

    init {
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(a: Activity) {
                if (a is FragmentActivity) activity = WeakReference(a)
            }
            override fun onActivityCreated(a: Activity, state: Bundle?) {
                if (a is FragmentActivity) activity = WeakReference(a)
            }
            override fun onActivityDestroyed(a: Activity) {
                if (activity.get() === a) activity = WeakReference(null)
            }
            override fun onActivityStarted(a: Activity) {}
            override fun onActivityPaused(a: Activity) {}
            override fun onActivityStopped(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, state: Bundle) {}
        })
    }

    override val kind = PlatformKind.ANDROID
    override val appVersion: String = BuildConfig.VERSION_NAME

    /** Opens a page in a Custom Tab (the browser if there is none). */
    override fun openWeb(url: String) {
        val context: Context = activity.get() ?: app
        try {
            CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, Uri.parse(url))
        } catch (_: Exception) {
            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        }
    }

    override fun copyToClipboard(text: String, label: String) {
        app.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText(label, text))
    }

    override fun clipboardText(): String? {
        val clip = app.getSystemService(ClipboardManager::class.java)?.primaryClip
        return clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(app)?.toString()
    }

    override fun share(text: String): Boolean {
        val context: Context = activity.get() ?: return false
        context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), null))
        return true
    }

    override suspend fun confirmPresence(reason: String): PresenceOutcome {
        val current = activity.get() ?: return PresenceOutcome.FAILED
        return Biometrics.authenticate(current, reason)
    }

    override fun notificationsEnabled(): Boolean = NotificationManagerCompat.from(app).areNotificationsEnabled()

    @Composable
    override fun rememberNotificationsAction(changed: () -> Unit): () -> Unit {
        val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { changed() }
        return {
            val canAsk = Build.VERSION.SDK_INT >= 33 &&
                ContextCompat.checkSelfPermission(app, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            if (canAsk && !notificationsEnabled()) launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
            else (activity.get() ?: app).startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, app.packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    @Composable
    override fun rememberNotificationPermissionRequest(): (() -> Unit)? {
        if (Build.VERSION.SDK_INT < 33) return null
        val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
        return { launcher.launch(Manifest.permission.POST_NOTIFICATIONS) }
    }

    @Composable
    override fun BackHandler(enabled: Boolean, onBack: () -> Unit) = androidx.activity.compose.BackHandler(enabled, onBack)

    @Composable
    override fun isActive(): Boolean {
        val state by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
        return state.isAtLeast(Lifecycle.State.RESUMED)
    }

    override val pairingScanner: (@Composable (Modifier, Boolean, (String) -> Unit) -> Unit) = { modifier, demo, onCode ->
        CameraBox(modifier, demo, onCode)
    }
}
