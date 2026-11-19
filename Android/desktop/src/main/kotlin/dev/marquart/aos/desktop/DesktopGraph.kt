package dev.marquart.aos.desktop

import dev.marquart.aos.connection.NetworkMonitor
import dev.marquart.aos.connection.TailnetDialer
import dev.marquart.aos.desktop.connection.JmdnsDiscovery
import dev.marquart.aos.desktop.connection.PollingNetworkMonitor
import dev.marquart.aos.desktop.keys.DesktopKeys
import dev.marquart.aos.desktop.keys.SecretServiceSealer
import dev.marquart.aos.desktop.native.DpapiSealer
import dev.marquart.aos.desktop.store.DesktopSecretStore
import dev.marquart.aos.desktop.store.FileMacStore
import dev.marquart.aos.desktop.store.FileSettingsStore
import dev.marquart.aos.desktop.store.PlainSealer
import dev.marquart.aos.desktop.store.Prefs
import dev.marquart.aos.desktop.store.Sealer
import dev.marquart.aos.desktop.system.DesktopSettings
import dev.marquart.aos.keys.KeyProvider
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.ssh.PairingClient
import dev.marquart.aos.ssh.SshConnector
import dev.marquart.aos.store.SecretStore
import dev.marquart.aos.store.SettingsStore
import dev.marquart.aos.ui.lock.AppLock

/** Everything the desktop app is made of, wired once (Android: AppGraph in AosApp.kt). */
class DesktopGraph {
    val desktopSettings = DesktopSettings(Prefs.named("desktop"))

    /** How secrets and the key files are protected: DPAPI (Windows), the Secret Service (Linux), else nothing. */
    val sealer: Sealer = when {
        Os.isWindows -> DpapiSealer
        Os.isLinux -> SecretServiceSealer.open() ?: PlainSealer
        else -> PlainSealer
    }
    val keys: KeyProvider = DesktopKeys.create(sealer)
    val deviceName: String = Os.computerName()

    /** aOS's own Tailscale node (with the desktop Go library), else none. */
    val tailnet: TailnetDialer = GoLibrary.tailnet(deviceName)
    val network: NetworkMonitor = PollingNetworkMonitor()
    val discovery = JmdnsDiscovery()
    val connector = SshConnector(tailnet = tailnet, discovery = discovery)
    val pairingClient = PairingClient(discovery)
    val macStore = FileMacStore()
    val settings: SettingsStore = FileSettingsStore()
    val secrets: SecretStore = DesktopSecretStore(sealer)
    val model = AppModel(
        keys = keys, macStore = macStore, settings = settings, connector = connector, pairingClient = pairingClient,
        network = network, tailnet = tailnet, defaultDeviceName = deviceName, appVersion = BuildInfo.VERSION,
    )
    val lock = AppLock(settings)

    companion object {
        /** The running app's graph (null in the demo). */
        @Volatile var current: DesktopGraph? = null
    }

    init {
        // In the tray the app stays connected (requests arrive as notifications), as long as it keeps running there.
        model.holdsConnectionInBackground = { desktopSettings.keepRunning.value }
    }
}
