package dev.marquart.aos.ui.overview

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Chat
import androidx.compose.material.icons.rounded.AddComment
import androidx.compose.material.icons.rounded.AddToQueue
import androidx.compose.material.icons.rounded.Apps
import androidx.compose.material.icons.rounded.Battery0Bar
import androidx.compose.material.icons.rounded.Battery3Bar
import androidx.compose.material.icons.rounded.Battery5Bar
import androidx.compose.material.icons.rounded.BatteryChargingFull
import androidx.compose.material.icons.rounded.BatteryFull
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.CloseFullscreen
import androidx.compose.material.icons.rounded.DesktopWindows
import androidx.compose.material.icons.rounded.Fingerprint
import androidx.compose.material.icons.rounded.Forum
import androidx.compose.material.icons.rounded.HourglassTop
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material.icons.rounded.LightMode
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.LockOpen
import androidx.compose.material.icons.rounded.Monitor
import androidx.compose.material.icons.rounded.NoAccounts
import androidx.compose.material.icons.rounded.PanTool
import androidx.compose.material.icons.rounded.Pin
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Power
import androidx.compose.material.icons.rounded.QrCodeScanner
import androidx.compose.material.icons.rounded.QuestionAnswer
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Schedule
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material.icons.rounded.Terminal
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material.icons.rounded.UnfoldMore
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import dev.marquart.aos.R
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.core.MacAction
import dev.marquart.aos.core.MacOffer
import dev.marquart.aos.core.MacStatus
import dev.marquart.aos.core.MacStayAwake
import dev.marquart.aos.core.ScreenTarget
import dev.marquart.aos.core.SignInRequest
import dev.marquart.aos.core.WorkspaceOperation
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.ui.ConnectionText
import dev.marquart.aos.ui.LocalAosUi
import dev.marquart.aos.ui.OverviewPage
import dev.marquart.aos.ui.Txt
import dev.marquart.aos.ui.components.AosCard
import dev.marquart.aos.ui.components.AppIconImage
import dev.marquart.aos.ui.components.ConfirmDialog
import dev.marquart.aos.ui.components.FactRow
import dev.marquart.aos.ui.components.HeroSymbol
import dev.marquart.aos.ui.components.IconColumn
import dev.marquart.aos.ui.components.OverviewRow
import dev.marquart.aos.ui.components.Page
import dev.marquart.aos.ui.components.ProblemLine
import dev.marquart.aos.ui.components.SmallSpinner
import dev.marquart.aos.ui.components.StatusDot
import dev.marquart.aos.ui.components.StatusTile
import dev.marquart.aos.ui.text
import dev.marquart.aos.ui.theme.AosTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The Overview tab: the Mac, what waits for you, the workspace, aOS on the Mac; its pages (chats, apps, routines). */
@Composable
fun OverviewTab() {
    val ui = LocalAosUi.current
    val page = ui.overview.top
    BackHandler(enabled = page != null) { ui.overview.pop() }
    AnimatedContent(targetState = page, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "overview") { shown ->
        when (shown) {
            null -> OverviewScreen()
            OverviewPage.Chats -> ChatsPage()
            is OverviewPage.Chat -> ChatPage(shown.id)
            OverviewPage.Apps -> AppsPage()
            OverviewPage.Routines -> RoutinesPage(onBack = { ui.overview.pop() })
        }
    }
}

