package dev.marquart.aos.desktop.screen

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.DesktopWindows
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material.icons.rounded.SupportAgent
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import dev.marquart.aos.R
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.core.HelpRequest
import dev.marquart.aos.core.MacAction
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.core.ScreenTarget
import dev.marquart.aos.desktop.GoLibrary
import dev.marquart.aos.desktop.Os
import dev.marquart.aos.desktop.store.Prefs
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.screen.ClipboardBridge
import dev.marquart.aos.screen.MacLogin
import dev.marquart.aos.screen.ModifierKey
import dev.marquart.aos.screen.PrefsKeyValues
import dev.marquart.aos.screen.ScreenController
import dev.marquart.aos.screen.ScreenHub
import dev.marquart.aos.screen.ScreenIds
import dev.marquart.aos.screen.ScreenOptions
import dev.marquart.aos.screen.ScreenStore
import dev.marquart.aos.screen.SessionChoice
import dev.marquart.aos.screen.SessionModel
import dev.marquart.aos.screen.SessionPhase
import dev.marquart.aos.screen.SystemCommand
import dev.marquart.aos.screen.failureTitle
import dev.marquart.aos.store.SecretStore
import dev.marquart.aos.ui.LocalAosUi
import dev.marquart.aos.ui.components.Section
import dev.marquart.aos.ui.components.SectionRow
import dev.marquart.aos.ui.platform.BackHandler
import dev.marquart.aos.ui.platform.Platform
import dev.marquart.aos.ui.platform.PlatformContext
import dev.marquart.aos.ui.platform.PresenceOutcome
import dev.marquart.aos.ui.platform.platformContext
import dev.marquart.aos.ui.platform.stringResource
import dev.marquart.aos.ui.platform.text
import dev.marquart.aos.ui.theme.AosTheme
import dev.marquart.aos.ui.platform.LocalPlatformContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import java.io.File

/** The desktop's screen hub (both screens, the store), made once. The demo's keeps nothing. */
object DesktopScreens {
    @Volatile var secrets: SecretStore? = null

    fun hub(context: PlatformContext, demo: Boolean, vpn: () -> Boolean): ScreenHub = ScreenHub.instance ?: synchronized(this) {
        ScreenHub.instance ?: run {
            val cache = Os.privateDir(File(Os.configDir, "cache"))
            val store = if (demo) ScreenStore(PrefsKeyValues(Prefs(File(cache, "demo-screen.json"))), PrefsKeyValues(Prefs(File(cache, "demo-records.json"))), cache, null)
                else ScreenStore(PrefsKeyValues(Prefs.named("screen")), PrefsKeyValues(Prefs.named("screen-records")), cache, secrets)
            ScreenHub(context, store, GoLibrary.screenSessions, cache, vpn).also { ScreenHub.instance = it }
        }
    }
}

/**
 * The Screen tab on the desktop: the workspace and the Mac's own screen as cards (with their last picture), one of
 * them connected at a time, filling the tab. The Mac's account for its screen sharing is asked once and kept with
 * the secrets (DPAPI, the Secret Service), behind the person's confirmation when it is read.
 */
