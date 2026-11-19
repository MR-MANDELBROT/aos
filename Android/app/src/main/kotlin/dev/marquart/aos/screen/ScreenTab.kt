// The Screen tab: Open Screen Sharing's selection view with two cards, the workspace and the Mac (aOS's
// iOS/Sources/Screen/ScreenTab.swift for Android; the cards after OSS's ComputerCard, GPL-3.0, nekohasekai). A tap on
// a card connects that screen, nothing connects by itself; the session then fills the screen. Written for aOS's
// Android app on 2026-11-19.

package dev.marquart.aos.screen

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.text.format.DateUtils
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import dev.marquart.aos.R
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.core.HelpRequest
import dev.marquart.aos.core.MacAction
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.core.ScreenTarget
import dev.marquart.aos.core.WorkspaceOperation
import dev.marquart.aos.model.AppModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch

/**
 * The Screen tab. Connects nothing by itself: a tap on a card connects that screen (the other one lets go); the
 * Overview's "Show the screen" and help requests come as `AppModel.screenRequest`, taken once while this tab is shown.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScreenTab(model: AppModel, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val hub = remember { ScreenHub.get(context) }
    val scope = rememberCoroutineScope()
    val connection by model.connection.collectAsState()
    val macs by model.macs.collectAsState()
    val activeHelp by model.activeHelp.collectAsState()
    val tab by model.tab.collectAsState()
    val screenRequest by model.screenRequest.collectAsState()
    val connectionState by (connection?.state ?: flowOf(MacConnection.State.Idle)).collectAsState(MacConnection.State.Idle)
    val companionState by (connection?.companionState ?: flowOf(MacConnection.CompanionState.NotStarted))
        .collectAsState(MacConnection.CompanionState.NotStarted)
    val macStatus by (connection?.macStatus ?: flowOf(null)).collectAsState(null)
    val workspaceStatus by (connection?.workspace ?: flowOf(null)).collectAsState(null)
    val operation by (connection?.workspaceOperation ?: flowOf(null)).collectAsState(null)
    val timeout by (connection?.workspaceTimeout ?: flowOf(null)).collectAsState(null)
    val matchesPhone by hub.store.matchesPhone.collectAsState()

    var notice by remember { mutableStateOf<String?>(null) }
    var confirmStart by remember { mutableStateOf(false) }
    var confirmClose by remember { mutableStateOf(false) }
    var showsWhenRunning by rememberSaveable { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var running by remember { mutableStateOf<MacAction?>(null) }
    var actionProblem by remember { mutableStateOf<String?>(null) }

    val mac = macs.firstOrNull()
    val connected = connectionState is MacConnection.State.Connected
    val ready = companionState == MacConnection.CompanionState.Ready
    // Recomposes with the reported states
    @Suppress("UNUSED_EXPRESSION") macStatus
    @Suppress("UNUSED_EXPRESSION") workspaceStatus
    val workspaceState = if (ready) connection?.workspaceState else null
    val workspaceViewable = connected && (workspaceState == "open" || workspaceState == "running")
    val setupIncomplete = macStatus?.workspace?.setupComplete == false

    fun area(): ScreenArea {
        val metrics = context.resources.displayMetrics
        return ScreenArea(metrics.widthPixels / metrics.density.toDouble(), metrics.heightPixels / metrics.density.toDouble(),
            metrics.density.toDouble(), hub.store.resolutionScale.value)
    }

    fun options() = ScreenOptions(hub.store.matchesPhone.value, hub.store.resolutionScale.value)

    fun connect(target: ScreenTarget) {
        notice = null
        val screen = hub.screen(target)
        hub.screen(if (target == ScreenTarget.MAC) ScreenTarget.WORKSPACE else ScreenTarget.MAC).stop()
        if (screen.phase == ScreenController.Phase.Preparing) return
        screen.onResolutionScale = { hub.store.setResolutionScale(it) }
        // The shell's demo (debug builds, AppModel.demo): the screen comes from the demo server in the app.
        if (model.demo != null) {
            screen.startDemo(if (target == ScreenTarget.MAC) mac?.name ?: "Mac" else context.getString(R.string.screen_workspace), 1280, 800)
            return
        }
        val c = connection
        if (c == null || !c.isConnected) {
            notice = context.getString(R.string.screen_not_connected_overview)
            return
        }
        scope.launch {
            screen.connect(c, options(), area()) { paired -> unlockMacLogin(context, hub.store, paired) }
        }
    }

    fun startWorkspace(showing: Boolean) {
        val c = connection ?: return
        showsWhenRunning = showing
        running = MacAction.WORKSPACE_START
        actionProblem = null
        scope.launch {
            try {
                c.perform(MacAction.WORKSPACE_START)
            } catch (e: Exception) {
                actionProblem = e.message
                showsWhenRunning = false
            } finally {
                running = null
            }
        }
    }

    fun stopWorkspace() {
        val c = connection ?: return
        showsWhenRunning = false
        hub.workspace.stop()
        running = MacAction.WORKSPACE_STOP
        actionProblem = null
        scope.launch {
            try {
                c.perform(MacAction.WORKSPACE_STOP)
            } catch (e: Exception) {
                actionProblem = e.message
            } finally {
                running = null
            }
        }
    }

    fun tapWorkspace() {
        if (!connected) {
            notice = context.getString(R.string.screen_not_connected_overview)
            return
        }
        if (!workspaceViewable && ready && workspaceState != null) {
            when {
                setupIncomplete -> notice = context.getString(R.string.screen_workspace_not_set_up_notice)
                workspaceState == "starting" -> showsWhenRunning = true
                workspaceState == "closing" -> notice = context.getString(R.string.screen_workspace_closing_notice)
                else -> confirmStart = true
            }
            return
        }
        connect(ScreenTarget.WORKSPACE)
    }

    // Requests from elsewhere (the Overview's "Show the screen", a help request the person opened): taps too.
    LaunchedEffect(tab, screenRequest) {
        val target = screenRequest ?: return@LaunchedEffect
        if (tab != AppModel.Tab.SCREEN) return@LaunchedEffect
        model.screenRequestHandled()
        if (target == ScreenTarget.WORKSPACE) tapWorkspace() else connect(ScreenTarget.MAC)
    }
    // "Start and show": it connects once it runs
    LaunchedEffect(workspaceViewable, showsWhenRunning) {
        if (workspaceViewable && showsWhenRunning) {
            showsWhenRunning = false
            connect(ScreenTarget.WORKSPACE)
        }
    }
    LaunchedEffect(operation == null) {
        if (operation == null && !workspaceViewable && running == null) showsWhenRunning = false
    }
    // The workspace's state while the cards are on screen: now and every 15 s (as the Overview does).
    LaunchedEffect(connection, ready) {
        while (ready) {
            connection?.refreshMacStatus()
            delay(15_000)
        }
    }
    // Unpaired Macs: what their screens kept goes.
    LaunchedEffect(macs) { hub.store.forgetAllBut(macs.map { it.id }.toSet()) }
    // The help request points at a region of the workspace: the screen zooms onto it.
    // (RemoteScreenView.focus, done by the session screen once it has a picture.)

    // The background: after the grace period the screen lets go and comes back with the app.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        var pauseJob: Job? = null
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> {
                    hub.workspace.session?.keyboard?.releaseAll()
                    hub.mac.session?.keyboard?.releaseAll()
                    pauseJob = scope.launch {
                        delay(PAUSE_AFTER_MILLIS)
                        hub.workspace.pause()
                        hub.mac.pause()
                    }
                }
                Lifecycle.Event.ON_START -> {
                    pauseJob?.cancel()
                    pauseJob = null
                    for (screen in listOf(hub.workspace, hub.mac)) {
                        if (screen.phase == ScreenController.Phase.Paused) scope.launch { screen.resume(model.connection.value, area()) }
                        else screen.session?.refresh()
                    }
                }
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            pauseJob?.cancel()
            // Leaving the tab lets go of the screens (turning the phone only rebuilds the activity).
            if (context.findActivity()?.isChangingConfigurations != true) {
                hub.workspace.stop()
                hub.mac.stop()
            }
        }
    }

    val shown = listOf(hub.workspace, hub.mac).firstOrNull { it.phase == ScreenController.Phase.Running && it.session != null }

    Box(modifier.fillMaxSize()) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val twoColumns = maxWidth > 600.dp
            Column(
                Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal))
                    .verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.screen_title), style = MaterialTheme.typography.headlineMedium, modifier = Modifier.weight(1f))
                    IconButton(onClick = { showSettings = true }) {
                        Icon(Icons.Outlined.Settings, contentDescription = stringResource(R.string.screen_settings))
                    }
                }
                activeHelp?.let { help ->
                    HelpBanner(help, show = { tapWorkspace() }, done = { scope.launch { model.finishHelp(help) } })
                }
                val problem = notice ?: listOf(hub.workspace, hub.mac).firstNotNullOfOrNull { screen ->
                    (screen.phase as? ScreenController.Phase.Failed)?.message?.let {
                        context.getString(if (screen.target == ScreenTarget.WORKSPACE) R.string.screen_no_picture_workspace else R.string.screen_no_picture_mac, it)
                    }
                }
                problem?.let {
                    NoticeBanner(it) {
                        notice = null
                        listOf(hub.workspace, hub.mac).forEach { s -> if (s.phase is ScreenController.Phase.Failed) s.stop() }
                    }
                }
                val workspaceCard: @Composable (Modifier) -> Unit = { m ->
                    Column(m, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        val id = mac?.let { ScreenIds.of(ScreenTarget.WORKSPACE, it.id) }
                        ScreenCard(
                            name = stringResource(R.string.screen_workspace),
                            detail = workspaceText(context, connected, setupIncomplete, workspaceState),
                            thumbnail = id?.let { hub.store.picture(it) },
                            available = if (!connected) false else if (workspaceState == null) null else workspaceViewable,
                            connecting = hub.workspace.phase.let { it == ScreenController.Phase.Preparing || it == ScreenController.Phase.Paused },
                            onClick = { tapWorkspace() },
                        )
                        WorkspaceActions(
                            ready = ready && connection?.macStatusUnsupported == false, state = workspaceState, operation = operation,
                            running = running, waiting = showsWhenRunning, setupIncomplete = setupIncomplete,
                            problem = actionProblem ?: timeout?.timeoutText ?: macStatus?.workspace?.error?.takeIf { workspaceState == "failed" && it.isNotEmpty() },
                            start = { startWorkspace(false) },
                            close = { if (workspaceState == "open") confirmClose = true else stopWorkspace() },
                        )
                    }
                }
                val macCard: @Composable (Modifier) -> Unit = { m ->
                    Column(m, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        val id = mac?.let { ScreenIds.of(ScreenTarget.MAC, it.id) }
                        val record = id?.let { hub.store.record(it) }.also { hub.store.revision }
                        var menu by remember { mutableStateOf(false) }
                        Box {
                            ScreenCard(
                                name = mac?.name ?: "Mac",
                                detail = macText(context, connected, record),
                                thumbnail = id?.let { hub.store.picture(it) },
                                available = if (connection == null) null else connected,
                                connecting = hub.mac.phase.let { it == ScreenController.Phase.Preparing || it == ScreenController.Phase.Paused },
                                onClick = { connect(ScreenTarget.MAC) },
                                onLongClick = { menu = true },
                            )
                            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                                DropdownMenuItem(text = { Text(stringResource(R.string.screen_change_login)) }, onClick = {
                                    menu = false
                                    mac?.let { m -> scope.launch { hub.store.setMacLogin(m.id, null) } }
                                    hub.workspace.stop()
                                    hub.mac.showNeedsLogin()
                                })
                            }
                        }
                        macNote(context, matchesPhone, hub.mac.tunnelReason, hub.mac.tunnelDetail)?.let { note ->
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Icon(Icons.Outlined.Info, null, Modifier.size(16.dp).padding(top = 2.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                Text(note, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
                if (twoColumns) {
                    Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                        workspaceCard(Modifier.weight(1f))
                        macCard(Modifier.weight(1f))
                    }
                } else {
                    workspaceCard(Modifier.fillMaxWidth())
                    macCard(Modifier.fillMaxWidth())
                }
            }
        }
    }

    // The running screen, full screen over everything
    if (shown != null) {
        val session = shown.session
        if (session != null) {
            SessionScreen(
                session = session,
                hub = hub,
                help = activeHelp?.takeIf { true },
                isWorkspace = shown.target == ScreenTarget.WORKSPACE,
                onShowWorkspace = { tapWorkspace() },
                onHelpDone = { help -> scope.launch { model.finishHelp(help) } },
                onClose = { shown.closed(session) },
            )
        }
    }

    if (hub.mac.phase == ScreenController.Phase.NeedsLogin && shown == null && mac != null) {
        MacLoginDialog(mac, hub.mac.loginProblem, onCancel = { hub.mac.cancelLogin() }) { login ->
            scope.launch {
                val c = connection
                if (!saveMacLogin(context, hub.store, mac, login)) return@launch
                if (c == null || !c.isConnected) {
                    hub.mac.stop()
                    notice = context.getString(R.string.screen_not_connected_overview)
                    return@launch
                }
                hub.mac.onResolutionScale = { hub.store.setResolutionScale(it) }
                hub.mac.start(c, login, options(), area())
            }
        }
    }

    if (confirmStart) {
        AlertDialog(
            onDismissRequest = { confirmStart = false },
            title = { Text(stringResource(R.string.screen_workspace_closed_title)) },
            text = { Text(stringResource(R.string.screen_workspace_closed_message)) },
            confirmButton = { TextButton(onClick = { confirmStart = false; startWorkspace(true) }) { Text(stringResource(R.string.screen_start_and_show)) } },
            dismissButton = { TextButton(onClick = { confirmStart = false }) { Text(stringResource(R.string.screen_cancel)) } },
        )
    }
    if (confirmClose) {
        val purpose = macStatus?.workspace?.purpose?.takeIf { it.isNotEmpty() } ?: workspaceStatus?.purpose?.takeIf { it.isNotEmpty() }
        AlertDialog(
            onDismissRequest = { confirmClose = false },
            title = { Text(stringResource(R.string.screen_close_workspace_title)) },
            text = {
                Text(if (purpose != null) stringResource(R.string.screen_close_workspace_agent, purpose) else stringResource(R.string.screen_close_workspace_message))
            },
            confirmButton = {
                TextButton(onClick = { confirmClose = false; stopWorkspace() }) {
                    Text(stringResource(R.string.screen_close), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { confirmClose = false }) { Text(stringResource(R.string.screen_cancel)) } },
        )
    }
    if (showSettings) {
        ModalBottomSheet(onDismissRequest = { showSettings = false }) {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
                ScreenSettingsSection()
            }
        }
    }
}

private const val PAUSE_AFTER_MILLIS = 25_000L

internal fun Context.findActivity(): Activity? {
    var c: Context? = this
    while (c is ContextWrapper) {
        if (c is Activity) return c
        c = c.baseContext
    }
    return null
}

private fun workspaceText(context: Context, connected: Boolean, setupIncomplete: Boolean, state: String?): String {
    if (!connected) return context.getString(R.string.screen_not_connected_to_mac)
    if (setupIncomplete) return context.getString(R.string.screen_workspace_not_set_up)
    return when (state) {
        "stopped" -> context.getString(R.string.screen_workspace_stopped)
        "starting" -> context.getString(R.string.screen_workspace_starting)
        "open" -> context.getString(R.string.screen_workspace_open)
        "running" -> context.getString(R.string.screen_workspace_running)
        "closing" -> context.getString(R.string.screen_workspace_closing)
        "failed" -> context.getString(R.string.screen_workspace_failed)
        null -> context.getString(R.string.screen_workspace_no_news)
        else -> state
    }
}

private fun macText(context: Context, connected: Boolean, record: ScreenRecord?): String {
    if (!connected) return context.getString(R.string.screen_not_connected_to_mac)
    val last = record?.lastConnected ?: return context.getString(R.string.screen_connected)
    val ago = DateUtils.getRelativeTimeSpanString(last, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)
    return context.getString(R.string.screen_last_connected, ago)
}

/** Why the Mac kept its own size (the phone's size was wanted, the direct path wasn't there), with the detail. */
private fun macNote(context: Context, matchesPhone: Boolean, reason: TunnelReason?, detail: String?): String? {
    if (!matchesPhone || reason == null) return null
    val text = context.getString(
        when (reason) {
            TunnelReason.NO_ADDRESS, TunnelReason.UNREACHABLE -> R.string.screen_note_ssh
            TunnelReason.TAILNET_WITHOUT_VPN -> R.string.screen_note_tailnet
            TunnelReason.NO_HIGH_PERFORMANCE -> R.string.screen_note_no_high_performance
            TunnelReason.FAILED -> R.string.screen_note_failed
        },
    )
    return if (detail.isNullOrEmpty()) text else "$text ($detail)"
}