/** The app is on screen and active (the polls run only then). */
@Composable
fun isResumed(): Boolean {
    val state by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    return state.isAtLeast(Lifecycle.State.RESUMED)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun OverviewScreen() {
    val ui = LocalAosUi.current
    val model = ui.model
    val connection by model.connection.collectAsState()
    val macs by model.macs.collectAsState()
    val questions by model.questions.collectAsState()
    val help by model.helpRequests.collectAsState()
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    val resumed = isResumed()
    val companion by model.companionState.collectAsState()

    // The Mac's status and the chats while the Overview is on screen: now and every 15 s.
    LaunchedEffect(connection, companion == MacConnection.CompanionState.Ready, resumed) {
        val c = connection ?: return@LaunchedEffect
        if (!resumed) return@LaunchedEffect
        while (true) {
            c.refreshMacStatus()
            c.refreshChats()
            delay(15_000)
        }
    }

    Page(title = if (macs.isNotEmpty()) stringResource(R.string.app_name) else "") { padding ->
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = {
                scope.launch {
                    refreshing = true
                    connection?.let { c ->
                        c.retryNow()
                        c.refreshStatus()
                        c.refreshMacStatus()
                        c.refreshChats()
                    }
                    refreshing = false
                }
            },
            modifier = Modifier.fillMaxSize().padding(padding),
        ) {
            val scroll = rememberScrollState()
            LaunchedEffect(ui.demo?.scrollToBottom) {
                if (ui.demo?.scrollToBottom == true) {
                    delay(900)
                    scroll.animateScrollTo(scroll.maxValue)
                }
            }
            Column(
                Modifier.fillMaxSize().verticalScroll(scroll).padding(horizontal = 16.dp).padding(bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                val c = connection
                if (c != null) {
                    MacCard(c)
                    if (questions.isNotEmpty() || help.isNotEmpty()) RequestsCard(model)
                    WorkspaceCard(c)
                    val macStatus by c.macStatus.collectAsState()
                    val sleeping by c.sleepingSince.collectAsState()
                    if (macStatus != null && companion == MacConnection.CompanionState.Ready && sleeping == null) AosCardView(c)
                    PromiseCard()
                } else {
                    WelcomeView()
                }
            }
        }
    }
}

// Mac

@Composable
private fun MacCard(connection: MacConnection) {
    val ui = LocalAosUi.current
    val colors = AosTheme.colors
    val mac by connection.mac.collectAsState()
    val state by connection.state.collectAsState()
    val companion by connection.companionState.collectAsState()
    val sleeping by connection.sleepingSince.collectAsState()
    val problem by connection.macAppProblem.collectAsState()
    val status by connection.macStatus.collectAsState()
    val hello by connection.hello.collectAsState()
    val actions = rememberActionState()
    var confirmSleep by remember { mutableStateOf(false) }

    val tint = when {
        sleeping != null -> colors.indigo
        state is MacConnection.State.Connected ->
            if (problem == null && (companion == MacConnection.CompanionState.Ready || companion == MacConnection.CompanionState.Starting)) colors.green
            else colors.orange
        state is MacConnection.State.Unreachable -> colors.orange
        state is MacConnection.State.NeedsAttention -> colors.red
        else -> colors.gray
    }
    val stateLine: Txt = when {
        sleeping != null -> Txt.res(R.string.mac_sleeping_since, Txt.Time(sleeping!!, Txt.TimeStyle.TIME))
        else -> when (val s = state) {
            MacConnection.State.Idle -> Txt.res(R.string.mac_not_connected)
            MacConnection.State.Connecting -> Txt.res(R.string.mac_connecting)
            is MacConnection.State.Connected -> Txt.res(R.string.mac_connected_via, MacStatusText.describeHost(s.host))
            is MacConnection.State.Unreachable -> Txt.res(R.string.mac_not_reachable_now)
            is MacConnection.State.NeedsAttention -> Txt.res(R.string.mac_needs_attention)
        }
    }

    AosCard {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            HeroSymbol(if (sleeping != null) Icons.Rounded.Bedtime else Icons.Rounded.Laptop, tint = tint, size = 52.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(mac.name, style = MaterialTheme.typography.titleLarge)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    StatusDot(tint)
                    Text(stateLine.text(), style = MaterialTheme.typography.bodyMedium, color = colors.secondary)
                }
            }
        }
        if (sleeping != null) {
            Text(stringResource(R.string.mac_sleeping_explain), style = MaterialTheme.typography.bodySmall, color = colors.secondary)
        } else {
            when (val s = state) {
                is MacConnection.State.Unreachable, is MacConnection.State.NeedsAttention -> {
                    val message = (s as? MacConnection.State.Unreachable)?.message ?: (s as MacConnection.State.NeedsAttention).message
                    Text(ConnectionText.message(message).text(), style = MaterialTheme.typography.bodySmall, color = colors.secondary)
                    OutlinedButton(onClick = { connection.retryNow() }) {
                        Icon(Icons.Rounded.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(6.dp))
                        Text(stringResource(R.string.try_again))
                    }
                }
                is MacConnection.State.Connected -> when {
                    companion == MacConnection.CompanionState.NeedsPairing -> {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Icon(Icons.Rounded.Warning, contentDescription = null, tint = colors.orange, modifier = Modifier.size(18.dp))
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(stringResource(R.string.error_pair_again), style = MaterialTheme.typography.titleSmall)
                                Text(stringResource(R.string.mac_pair_again_explain), style = MaterialTheme.typography.bodySmall,
                                    color = colors.secondary)
                            }
                        }
                        Button(onClick = { ui.startPairing() }) {
                            Icon(Icons.Rounded.QrCodeScanner, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.size(6.dp))
                            Text(stringResource(R.string.pair_again))
                        }
                    }
                    problem != null -> ProblemLine(
                        if (problem!!.isEmpty()) stringResource(R.string.mac_app_not_answering)
                        else stringResource(R.string.mac_app_not_answering_detail, problem!!))
                    companion is MacConnection.CompanionState.Unavailable ->
                        ProblemLine(ConnectionText.message((companion as MacConnection.CompanionState.Unavailable).message).text())
                    status != null -> {
                        HorizontalDivider(color = colors.separator)
                        MacStatusRows(status!!, connection, actions)
                        val offer = MacOffer.now(status!!, hello?.features ?: emptySet(), sleeping != null)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            val enabled = actions.running == null
                            if (offer.sleep) ActionButton(Icons.Rounded.Bedtime, stringResource(R.string.mac_sleep), enabled) { confirmSleep = true }
                            if (offer.displayOff) ActionButton(Icons.Rounded.Monitor, stringResource(R.string.mac_display_off_action), enabled) {
                                actions.run(MacAction.DISPLAY_OFF, connection)
                            }
                            if (offer.displayOn) ActionButton(Icons.Rounded.LightMode, stringResource(R.string.mac_display_on_action), enabled) {
                                actions.run(MacAction.DISPLAY_ON, connection)
                            }
                            if (actions.running != null) SmallSpinner()
                        }
                        ProblemLine(actions.problem)
                    }
                    hello != null && hello!!.aos.isNotEmpty() -> Text(
                        if (connection.macStatusUnsupported) stringResource(R.string.mac_aos_answers_update, hello!!.aos)
                        else stringResource(R.string.mac_aos_answers, hello!!.aos),
                        style = MaterialTheme.typography.bodySmall, color = colors.secondary)
                    else -> Unit
                }
                else -> Unit
            }
        }
    }
    if (confirmSleep) {
        ConfirmDialog(
            title = stringResource(R.string.mac_sleep_question, mac.name),
            message = stringResource(R.string.mac_sleep_explain),
            confirm = stringResource(R.string.mac_sleep),
            onConfirm = { actions.run(MacAction.SLEEP, connection) },
            onDismiss = { confirmSleep = false },
        )
    }
}