@Composable
fun DesktopScreenTab(model: AppModel, modifier: Modifier = Modifier) {
    val ui = LocalAosUi.current
    val context = platformContext()
    val hub = remember { DesktopScreens.hub(context, model.demo != null) { ui.network.tailscaleVpnActive() } }
    val scope = rememberCoroutineScope()
    val connection by model.connection.collectAsState()
    val macs by model.macs.collectAsState()
    val activeHelp by model.activeHelp.collectAsState()
    val tab by model.tab.collectAsState()
    val screenRequest by model.screenRequest.collectAsState()
    val connectionState by (connection?.state ?: flowOf(MacConnection.State.Idle)).collectAsState(MacConnection.State.Idle)
    val companionState by (connection?.companionState ?: flowOf(MacConnection.CompanionState.NotStarted)).collectAsState(MacConnection.CompanionState.NotStarted)
    val macStatus by (connection?.macStatus ?: flowOf(null)).collectAsState(null)
    @Suppress("UNUSED_VARIABLE") val workspaceStatus by (connection?.workspace ?: flowOf(null)).collectAsState(null)
    var notice by remember { mutableStateOf<String?>(null) }
    var confirmStart by remember { mutableStateOf(false) }
    var showsWhenRunning by remember { mutableStateOf(false) }
    val mac = macs.firstOrNull()
    val connected = connectionState is MacConnection.State.Connected
    val ready = companionState == MacConnection.CompanionState.Ready
    val workspaceState = if (ready) connection?.workspaceState else null
    val workspaceViewable = connected && (workspaceState == "open" || workspaceState == "running")
    val setupIncomplete = macStatus?.workspace?.setupComplete == false

    fun options() = ScreenOptions(hub.store.matchesPhone.value, hub.store.resolutionScale.value)
    fun area() = dev.marquart.aos.screen.ScreenArea(1100.0, 700.0, 1.0, hub.store.resolutionScale.value)

    fun connect(target: ScreenTarget) {
        notice = null
        val screen = hub.screen(target)
        hub.screen(if (target == ScreenTarget.MAC) ScreenTarget.WORKSPACE else ScreenTarget.MAC).stop()
        if (screen.phase == ScreenController.Phase.Preparing) return
        screen.onResolutionScale = { hub.store.setResolutionScale(it) }
        if (model.demo != null) {
            screen.startDemo(if (target == ScreenTarget.MAC) mac?.name ?: "Mac" else context.text(R.string.screen_workspace), 1280, 800)
            return
        }
        val c = connection
        if (c == null || !c.isConnected) {
            notice = context.text(R.string.screen_not_connected_overview)
            return
        }
        scope.launch {
            screen.connect(c, options(), area()) { paired -> unlockMacLogin(context, hub.store, paired) }
        }
    }

    fun tapWorkspace() {
        if (model.demo == null && !connected) {
            notice = context.text(R.string.screen_not_connected_overview)
            return
        }
        if (model.demo == null && !workspaceViewable && ready && workspaceState != null) {
            when {
                setupIncomplete -> notice = context.text(R.string.screen_workspace_not_set_up_notice)
                workspaceState == "starting" -> showsWhenRunning = true
                workspaceState == "closing" -> notice = context.text(R.string.screen_workspace_closing_notice)
                else -> confirmStart = true
            }
            return
        }
        connect(ScreenTarget.WORKSPACE)
    }

    LaunchedEffect(tab, screenRequest) {
        val target = screenRequest ?: return@LaunchedEffect
        if (tab != AppModel.Tab.SCREEN) return@LaunchedEffect
        model.screenRequestHandled()
        if (target == ScreenTarget.WORKSPACE) tapWorkspace() else connect(ScreenTarget.MAC)
    }
    LaunchedEffect(workspaceViewable, showsWhenRunning) {
        if (workspaceViewable && showsWhenRunning) {
            showsWhenRunning = false
            connect(ScreenTarget.WORKSPACE)
        }
    }
    LaunchedEffect(connection, ready) {
        while (ready) {
            connection?.refreshMacStatus()
            delay(15_000)
        }
    }
    LaunchedEffect(macs) { if (model.demo == null) hub.store.forgetAllBut(macs.map { it.id }.toSet()) }

    val shown = listOf(hub.workspace, hub.mac).firstOrNull { it.phase == ScreenController.Phase.Running && it.session != null }
    androidx.compose.material3.Surface(modifier.fillMaxSize(), color = AosTheme.colors.background) {
        if (shown != null) {
            SessionView(shown, shown.session!!, hub) { shown.stop() }
        } else {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp).widthIn(max = 900.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp)) {
                Text(stringResource(R.string.screen_title), style = MaterialTheme.typography.headlineMedium)
                activeHelp?.let { HelpBanner(it, show = { tapWorkspace() }, done = { scope.launch { model.finishHelp(it) } }) }
                val problem = notice ?: listOf(hub.workspace, hub.mac).firstNotNullOfOrNull { screen ->
                    (screen.phase as? ScreenController.Phase.Failed)?.message?.let {
                        context.text(if (screen.target == ScreenTarget.WORKSPACE) R.string.screen_no_picture_workspace else R.string.screen_no_picture_mac, it)
                    }
                }
                problem?.let {
                    Text(it, color = AosTheme.colors.orange, modifier = Modifier.clickable {
                        notice = null
                        listOf(hub.workspace, hub.mac).forEach { s -> if (s.phase is ScreenController.Phase.Failed) s.stop() }
                    })
                }
                if (!GoLibrary.screenSessions.available && model.demo == null) {
                    Text(stringResource(R.string.screen_no_library), color = AosTheme.colors.secondary)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                    ScreenCard(Modifier.weight(1f), Icons.Rounded.DesktopWindows, stringResource(R.string.screen_workspace),
                        workspaceText(connected || model.demo != null, setupIncomplete, workspaceState, model.demo != null),
                        mac?.let { hub.store.picture(ScreenIds.of(ScreenTarget.WORKSPACE, it.id)) }, hub.workspace.phase, ::tapWorkspace)
                    ScreenCard(Modifier.weight(1f), Icons.Rounded.Laptop, mac?.name ?: "Mac",
                        if (connected || model.demo != null) stringResource(R.string.screen_connected) else stringResource(R.string.screen_not_connected_to_mac),
                        mac?.let { hub.store.picture(ScreenIds.of(ScreenTarget.MAC, it.id)) }, hub.mac.phase) { connect(ScreenTarget.MAC) }
                }
                if (hub.mac.phase == ScreenController.Phase.NeedsLogin && mac != null) {
                    LoginForm(mac, hub.mac.loginProblem, onCancel = { hub.mac.cancelLogin() }) { login ->
                        scope.launch {
                            hub.store.setMacLogin(mac.id, login)
                            val c = connection ?: return@launch
                            hub.mac.start(c, login, options(), area())
                        }
                    }
                }
            }
        }
    }
    if (confirmStart) {
        AlertDialog(onDismissRequest = { confirmStart = false },
            title = { Text(stringResource(R.string.screen_workspace_closed_title)) },
            text = { Text(stringResource(R.string.screen_workspace_closed_message)) },
            confirmButton = {
                Button(onClick = {
                    confirmStart = false
                    showsWhenRunning = true
                    scope.launch { runCatching { connection?.perform(MacAction.WORKSPACE_START) } }
                }) { Text(stringResource(R.string.screen_start_and_show)) }
            },
            dismissButton = { TextButton(onClick = { confirmStart = false }) { Text(stringResource(R.string.screen_cancel)) } })
    }
}