/** A screen: the last picture (16:10) or a computer, a dot (green: reachable), the name and one line. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ScreenCard(
    name: String,
    detail: String,
    thumbnail: Bitmap?,
    available: Boolean?,
    connecting: Boolean,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).combinedClickable(onClick = onClick, onLongClick = onLongClick),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            Modifier.fillMaxWidth().aspectRatio(16f / 10f).clip(RoundedCornerShape(18.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(18.dp)),
            contentAlignment = Alignment.Center,
        ) {
            if (thumbnail != null) {
                Image(thumbnail.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            } else {
                Icon(Icons.Outlined.Computer, contentDescription = null, Modifier.size(72.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (connecting) {
                Surface(shape = CircleShape, tonalElevation = 6.dp, shadowElevation = 4.dp, modifier = Modifier.size(73.dp)) {
                    Box(contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(Modifier.size(36.dp), strokeWidth = 3.5.dp)
                    }
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(horizontal = 4.dp)) {
            if (available != null) {
                Box(Modifier.size(9.dp).clip(CircleShape).background(if (available) Color(0xFF34C759) else MaterialTheme.colorScheme.outline))
            }
            Column {
                Text(name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** Start or Close under the workspace's card, busy until the Mac reports it done. */
@Composable
private fun WorkspaceActions(
    ready: Boolean,
    state: String?,
    operation: WorkspaceOperation?,
    running: MacAction?,
    waiting: Boolean,
    setupIncomplete: Boolean,
    problem: String?,
    start: () -> Unit,
    close: () -> Unit,
) {
    val starting = running == MacAction.WORKSPACE_START || operation?.kind == WorkspaceOperation.Kind.START
    val closing = running == MacAction.WORKSPACE_STOP || operation?.kind == WorkspaceOperation.Kind.STOP
    val busy = running != null || operation != null
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        if (ready && state != null) {
            if (starting || (!closing && (state == "stopped" || state == "failed"))) {
                FilledTonalButton(onClick = start, enabled = !busy && !setupIncomplete) {
                    BusyIcon(starting) { Icon(Icons.Filled.PlayArrow, null, Modifier.size(18.dp)) }
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(if (starting) R.string.screen_workspace_starting else R.string.screen_start))
                }
            } else if (closing || state == "open" || state == "running" || state == "starting") {
                FilledTonalButton(onClick = close, enabled = !busy) {
                    BusyIcon(closing) { Icon(Icons.Filled.Stop, null, Modifier.size(18.dp)) }
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(if (closing) R.string.screen_workspace_closing else R.string.screen_close))
                }
            }
        }
        if (waiting && !starting && !closing) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
    }
    problem?.let {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.Outlined.WarningAmber, null, Modifier.size(16.dp), tint = Color(0xFFFF9500))
            Text(it, style = MaterialTheme.typography.bodySmall, color = Color(0xFFFF9500))
        }
    }
}