/** A secondary button with a symbol (the iPhone's glass buttons). */
@Composable
fun ActionButton(icon: ImageVector?, title: String, enabled: Boolean = true, busy: Boolean = false, onClick: () -> Unit) {
    FilledTonalButton(onClick = onClick, enabled = enabled) {
        // While it is under way, the spinner takes the symbol's place (the button keeps its size).
        if (busy) SmallSpinner() else if (icon != null) Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
        if (busy || icon != null) Spacer(Modifier.size(6.dp))
        Text(title)
    }
}

@Composable
private fun MacStatusRows(status: MacStatus, connection: MacConnection, actions: ActionState) {
    val colors = AosTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        val power = status.power
        val display = status.display
        if (power != null || display != null) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (power != null) {
                    StatusTile(batteryIcon(power), MacStatusText.batteryValue(power).text(), MacStatusText.batteryCaption(power).text(),
                        Modifier.weight(1f), tint = batteryTint(power))
                    val hot = MacStatusText.isHot(power)
                    StatusTile(Icons.Rounded.Laptop, MacStatusText.lidTitle(power).text(),
                        (MacStatusText.thermalShort(power) ?: Txt.res(R.string.mac_cool)).text(), Modifier.weight(1f),
                        tint = if (hot) colors.orange else if (power.lid == "open") colors.indigo else colors.secondary,
                        captionTint = if (hot) colors.orange else colors.secondary)
                }
                if (display != null) {
                    StatusTile(Icons.Rounded.Monitor, MacStatusText.displayTitle(display).text(), MacStatusText.displayCaption(display).text(),
                        Modifier.weight(1f), tint = if (display.state == "on") colors.indigo else colors.secondary)
                }
            }
            HorizontalDivider(color = colors.separator)
        }
        val awake = status.awake ?: return@Column
        OverviewRow(
            icon = if (awake.setting == MacStayAwake.OFF) Icons.Rounded.Bedtime else Icons.Rounded.LightMode,
            title = stringResource(R.string.mac_stay_awake),
            detail = MacStatusText.awakeDetail(awake).text(),
            detailTint = if (MacStatusText.awakeWarns(awake)) colors.orange else colors.secondary,
        ) {
            if (!awake.otherService) {
                Picker(
                    current = MacStatusText.stayAwakeShortName(awake.setting).text(),
                    choices = MacStayAwake.entries.map { it to MacStatusText.stayAwakeName(it).text() },
                    enabled = actions.running == null,
                ) { mode -> actions.run(MacAction.STAY_AWAKE, connection, mode.raw) }
            }
        }
        val limit = awake.batteryLimit
        if (!awake.otherService && awake.setting == MacStayAwake.LID_CLOSED && limit != null && awake.batteryLimits.isNotEmpty()) {
            OverviewRow(
                icon = Icons.Rounded.Battery3Bar,
                title = stringResource(R.string.mac_battery_limit),
                detail = MacStatusText.batteryLimitDetail(limit).text(),
            ) {
                Picker(
                    current = MacStatusText.batteryLimitName(limit).text(),
                    choices = awake.batteryLimits.map { it to MacStatusText.batteryLimitName(it).text() },
                    enabled = actions.running == null,
                ) { p -> actions.run(MacAction.BATTERY_LIMIT, connection, p.toString()) }
            }
        }
    }
}