@Composable
private fun workspaceText(connected: Boolean, setupIncomplete: Boolean, state: String?, demo: Boolean): String = when {
    demo -> stringResource(R.string.screen_workspace_open)
    !connected -> stringResource(R.string.screen_not_connected_to_mac)
    setupIncomplete -> stringResource(R.string.screen_workspace_not_set_up)
    else -> when (state) {
        "open" -> stringResource(R.string.screen_workspace_open)
        "running" -> stringResource(R.string.screen_workspace_running)
        "starting" -> stringResource(R.string.screen_workspace_starting)
        "closing" -> stringResource(R.string.screen_workspace_closing)
        "failed" -> stringResource(R.string.screen_workspace_failed)
        "stopped" -> stringResource(R.string.screen_workspace_stopped)
        else -> stringResource(R.string.screen_workspace_no_news)
    }
}

@Composable
private fun ScreenCard(modifier: Modifier, icon: androidx.compose.ui.graphics.vector.ImageVector, name: String, detail: String,
                       thumbnail: java.awt.image.BufferedImage?, phase: ScreenController.Phase, onClick: () -> Unit) {
    Column(modifier.clip(RoundedCornerShape(20.dp)).background(AosTheme.colors.card).clickable(onClick = onClick)) {
        Box(Modifier.fillMaxWidth().aspectRatio(16f / 10f).background(Color.Black), contentAlignment = Alignment.Center) {
            val image = remember(thumbnail) { thumbnail?.toComposeImageBitmap() }
            if (image != null) Image(image, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            else Icon(icon, contentDescription = null, tint = Color.White.copy(alpha = 0.6f), modifier = Modifier.size(56.dp))
            if (phase == ScreenController.Phase.Preparing) CircularProgressIndicator(color = Color.White)
        }
        Column(Modifier.padding(16.dp)) {
            Text(name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(detail, style = MaterialTheme.typography.bodyMedium, color = AosTheme.colors.secondary)
        }
    }
}

@Composable
private fun HelpBanner(help: HelpRequest, show: () -> Unit, done: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(AosTheme.colors.orange.copy(alpha = 0.15f)).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(Icons.Rounded.SupportAgent, contentDescription = null, tint = AosTheme.colors.orange)
        Column(Modifier.weight(1f)) {
            Text(if (help.agent.isEmpty()) stringResource(R.string.screen_agent_asks_for_help) else stringResource(R.string.screen_asks_for_help, help.agent),
                fontWeight = FontWeight.SemiBold)
            if (help.purpose.isNotEmpty()) Text(help.purpose, color = AosTheme.colors.secondary)
        }
        FilledTonalButton(onClick = show) { Text(stringResource(R.string.screen_show)) }
        TextButton(onClick = done) { Text(stringResource(R.string.screen_done)) }
    }
}

@Composable
private fun LoginForm(mac: PairedMac, problem: String?, onCancel: () -> Unit, save: (MacLogin) -> Unit) {
    var user by remember { mutableStateOf(mac.user) }
    var password by remember { mutableStateOf("") }
    Section(header = stringResource(R.string.screen_login_title, mac.name), footer = stringResource(R.string.screen_login_sharing_on)) {
        SectionRow(divider = false) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(stringResource(R.string.screen_login_explanation), color = AosTheme.colors.secondary)
                problem?.let { Text(it, color = AosTheme.colors.red) }
                OutlinedTextField(user, { user = it }, singleLine = true, label = { Text(stringResource(R.string.screen_account_name)) })
                OutlinedTextField(password, { password = it }, singleLine = true, label = { Text(stringResource(R.string.screen_password)) },
                    visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                Text(stringResource(R.string.screen_login_kept), style = MaterialTheme.typography.bodySmall, color = AosTheme.colors.secondary)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { save(MacLogin(user.trim(), password)) }, enabled = user.isNotBlank() && password.isNotEmpty()) {
                        Text(stringResource(R.string.screen_save_and_connect))
                    }
                    TextButton(onClick = onCancel) { Text(stringResource(R.string.screen_cancel)) }
                }
            }
        }
    }
}

