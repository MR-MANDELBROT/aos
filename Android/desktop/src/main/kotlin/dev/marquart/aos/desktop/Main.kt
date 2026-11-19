package dev.marquart.aos.desktop

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import dev.marquart.aos.desktop.system.Autostart
import dev.marquart.aos.desktop.system.Notifier
import dev.marquart.aos.desktop.system.PasswordPrompt
import dev.marquart.aos.desktop.system.PasswordPromptHost
import dev.marquart.aos.desktop.system.Presence
import dev.marquart.aos.desktop.system.SingleInstance
import dev.marquart.aos.desktop.system.TrayHost
import dev.marquart.aos.desktop.system.UrlScheme
import dev.marquart.aos.ssh.SshConnector
import dev.marquart.aos.ui.AosRoot
import dev.marquart.aos.ui.AosUi
import dev.marquart.aos.ui.demo.Demo
import dev.marquart.aos.ui.demo.DemoOptions
import dev.marquart.aos.ui.platform.DesktopPlatform
import dev.marquart.aos.ui.platform.LocalPlatformContext
import dev.marquart.aos.ui.platform.Platform
import dev.marquart.aos.ui.platform.PlatformContext
import dev.marquart.aos.ui.tabs.installSettingsSlots
import dev.marquart.aos.ui.theme.AosTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File
import kotlin.system.exitProcess

/**
 * aOS for Windows and Linux. Arguments:
 *
 * - an `aos-pair://` link: pairing with it (the URL handler starts the app like that)
 * - `--background`: start hidden in the tray (start at login)
 * - `--demo` with `--demo.<name>=<value>` (Demo.kt's options: tab, sheet, unpaired, theme, ...): sample data, nothing
 *   is stored or sent
 * - `--shot=<file.png>` (with `--demo`): renders one picture of the window (`--size=1100x760`, `--wait=2500` ms) and
 *   ends (Tools/desktop.sh screenshots)
 */
fun main(args: Array<String>) {
    val options = Arguments(args)
    System.setProperty("apple.awt.application.name", "aOS")
    options.lang?.let { DesktopStrings.use(java.util.Locale.forLanguageTag(it)) }
    installSettingsSlots()

    if (options.demo != null || options.shots != null) {
        runDemo(options)
        return
    }

    val instance = SingleInstance()
    if (instance.handOver(options.link ?: "show")) exitProcess(0)

    SshConnector.useHomeFolder(Os.privateDir(File(Os.configDir, "ssh-home")))
    val graph = DesktopGraph()
    dev.marquart.aos.desktop.screen.DesktopScreens.secrets = graph.secrets
    DesktopGraph.current = graph
    val prompt = PasswordPrompt()
    var window: java.awt.Window? = null
    val presence = Presence({ graph.desktopSettings.presence.value }, { window }, prompt::ask)
    val platform = DesktopPlatform(presence::confirm, { graph.desktopSettings.notifications.value },
        { graph.desktopSettings.setNotifications(!graph.desktopSettings.notifications.value) })
    Platform.current = platform
    val ui = AosUi(PlatformContext(DesktopStrings.locale), graph.model, graph.settings, graph.lock, graph.keys,
        GoLibrary.tailnetControl(graph.tailnet), graph.network)
    options.link?.let { ui.startPairing(it) }

    if (!graph.desktopSettings.firstStartDone) graph.desktopSettings.firstStartDone = true
    UrlScheme.register()
    if (Autostart.isSupported) runCatching { Autostart.set(graph.desktopSettings.startAtLogin.value) }

    graph.network.start()
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    scope.launch { graph.model.load() }
    val notifier = Notifier(graph.model, graph.desktopSettings)

    application(exitProcessOnExit = true) {
        var visible by remember { mutableStateOf(!options.background) }
        val keepRunning by graph.desktopSettings.keepRunning.collectAsState()
        fun show() {
            visible = true
            window?.let { it.toFront(); it.requestFocus() }
        }
        val tray = TrayHost(graph.model, open = ::show, quit = {
            instance.close()
            exitApplication()
        })
        LaunchedEffect(Unit) {
            instance.listen { message ->
                CoroutineScope(Dispatchers.Main).launch {
                    if (message.startsWith("aos-pair:", ignoreCase = true)) ui.startPairing(message)
                    show()
                }
            }
            notifier.start(tray, isShown = { visible && platform.windowActive }, open = { id ->
                notifier.openRequest(id, ui)
                show()
            })
        }
        LaunchedEffect(visible) {
            platform.windowActive = visible
            if (visible) {
                graph.lock.onForeground()
                graph.model.onForeground()
                notifier.clear()
            } else {
                graph.lock.onBackground()
                graph.model.onBackground()
            }
        }
        val state = rememberWindowState(size = DpSize(1100.dp, 760.dp), position = WindowPosition.PlatformDefault)
        Window(
            onCloseRequest = {
                if (keepRunning && tray.isSupported) visible = false
                else {
                    instance.close()
                    exitApplication()
                }
            },
            visible = visible,
            state = state,
            title = "aOS",
            icon = AppIcon.painter(),
            onPreviewKeyEvent = { event ->
                event.type == KeyEventType.KeyDown && event.key == Key.Escape && platform.back()
            },
        ) {
            window = this.window
            this.window.minimumSize = java.awt.Dimension(720, 520)
            AppContent(ui, prompt)
        }
    }
}