/** A value with a menu of choices (the iPhone's Menu with a Picker). */
@Composable
fun <T> Picker(current: String, choices: List<Pair<T, String>>, enabled: Boolean = true, onPick: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        TextButton(onClick = { open = true }, enabled = enabled) {
            Text(current)
            Icon(Icons.Rounded.UnfoldMore, contentDescription = null, modifier = Modifier.size(16.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            for ((value, label) in choices) {
                DropdownMenuItem(text = { Text(label) }, onClick = {
                    open = false
                    onPick(value)
                })
            }
        }
    }
}

fun batteryIcon(p: MacStatus.Power): ImageVector {
    val level = p.battery ?: return Icons.Rounded.Power
    if (p.charging == true) return Icons.Rounded.BatteryChargingFull
    return when {
        level >= 88 -> Icons.Rounded.BatteryFull
        level >= 50 -> Icons.Rounded.Battery5Bar
        level >= 13 -> Icons.Rounded.Battery3Bar
        else -> Icons.Rounded.Battery0Bar
    }
}

@Composable
private fun batteryTint(p: MacStatus.Power): Color {
    val colors = AosTheme.colors
    val level = p.battery ?: return colors.indigo
    if (p.charging == true) return colors.green
    return if (level < 15 && p.source == "battery") colors.red else colors.indigo
}

// Requests

@Composable
private fun RequestsCard(model: AppModel) {
    val colors = AosTheme.colors
    val questions by model.questions.collectAsState()
    val help by model.helpRequests.collectAsState()
    AosCard(tint = colors.attention) {
        OverviewRow(Icons.Rounded.PanTool, stringResource(R.string.waiting_for_you), tint = colors.attention)
        for (question in questions) {
            when (question) {
                is AppModel.Question.SignIn -> {
                    val r = question.request
                    OverviewRow(
                        icon = if (r.field == SignInRequest.Field.CODE) Icons.Rounded.Pin else Icons.Rounded.Key,
                        title = r.host, tint = colors.attention,
                        detail = if (r.field == SignInRequest.Field.CODE) stringResource(R.string.request_asks_code, agentName(r.agent))
                            else stringResource(R.string.request_asks_sign_in, agentName(r.agent)),
                        onClick = { model.present(question) },
                    )
                }
                is AppModel.Question.Approval -> {
                    val r = question.request
                    OverviewRow(
                        icon = Icons.Rounded.AddToQueue, tint = colors.attention,
                        title = r.purpose.ifEmpty { stringResource(R.string.approval_open_workspace) },
                        detail = stringResource(R.string.request_wants_workspace, agentName(r.agent)),
                        onClick = { model.present(question) },
                    )
                }
            }
        }
        for (request in help) {
            OverviewRow(
                icon = Icons.Rounded.TouchApp, tint = colors.attention,
                title = request.purpose.ifEmpty { stringResource(R.string.help_in_workspace) },
                detail = stringResource(R.string.request_asks_help, agentName(request.agent)),
                onClick = { model.showHelp(request) },
            )
        }
    }
}

@Composable
fun agentName(agent: String): String = agent.ifEmpty { stringResource(R.string.your_agent) }

// Workspace

@Composable
private fun WorkspaceCard(connection: MacConnection) {
    val ui = LocalAosUi.current
    val colors = AosTheme.colors
    val companion by connection.companionState.collectAsState()
    val sleeping by connection.sleepingSince.collectAsState()
    val workspace by connection.workspace.collectAsState()
    val status by connection.macStatus.collectAsState()
    val operation by connection.workspaceOperation.collectAsState()
    val timeout by connection.workspaceTimeout.collectAsState()
    val hello by connection.hello.collectAsState()
    val actions = rememberActionState()
    var confirmClose by remember { mutableStateOf(false) }
    var confirmSignOut by remember { mutableStateOf(false) }
    var signOutNote by remember { mutableStateOf<String?>(null) }
    val context = androidx.compose.ui.platform.LocalContext.current

    val live = companion == MacConnection.CompanionState.Ready && sleeping == null
    // Read the states through the flows above, so the card follows them.
    val state = operation?.shownState ?: status?.workspace?.state ?: workspace?.state?.name ?: "stopped"
    val icon = if (!live) Icons.Rounded.DesktopWindows else when (state) {
        "open", "running" -> Icons.Rounded.DesktopWindows
        "starting" -> Icons.Rounded.HourglassTop
        "closing" -> Icons.Rounded.CloseFullscreen
        "failed" -> Icons.Rounded.Warning
        else -> Icons.Rounded.Bedtime
    }

    AosCard {
        OverviewRow(icon, stringResource(R.string.workspace),
            detail = WorkspaceText.state(state, live, workspace != null || status != null, status?.workspace?.setupComplete).text())
        val w = workspace
        if (live && w != null && (w.state.name == "open" || w.state.name == "starting" || operation?.kind == WorkspaceOperation.Kind.STOP)) {
            if (w.purpose.isNotEmpty()) {
                Text("„${w.purpose}“", style = MaterialTheme.typography.bodyLarge, fontStyle = FontStyle.Italic,
                    modifier = Modifier.padding(start = IconColumn + 12.dp))
            }
            w.until?.let {
                Text(stringResource(R.string.workspace_open_until, Txt.Time(it, Txt.TimeStyle.TIME).text()),
                    style = MaterialTheme.typography.bodySmall, color = colors.secondary, modifier = Modifier.padding(start = IconColumn + 12.dp))
            }
        }
        val error = status?.workspace?.error
        if (live && error != null && state == "failed") {
            Text(error, style = MaterialTheme.typography.bodySmall, color = colors.orange, modifier = Modifier.padding(start = IconColumn + 12.dp))
        }
        if (live && w != null) {
            for (session in w.sessions) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Box(Modifier.size(IconColumn, 16.dp), contentAlignment = Alignment.Center) {
                        StatusDot(if (session.state == "running") colors.green else colors.gray)
                    }
                    Text(session.title, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                    Text(WorkspaceText.sessionState(session.state).text(), style = MaterialTheme.typography.bodySmall, color = colors.secondary)
                }
            }
        }
        if (live) {
            val starting = actions.running == MacAction.WORKSPACE_START || operation?.kind == WorkspaceOperation.Kind.START
            val closing = actions.running == MacAction.WORKSPACE_STOP || operation?.kind == WorkspaceOperation.Kind.STOP
            val viewable = state == "open" || state == "running" || (closing && (operation?.from ?: "") in listOf("open", "running"))
            val enabled = actions.running == null && operation == null
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (viewable) {
                    ActionButton(Icons.Rounded.DesktopWindows, stringResource(R.string.workspace_show_screen), enabled = enabled) {
                        ui.model.showScreen(ScreenTarget.WORKSPACE)
                    }
                }
                if (status != null) {
                    if (starting || (!closing && (state == "stopped" || state == "failed"))) {
                        ActionButton(Icons.Rounded.PlayArrow, stringResource(R.string.start),
                            enabled = enabled && status?.workspace?.setupComplete != false, busy = starting) {
                            actions.run(MacAction.WORKSPACE_START, connection)
                        }
                    } else if (closing || state in listOf("open", "running", "starting")) {
                        ActionButton(Icons.Rounded.Stop, stringResource(R.string.close), enabled = enabled, busy = closing) {
                            if (state == "open") confirmClose = true else actions.run(MacAction.WORKSPACE_STOP, connection)
                        }
                    }
                }
            }
            val canSignOut = hello?.features?.contains(MacAction.WORKSPACE_SIGN_OUT.raw) == true && status?.workspace?.setupComplete != false
            if (canSignOut) {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    ActionButton(Icons.Rounded.NoAccounts, stringResource(R.string.workspace_sign_out_all),
                        enabled = enabled, busy = actions.running == MacAction.WORKSPACE_SIGN_OUT) { confirmSignOut = true }
                    val note = signOutNote ?: if (status?.workspace?.signOutPending == true) stringResource(R.string.workspace_sign_out_pending) else null
                    if (note != null) Text(note, style = MaterialTheme.typography.bodySmall, color = colors.secondary)
                }
            }
        }
        ProblemLine(actions.problem ?: timeout?.let {
            stringResource(if (it.kind == WorkspaceOperation.Kind.START) R.string.workspace_start_timeout else R.string.workspace_close_timeout)
        })
    }
    if (confirmClose) {
        val purpose = workspace?.purpose ?: ""
        ConfirmDialog(
            title = stringResource(R.string.workspace_close_question),
            message = if (purpose.isNotEmpty()) stringResource(R.string.workspace_close_agent, purpose) else stringResource(R.string.workspace_close_plain),
            confirm = stringResource(R.string.close),
            onConfirm = { actions.run(MacAction.WORKSPACE_STOP, connection) },
            onDismiss = { confirmClose = false },
        )
    }
    if (confirmSignOut) {
        ConfirmDialog(
            title = stringResource(R.string.workspace_sign_out_question),
            message = stringResource(R.string.workspace_sign_out_explain),
            confirm = stringResource(R.string.workspace_sign_out_all),
            onConfirm = {
                signOutNote = null
                actions.run(MacAction.WORKSPACE_SIGN_OUT, connection) { result ->
                    signOutNote = context.getString(if (result.signOut == "atNextStart") R.string.workspace_sign_out_next_start
                        else R.string.workspace_signed_out)
                }
            },
            onDismiss = { confirmSignOut = false },
        )
    }
}