/** The Mac's login from the store, after the person confirmed it is them (Windows Hello, polkit, the password). */
private suspend fun unlockMacLogin(context: PlatformContext, store: ScreenStore, mac: PairedMac): MacLogin? {
    if (!store.hasMacLogin(mac.id)) return null
    when (Platform.current.confirmPresence(context.text(R.string.screen_unlock_title, mac.name))) {
        PresenceOutcome.SUCCESS, PresenceOutcome.UNAVAILABLE -> Unit
        else -> throw dev.marquart.aos.screen.UnlockCancelled()
    }
    return store.macLogin(mac.id)
}

@Composable
private fun SessionView(screen: ScreenController, session: SessionModel, hub: ScreenHub, close: () -> Unit) {
    val name = screen.route?.name ?: ""
    BackHandler(onBack = close)
    LaunchedEffect(session) {
        session.clipboard = object : ClipboardBridge {
            override fun read(): String? = Platform.current.clipboardText()
            override fun write(text: String) = Platform.current.copyToClipboard(text, "Screen")
        }
    }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().background(AosTheme.colors.card).padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            IconButton(onClick = close) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = stringResource(R.string.screen_disconnect)) }
            Text(name, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            when (val phase = session.phase) {
                SessionPhase.Connecting, SessionPhase.Authenticating -> Text(stringResource(R.string.screen_status_connecting), color = AosTheme.colors.secondary)
                is SessionPhase.Reconnecting -> Text(stringResource(R.string.screen_status_reconnecting), color = AosTheme.colors.secondary)
                SessionPhase.WaitingForPermission -> Text(stringResource(R.string.screen_status_waiting_permission), color = AosTheme.colors.secondary)
                else -> if (phase is SessionPhase.Failed) Unit
            }
            // ⌘ for the next key (the system keeps the Windows key), Mission Control, the clipboard both ways.
            TextButton(onClick = { session.keyboard.toggleSticky(ModifierKey.COMMAND) }) {
                Text("⌘", fontWeight = if (ModifierKey.COMMAND in session.keyboard.sticky) FontWeight.Bold else FontWeight.Normal)
            }
            if (session.canPerform(SystemCommand.MISSION_CONTROL)) TextButton(onClick = { session.perform(SystemCommand.MISSION_CONTROL) }) {
                Text(stringResource(R.string.screen_mission_control))
            }
            IconButton(onClick = { session.sendClipboardToMac() }) {
                Icon(Icons.Rounded.ContentPaste, contentDescription = stringResource(R.string.screen_send_clipboard))
            }
            Text(stringResource(R.string.screen_sync_clipboard), style = MaterialTheme.typography.bodySmall)
            Switch(session.clipboardSharing, { session.changeClipboardSharing(it) })
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            RemoteScreen(session, Modifier.fillMaxSize())
            when (val phase = session.phase) {
                is SessionPhase.Failed -> AlertDialog(onDismissRequest = close,
                    title = { Text(failureTitle(phase.failure, name)) },
                    text = { Text(phase.failure.message) },
                    confirmButton = { Button(onClick = { session.retry() }) { Text(stringResource(R.string.screen_reconnect)) } },
                    dismissButton = { TextButton(onClick = close) { Text(stringResource(R.string.screen_close)) } })
                is SessionPhase.ChoosingSession -> AlertDialog(onDismissRequest = { session.answerPrompt(SessionChoice.CANCEL) },
                    title = { Text(stringResource(R.string.screen_in_use, name)) },
                    text = { Text(stringResource(R.string.screen_in_use_by, phase.prompt.consoleUser)) },
                    confirmButton = {
                        if (phase.prompt.allowsOwnSession) Button(onClick = { session.answerPrompt(SessionChoice.OWN_SESSION) }) { Text(stringResource(R.string.screen_own_session)) }
                    },
                    dismissButton = {
                        if (phase.prompt.allowsShareConsole) TextButton(onClick = { session.answerPrompt(SessionChoice.SHARE_CONSOLE) }) { Text(stringResource(R.string.screen_ask_to_share)) }
                    })
                else -> if (!session.hasPicture) CircularProgressIndicator(Modifier.align(Alignment.Center), color = Color.White)
            }
        }
    }
}

