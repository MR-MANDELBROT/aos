package dev.marquart.aos.ui.demo

import dev.marquart.aos.companion.MockCompanionServer
import dev.marquart.aos.connection.FixedNetworkMonitor
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.connection.NoTailnet
import dev.marquart.aos.core.ApprovalRequest
import dev.marquart.aos.core.BitwardenLogin
import dev.marquart.aos.core.BitwardenState
import dev.marquart.aos.core.Bytes
import dev.marquart.aos.core.CompanionCommand
import dev.marquart.aos.core.CompanionEvent
import dev.marquart.aos.core.HelpRequest
import dev.marquart.aos.core.Iso8601
import dev.marquart.aos.core.Json
import dev.marquart.aos.core.MacAction
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.core.PairingLink
import dev.marquart.aos.core.ReachWay
import dev.marquart.aos.core.SignInRequest
import dev.marquart.aos.core.WorkspaceState
import dev.marquart.aos.keys.MemoryKeys
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.ssh.PairingClient
import dev.marquart.aos.ssh.SshConnector
import dev.marquart.aos.store.MemoryMacStore
import dev.marquart.aos.store.MemorySettingsStore
import dev.marquart.aos.ui.AosUi
import dev.marquart.aos.ui.LicenseKind
import dev.marquart.aos.ui.OverviewPage
import dev.marquart.aos.ui.SettingsPage
import dev.marquart.aos.ui.lock.AppLock
import dev.marquart.aos.ui.platform.Platform
import dev.marquart.aos.ui.platform.PlatformContext
import dev.marquart.aos.ui.tailnet.FakeTailnetControl
import dev.marquart.aos.ui.tailnet.TailnetInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.time.Instant

/**
 * Sample data for screenshots and UI work without a Mac (debug builds only; iOS Demo.swift). Android: start the app
 * with intent extras (app/.../ui/demo/DemoIntent.kt); the desktop: `--demo` and `--demo.<name>=<value>` arguments
 * (desktop/.../Main.kt):
 *
 *     adb shell am start -S -n dev.marquart.aos/.MainActivity --ez aos.demo true [--es aos.demo.sheet signin] ...
 *
 * - `aos.demo.tab` overview|terminal|screen|settings
 * - `aos.demo.sheet` signin|signin-code|signin-none|signin-locked|signin-off|approval|help|requests|pairing|pairing-scan|
 *   lock|chats|chat|apps|routines|routine-edit|settings|connection|mac|key|about|licenses|license
 * - `aos.demo.unpaired` true: the welcome page
 * - `aos.demo.theme` light|dark (instead of the system's)
 * - `aos.demo.session` needsLogin; `aos.demo.display` off|none; `aos.demo.chats` off; `aos.demo.sleeping` true;
 *   `aos.demo.workspace` starting|closing; `aos.demo.scroll` bottom; `aos.demo.tailnet` running|signin|none
 *
 * Nothing touches the Keystore, the stores or the network: the Mac is `MockCompanionServer` in memory.
 */
data class DemoOptions(
    val tab: String? = null,
    val sheet: String? = null,
    val unpaired: Boolean = false,
    val dark: Boolean? = null,
    val session: String? = null,
    val display: String? = null,
    val chats: String? = null,
    val sleeping: Boolean = false,
    val workspace: String? = null,
    val scrollToBottom: Boolean = false,
    val tailnet: String? = null,
) {
    /** The pairing page's link (`pairing`): its confirm step. */
    val pairingLink: PairingLink?
        get() = if (sheet == "pairing") PairingLink("Max’s MacBook Pro", listOf("Maxs-MacBook-Pro.local", "192.168.178.24", "100.101.7.12"),
            50123, 22, "max", "SHA256:IKIpT5qrBHciGB6LMk+7fuTQHDnNluSkoLBSGY4SWMQ", ByteArray(16) { it.toByte() }, ReachWay.AOS_TAILSCALE,
            listOf("100.101.7.12"), "max@marquart.dev") else null

    companion object {
        const val EXTRA = "aos.demo"
    }
}