@Composable
private fun BusyIcon(busy: Boolean, icon: @Composable () -> Unit) {
    if (busy) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) else icon()
}

/** The agent asks for help in the workspace: what for, a button to show the workspace, and one to say it's done. */
@Composable
private fun HelpBanner(request: HelpRequest, show: () -> Unit, done: () -> Unit) {
    Surface(shape = RoundedCornerShape(22.dp), color = MaterialTheme.colorScheme.tertiaryContainer) {
        Row(Modifier.padding(14.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(Icons.Outlined.PanTool, null, tint = MaterialTheme.colorScheme.tertiary)
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    stringResource(R.string.screen_asks_for_help, request.agent.ifEmpty { stringResource(R.string.screen_your_agent) }),
                    style = MaterialTheme.typography.titleSmall,
                )
                if (request.purpose.isNotEmpty()) Text(request.purpose, style = MaterialTheme.typography.bodyMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(top = 8.dp)) {
                    Button(onClick = show) { Text(stringResource(R.string.screen_show_workspace)) }
                    TextButton(onClick = done) { Text(stringResource(R.string.screen_done)) }
                }
            }
        }
    }
}

/** What went wrong, above the cards, until dismissed or the next tap. */
@Composable
private fun NoticeBanner(text: String, dismiss: () -> Unit) {
    Surface(shape = RoundedCornerShape(22.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
        Row(Modifier.padding(14.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
            Icon(Icons.Outlined.WarningAmber, null, tint = Color(0xFFFF9500))
            Text(text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
            TextButton(onClick = dismiss) { Text(stringResource(R.string.screen_ok)) }
        }
    }
}

/** The Mac account for the Mac's own screen sharing, entered once. */
@Composable
private fun MacLoginDialog(mac: PairedMac, problem: String?, onCancel: () -> Unit, onSave: (MacLogin) -> Unit) {
    var username by rememberSaveable { mutableStateOf(mac.user) }
    var password by remember { mutableStateOf("") }
    val canSave = username.isNotEmpty() && password.isNotEmpty()
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text(stringResource(R.string.screen_login_title, mac.name)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.screen_login_explanation))
                OutlinedTextField(
                    value = username, onValueChange = { username = it }, singleLine = true,
                    label = { Text(stringResource(R.string.screen_account_name)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, imeAction = ImeAction.Next, autoCorrectEnabled = false),
                )
                OutlinedTextField(
                    value = password, onValueChange = { password = it }, singleLine = true,
                    label = { Text(stringResource(R.string.screen_password)) },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { if (canSave) onSave(MacLogin(username, password)) }),
                )
                problem?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                Text(stringResource(R.string.screen_login_kept), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(stringResource(R.string.screen_login_sharing_on), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = {
            Button(onClick = { onSave(MacLogin(username, password)) }, enabled = canSave, colors = ButtonDefaults.buttonColors()) {
                Text(stringResource(R.string.screen_save_and_connect))
            }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text(stringResource(R.string.screen_cancel)) } },
    )
}
