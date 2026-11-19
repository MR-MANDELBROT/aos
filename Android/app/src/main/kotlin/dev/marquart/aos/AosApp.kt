package dev.marquart.aos

import android.app.Application
import android.os.Build
import android.provider.Settings
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import dev.marquart.aos.connection.AndroidNetworkMonitor
import dev.marquart.aos.connection.Tailnets
import dev.marquart.aos.connection.NsdServiceDiscovery
import dev.marquart.aos.connection.TailnetDialer
import dev.marquart.aos.keys.KeystoreOrMemoryKeys
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.ssh.PairingClient
import dev.marquart.aos.ssh.SshConnector
import dev.marquart.aos.store.DataStoreMacStore
import dev.marquart.aos.store.DataStoreSettingsStore
import dev.marquart.aos.store.KeystoreSecretStore
import dev.marquart.aos.ui.lock.AppLock
import dev.marquart.aos.ui.notify.RequestNotifier
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** The app's process: builds the object graph once and follows the app into and out of the foreground. */
class AosApp : Application() {
    lateinit var graph: AppGraph
        private set

    override fun onCreate() {
        super.onCreate()
        SshConnector.useHomeFolder(java.io.File(noBackupFilesDir, "ssh-home"))
        graph = AppGraph(this)
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                graph.lock.onForeground()
                graph.notifier.clear()
                graph.model.onForeground()
            }

            override fun onStop(owner: LifecycleOwner) {
                graph.lock.onBackground()
                graph.model.onBackground()
            }
        })
        graph.notifier.start()
        graph.network.start()
        CoroutineScope(SupervisorJob() + Dispatchers.Default).launch { graph.model.load() }
    }
}

/**
 * Everything the app is made of, wired once. Later modules plug in here: `tailnet` is aOS's own Tailscale node
 * (`TailnetDialer`; `EmbeddedTailnet` with the Go library, src/tailnet), the UI reads `model`, the terminal and the screen use `model.connection`.
 */
class AppGraph(app: Application) {
    val keys = KeystoreOrMemoryKeys()

    /** aOS's own Tailscale node (`EmbeddedTailnet` when built with the Go library, else `NoTailnet`). */
    val tailnet: TailnetDialer = Tailnets.create(app, deviceName(app))
    val network = AndroidNetworkMonitor(app)
    val discovery = NsdServiceDiscovery(app)
    val connector = SshConnector(tailnet = tailnet, discovery = discovery)
    val pairingClient = PairingClient(discovery)
    val macStore = DataStoreMacStore(app)
    val settings = DataStoreSettingsStore(app)
    val secrets = KeystoreSecretStore(app)
    val model = AppModel(
        keys = keys, macStore = macStore, settings = settings, connector = connector, pairingClient = pairingClient,
        network = network, tailnet = tailnet, defaultDeviceName = deviceName(app), appVersion = BuildConfig.VERSION_NAME,
    )

    /** "Unlock to open aOS" (ui/lock). */
    val lock = AppLock(settings)

    /** Requests that come while the app is in the background (ui/notify). */
    val notifier = RequestNotifier(app, model)

    private fun deviceName(app: Application): String =
        Settings.Global.getString(app.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: "${Build.MANUFACTURER} ${Build.MODEL}".trim()
}