object Demo {
    val mac = PairedMac(
        id = "demo-mac", name = "Max’s MacBook Pro",
        hosts = listOf("Maxs-MacBook-Pro.local", "192.168.178.24", "100.101.7.12", "maxs-macbook-pro.tail4c2a.ts.net"),
        sshPort = 22, user = "max", hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN8Rl2qwv75VjkzLHaW5OyZu4CaxGsZU2+cYoDrSFSrY",
        hostKeyFingerprint = "SHA256:IKIpT5qrBHciGB6LMk+7fuTQHDnNluSkoLBSGY4SWMQ", companionPath = CompanionCommand.DEFAULT_PATH,
        pairedAt = System.currentTimeMillis() - 9L * 24 * 3600 * 1000, lastHost = "Maxs-MacBook-Pro.local", way = ReachWay.AOS_TAILSCALE.raw,
        tailnetHosts = listOf("100.101.7.12", "maxs-macbook-pro.tail4c2a.ts.net"), tailnetName = "max@marquart.dev",
    )

    private val amazonLogins = listOf(
        BitwardenLogin("0b6d3f7e-1c2a-4e5b-9a8d-7c6b5a4f3e21", "Amazon", "max@marquart.dev", false),
        BitwardenLogin("4f2e8a1c-3b7d-4c9e-8f6a-1d2c3b4a5e6f", "Amazon Business", "einkauf@marquart.dev", true),
    )
    private val githubLogins = listOf(BitwardenLogin("9c8b7a6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d", "GitHub", "mr-mandelbrot", true))

    /** The demo's Mac status: the server's, with routines and apps on this phone. */
    private fun status(options: DemoOptions): JsonObject {
        val now = Instant.now()
        fun at(seconds: Long) = Iso8601.format(now.plusSeconds(seconds))
        val extra = Json.parseObject(Bytes.utf8("""
            {"routines":{"items":[
               {"id":"A1","name":"Morgenbriefing","schedule":"30 7 * * 1-5","prompt":"Fasse Mails und Termine zusammen","enabled":true,"next":"${at(14 * 3600)}"},
               {"id":"A2","name":"Repos aufräumen","schedule":"0 9-18/3 * * *","prompt":"Prüfe offene Branches","enabled":true,"next":"${at(5400)}"},
               {"id":"A3","name":"Wochenrückblick","schedule":"0 18 * * 0","prompt":"Schreib den Rückblick der Woche","enabled":false}],
             "reminders":[{"name":"Rechnung an die TUM schicken","at":"${at(26 * 3600)}"}],
             "queued":1,
             "recent":[{"kind":"routine","name":"Morgenbriefing","at":"${at(-3 * 3600)}"},{"kind":"note","name":"Cloupi","at":"${at(-7200)}"}]},
             "apps":{"state":"connected","since":"${at(-3 * 3600)}","network":"wifi","device":"iPhone von Max","previousSeconds":4210,
              "jobs":[{"id":"j3","name":"Tabby Focus","bundleId":"dev.marquart.saldo","state":"installing","created":"${at(-40)}","version":"1.4","source":"Claude Code"},
                      {"id":"j2","name":"aOS","bundleId":"dev.marquart.aos","state":"done","created":"${at(-3600)}","finished":"${at(-3570)}","seconds":28.4,"version":"0.1.0","source":"Claude Code"},
                      {"id":"j1","name":"Saldo","bundleId":"dev.marquart.saldo","state":"failed","created":"${at(-86400)}","finished":"${at(-86380)}","seconds":12,"network":"cellular","message":"The phone was locked."}]}}
        """.trimIndent()))!!
        var status = JsonObject(MockCompanionServer.demoMacStatus() + extra)
        if (options.session == "needsLogin") {
            status = JsonObject(status + ("session" to JsonObject(mapOf("enabled" to JsonPrimitive(true), "state" to JsonPrimitive("needsLogin")))))
        }
        options.display?.let {
            status = JsonObject(status + ("display" to JsonObject(mapOf("state" to JsonPrimitive(it), "external" to JsonPrimitive(0)))))
        }
        if (options.workspace == "starting") {
            status = JsonObject(status + ("workspace" to JsonObject(mapOf("state" to JsonPrimitive("stopped"), "setupComplete" to JsonPrimitive(true)))))
        }
        return status
    }