@Composable
fun AppContent(ui: AosUi, prompt: PasswordPrompt?, dark: Boolean? = null) {
    AosTheme(dark = dark ?: isSystemInDarkTheme()) {
        CompositionLocalProvider(LocalPlatformContext provides PlatformContext(DesktopStrings.locale)) {
            AosRoot(ui, rail = true)
            if (prompt != null) PasswordPromptHost(prompt)
        }
    }
}

/** The demo (sample data): a window, or one picture of it (`--shot`). */
private fun runDemo(options: Arguments) {
    val demo = options.demo ?: DemoOptions()
    Platform.current = DesktopPlatform({ dev.marquart.aos.ui.platform.PresenceOutcome.SUCCESS }, { true }, {})
    options.shots?.let {
        Screenshot.renderAll(File(it), options.width, options.height)
        exitProcess(0)
    }
    val shot = options.shot
    if (shot != null) {
        Screenshot.render(demo, File(shot), options.width, options.height, options.waitMillis)
        exitProcess(0)
    }
    application {
        val ui = remember { Demo.makeUi(PlatformContext(DesktopStrings.locale), demo, deviceName = Os.computerName()) }
        Window(onCloseRequest = ::exitApplication, title = "aOS (Demo)", state = rememberWindowState(size = DpSize(options.width.dp, options.height.dp)),
            icon = AppIcon.painter(),
            onPreviewKeyEvent = { event ->
                event.type == KeyEventType.KeyDown && event.key == Key.Escape && (Platform.current as DesktopPlatform).back()
            }) {
            AppContent(ui, null, demo.dark)
        }
    }
}

/** The command line. */
class Arguments(args: Array<String>) {
    private val named = args.filter { it.startsWith("--") }.associate {
        val text = it.removePrefix("--")
        text.substringBefore('=') to (if ('=' in text) text.substringAfter('=') else "true")
    }

    val link: String? = args.firstOrNull { it.startsWith("aos-pair:", ignoreCase = true) }
    val background: Boolean = named["background"] == "true"
    val lang: String? = named["lang"]
    val shot: String? = named["shot"]
    val shots: String? = named["shots"]
    val width: Int = named["size"]?.substringBefore('x')?.toIntOrNull() ?: 1100
    val height: Int = named["size"]?.substringAfter('x')?.toIntOrNull() ?: 760
    val waitMillis: Long = named["wait"]?.toLongOrNull() ?: 2500

    /** `--demo` and its options (`--demo.sheet=signin`, ...), as Android's intent extras (Demo.kt). */
    val demo: DemoOptions? = if (named["demo"] != "true") null else {
        fun s(name: String) = named["demo.$name"]
        DemoOptions(
            tab = s("tab"), sheet = s("sheet"), unpaired = s("unpaired") == "true",
            dark = when (s("theme")) { "dark" -> true; "light" -> false; else -> null },
            session = s("session"), display = s("display"), chats = s("chats"), sleeping = s("sleeping") == "true",
            workspace = s("workspace"), scrollToBottom = s("scroll") == "bottom", tailnet = s("tailnet"),
        )
    }
}