/** Settings > Screen on the desktop: the window's shape for the screens, the resolution. */
@Composable
fun ScreenSettingsSection() {
    val ui = LocalAosUi.current
    val context = LocalPlatformContext.current
    val hub = remember { DesktopScreens.hub(context, ui.isDemo) { ui.network.tailscaleVpnActive() } }
    val matches by hub.store.matchesPhone.collectAsState()
    val scale by hub.store.resolutionScale.collectAsState()
    Section(header = stringResource(R.string.screen_display), footer = stringResource(R.string.screen_display_footer)) {
        SectionRow(divider = true) {
            Text(stringResource(R.string.screen_matches_phone), modifier = Modifier.weight(1f))
            Switch(matches, { hub.store.setMatchesPhone(it) })
        }
        SectionRow(divider = false) {
            Text(stringResource(R.string.screen_resolution), modifier = Modifier.weight(1f))
            for (choice in listOf(1.0, 1.25, 1.5, 2.0)) {
                TextButton(onClick = { hub.store.setResolutionScale(choice) }) {
                    Text(if (choice == 1.0) stringResource(R.string.screen_native) else "${(choice * 100).toInt()} %",
                        fontWeight = if (choice == scale) FontWeight.Bold else FontWeight.Normal)
                }
            }
        }
    }
}