    /** The demo's UI. `deviceName`: what this device calls itself in the sample (a phone, a PC). */
    fun makeUi(context: PlatformContext, options: DemoOptions, deviceName: String = "Pixel 9"): AosUi {
        val server = MockCompanionServer()
        server.update { s ->
            s.macStatus = status(options)
            // Starting and closing the workspace take a moment, as on the Mac (a minute per step for the screenshots).
            s.workspaceStepMillis = if (options.workspace != null) 60_000 else 2_000
            if (options.workspace == "starting") s.workspace = s.workspace.copy(state = WorkspaceState.STOPPED)
            if (options.chats == "off") s.chatsEnabled = false
        }
        val settings = MemorySettingsStore()
        val model = AppModel(
            keys = MemoryKeys(), macStore = MemoryMacStore(if (options.unpaired) emptyList() else listOf(mac)), settings = settings,
            connector = SshConnector(), pairingClient = PairingClient(), network = FixedNetworkMonitor(), tailnet = NoTailnet,
            defaultDeviceName = deviceName, appVersion = Platform.current.appVersion, connectionTiming = MacConnection.Timing(), demo = server,
        )
        val tailnet = when (options.tailnet) {
            "none" -> FakeTailnetControl()
            "signin" -> FakeTailnetControl(TailnetInfo("NeedsLogin"))
            else -> FakeTailnetControl(TailnetInfo("Running", tailnet = "max@marquart.dev", dnsName = "aos-pixel-9.tail4c2a.ts.net",
                addresses = listOf("100.88.14.3", "fd7a:115c:a1e0::9c01:e03"), keyExpiry = Iso8601.format(Instant.now().plusSeconds(170L * 86400))))
        }
        val ui = AosUi(context, model, settings, AppLock(settings), MemoryKeys(), tailnet, FixedNetworkMonitor(), options)
        CoroutineScope(SupervisorJob() + Dispatchers.Main).launch {
            model.load()
            script(ui, server, options)
        }
        return ui
    }