// aOS

@Composable
private fun AosCardView(connection: MacConnection) {
    val ui = LocalAosUi.current
    val colors = AosTheme.colors
    val status by connection.macStatus.collectAsState()
    val chats by connection.chats.collectAsState()
    val companion by connection.companionState.collectAsState()
    val hello by connection.hello.collectAsState()
    val actions = rememberActionState()
    var confirmRestart by remember { mutableStateOf(false) }
    val s = status ?: return
    val chatsSupported = companion == MacConnection.CompanionState.Ready && hello?.features?.contains(MacAction.CHATS_LIST.raw) == true

    AosCard {
        s.session?.let { session ->
            OverviewRow(Icons.Rounded.Forum, stringResource(R.string.session_title), detail = AosText.session(session).text(),
                detailTint = if (AosText.sessionWarns(session)) colors.orange else colors.secondary) {
                if (session.enabled && session.state != null) {
                    androidx.compose.material3.FilledTonalIconButton(onClick = { confirmRestart = true }, enabled = actions.running == null) {
                        Icon(Icons.Rounded.Refresh, contentDescription = stringResource(R.string.session_restart_label))
                    }
                }
            }
        }
        val routines = s.routines
        if (routines != null && routines.items.isNotEmpty()) {
            OverviewRow(Icons.Rounded.Schedule, stringResource(R.string.routines), detail = AosText.routines(routines).text(),
                onClick = { ui.overview.push(OverviewPage.Routines) })
        }
        val sessionSignIn = s.session?.let { it.enabled && it.state == "needsLogin" } ?: false
        if (sessionSignIn) SignInHelp { ui.model.openNewTerminal() }
        val newChats = s.newChats
        val newChatsSignIn = newChats?.let { it.enabled && it.state == "needsLogin" } ?: false
        if (chatsSupported) {
            OverviewRow(Icons.Rounded.QuestionAnswer, stringResource(R.string.chats),
                detail = ChatsText.overview(chats, newChats, s.kept).text(),
                detailTint = if (newChatsSignIn) colors.orange else colors.secondary,
                onClick = { ui.overview.push(OverviewPage.Chats) })
        } else if (newChats != null) {
            OverviewRow(Icons.Rounded.AddComment, stringResource(R.string.new_chats_title), detail = AosText.newChats(newChats).text(),
                detailTint = if (newChatsSignIn) colors.orange else colors.secondary)
        }
        if (!sessionSignIn && AosText.needsSignIn(s)) SignInHelp { ui.model.openNewTerminal() }
        val kept = s.kept
        if (kept != null && !chatsSupported) {
            OverviewRow(Icons.AutoMirrored.Rounded.Chat, stringResource(R.string.kept_title), detail = AosText.kept(kept).text())
        }
        s.apps?.let { apps ->
            OverviewRow(Icons.Rounded.Apps, stringResource(R.string.apps), detail = AppsText.overview(apps).text(),
                detailTint = if (apps.state == "notPaired") colors.orange else colors.secondary,
                onClick = { ui.overview.push(OverviewPage.Apps) })
        }
        s.bitwarden?.let { vault ->
            OverviewRow(if (vault.state == "unlocked") Icons.Rounded.LockOpen else Icons.Rounded.Lock, "Bitwarden",
                detail = AosText.vault(vault).text()) {
                if (vault.state == "unlocked") {
                    ActionButton(Icons.Rounded.Lock, stringResource(R.string.lock), enabled = actions.running == null) {
                        actions.run(MacAction.BITWARDEN_LOCK, connection)
                    }
                }
            }
        }
        ProblemLine(actions.problem)
    }
    if (confirmRestart) {
        ConfirmDialog(
            title = stringResource(R.string.session_restart_question),
            message = stringResource(R.string.session_restart_explain),
            confirm = stringResource(R.string.restart),
            destructive = false,
            onConfirm = { actions.run(MacAction.SESSION_RESTART, connection) },
            onDismiss = { confirmRestart = false },
        )
    }
}