    private suspend fun script(ui: AosUi, server: MockCompanionServer, o: DemoOptions) {
        val model = ui.model
        when (o.tab) {
            "terminal" -> model.selectTab(AppModel.Tab.TERMINAL)
            "screen" -> model.selectTab(AppModel.Tab.SCREEN)
            "settings" -> model.selectTab(AppModel.Tab.SETTINGS)
        }
        when (o.sheet) {
            "pairing", "pairing-scan" -> ui.startPairing()
            "lock" -> ui.lock.lockNow()
            "settings" -> model.selectTab(AppModel.Tab.SETTINGS)
            "connection" -> settings(ui, SettingsPage.Connection)
            "mac" -> settings(ui, SettingsPage.Mac(mac.id))
            "key" -> settings(ui, SettingsPage.DeviceKey)
            "about" -> settings(ui, SettingsPage.About)
            "licenses" -> settings(ui, SettingsPage.Acknowledgements)
            "license" -> settings(ui, SettingsPage.Acknowledgements, SettingsPage.License(LicenseKind.OPEN_SCREEN_SHARING))
        }
        val connection = model.connection.value ?: return
        // Once the demo's Mac answers
        repeat(100) { if (connection.companionState.value != MacConnection.CompanionState.Ready) delay(100) }
        if (o.sleeping) connection.macGoesToSleep(0.0)
        if (o.workspace != null) {
            connection.refreshMacStatus()
            delay(500)
            runCatching { connection.perform(if (o.workspace == "starting") MacAction.WORKSPACE_START else MacAction.WORKSPACE_STOP) }
        }
        delay(300)
        val expires = { seconds: Long -> Instant.now().plusSeconds(seconds) }
        when (o.sheet) {
            "signin" -> server.emit(CompanionEvent.SignIn(SignInRequest("demo-1", "Claude Code", "www.amazon.de",
                "Die Rechnung vom Oktober herunterladen", expires(4 * 60 + 32), logins = amazonLogins, bitwarden = BitwardenState.UNLOCKED)))
            "signin-code" -> server.emit(CompanionEvent.SignIn(SignInRequest("demo-3", "Claude Code", "github.com",
                "Mit dem Code aus der App anmelden", expires(2 * 60 + 10), SignInRequest.Field.CODE, githubLogins, BitwardenState.UNLOCKED)))
            "signin-locked" -> server.emit(CompanionEvent.SignIn(SignInRequest("demo-5", "Claude Code", "www.amazon.de",
                "Die Rechnung vom Oktober herunterladen", expires(4 * 60), bitwarden = BitwardenState.LOCKED)))
            "signin-off" -> server.emit(CompanionEvent.SignIn(SignInRequest("demo-6", "Codex", "portal.example-energie.de",
                "Zählerstand eintragen", expires(3 * 60), bitwarden = BitwardenState.OFF)))
            "signin-none" -> server.emit(CompanionEvent.SignIn(SignInRequest("demo-2", "Codex", "portal.example-energie.de",
                "Zählerstand eintragen", expires(3 * 60), bitwarden = BitwardenState.UNLOCKED)))
            "approval" -> server.emit(CompanionEvent.Approval(ApprovalRequest("demo-4", "Codex", "Die Rechnungen vom Oktober herunterladen",
                30, expires(4 * 60 + 50))))
            "help" -> server.emit(CompanionEvent.Help(HelpRequest("help-1", "Claude Code", "Bitte das Captcha auf der Anmeldeseite lösen",
                HelpRequest.Region(470.0, 440.0, 340.0, 100.0))))
            "requests" -> {
                server.emit(CompanionEvent.SignIn(SignInRequest("demo-1", "Claude Code", "www.amazon.de",
                    "Die Rechnung vom Oktober herunterladen", expires(4 * 60 + 32), logins = amazonLogins, bitwarden = BitwardenState.UNLOCKED)))
                server.emit(CompanionEvent.Approval(ApprovalRequest("demo-4", "Codex", "Die Rechnungen vom Oktober herunterladen",
                    30, expires(4 * 60 + 50))))
                delay(300)
                model.closeQuestionSheet()
                delay(600)
                model.closeQuestionSheet()
            }
            "chats", "chat" -> {
                connection.refreshChats()
                val chats = connection.chats.value?.chats.orEmpty()
                val chat = chats.firstOrNull { it.state == "needsAttention" } ?: chats.firstOrNull()
                if (o.sheet == "chat" && chat != null) ui.overview.set(OverviewPage.Chats, OverviewPage.Chat(chat.id))
                else ui.overview.set(OverviewPage.Chats)
            }
            "apps" -> ui.overview.set(OverviewPage.Apps)
            "routines", "routine-edit" -> ui.overview.set(OverviewPage.Routines)
        }
        // The help request opens the Screen tab like a real one; for its banner on the Overview, back there.
        if (o.sheet == "help" && o.tab == "overview") {
            delay(800)
            model.selectTab(AppModel.Tab.OVERVIEW)
        }
    }

    private fun settings(ui: AosUi, vararg pages: SettingsPage) {
        ui.model.selectTab(AppModel.Tab.SETTINGS)
        ui.settingsPages.set(*pages)
    }
}