/** What to do when Claude Code on the Mac needs a sign-in: `claude` once in a terminal there, from here too. */
@Composable
fun SignInHelp(openTerminal: () -> Unit) {
    Column(Modifier.padding(start = IconColumn + 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(stringResource(R.string.sign_in_help), style = MaterialTheme.typography.bodySmall)
        Button(onClick = openTerminal) {
            Icon(Icons.Rounded.Terminal, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.size(6.dp))
            Text(stringResource(R.string.open_terminal))
        }
    }
}

/** What is where, said plainly. */
@Composable
private fun PromiseCard() {
    Column(Modifier.padding(horizontal = 16.dp).padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        FactRow(Icons.Rounded.Fingerprint, stringResource(R.string.promise_bitwarden))
        FactRow(Icons.Rounded.VisibilityOff, stringResource(R.string.promise_no_password))
        FactRow(Icons.Rounded.Lock, stringResource(R.string.promise_ssh))
    }
}

// Welcome

@Composable
private fun WelcomeView() {
    val ui = LocalAosUi.current
    val colors = AosTheme.colors
    Column(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(20.dp)) {
        AppIconImage(88.dp)
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.welcome_title), style = MaterialTheme.typography.headlineMedium, textAlign = TextAlign.Center)
            Text(stringResource(R.string.welcome_subtitle), style = MaterialTheme.typography.titleMedium, color = colors.secondary,
                textAlign = TextAlign.Center)
        }
        AosCard {
            WelcomePoint(Icons.Rounded.Key, stringResource(R.string.welcome_sign_ins), stringResource(R.string.welcome_sign_ins_text))
            WelcomePoint(Icons.Rounded.Terminal, stringResource(R.string.terminal), stringResource(R.string.welcome_terminal_text))
            WelcomePoint(Icons.Rounded.DesktopWindows, stringResource(R.string.screen), stringResource(R.string.welcome_screen_text))
        }
        Button(onClick = { ui.startPairing() }, modifier = Modifier.fillMaxWidth().height(52.dp)) {
            Icon(Icons.Rounded.QrCodeScanner, contentDescription = null)
            Spacer(Modifier.size(8.dp))
            Text(stringResource(R.string.pair_with_mac))
        }
        Text(stringResource(R.string.welcome_how_to_pair), style = MaterialTheme.typography.bodySmall, color = colors.secondary,
            textAlign = TextAlign.Center)
    }
}

@Composable
private fun WelcomePoint(icon: ImageVector, title: String, text: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Icon(icon, contentDescription = null, tint = AosTheme.colors.indigo, modifier = Modifier.size(IconColumn))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(text, style = MaterialTheme.typography.bodyMedium, color = AosTheme.colors.secondary)
        }
    }
}

