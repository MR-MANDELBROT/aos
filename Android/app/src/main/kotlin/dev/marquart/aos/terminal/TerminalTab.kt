package dev.marquart.aos.terminal

import androidx.compose.runtime.movableContentOf
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import dev.marquart.aos.ui.layout.AdaptiveSheet
import dev.marquart.aos.ui.layout.LocalWindowLayout
import dev.marquart.aos.ui.layout.PanePlaceholder
import dev.marquart.aos.ui.layout.TwoPane
import dev.marquart.aos.ui.layout.contextClick
import android.Manifest
import android.content.ClipboardManager
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.AddCircle
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Cancel
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material.icons.rounded.KeyboardHide
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.PowerSettingsNew
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Terminal
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material.icons.rounded.SystemUpdate
import androidx.compose.material.icons.rounded.Logout
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import dev.marquart.aos.R
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.core.MacTermSession
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.model.AppModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * The Terminal tab (iOS TerminalTab): the terminal sessions on the paired Mac, a new one, and the terminal that shows
 * one of them. The list (`term list`, every 10 s while it is on screen) opens a session here or ends it (swipe, or the
 * long-press menu); New Session starts another shell on the Mac. The terminal has New Session, Switch Session and End
 * Session in its menu and the session's name as its subtitle. Back (or the arrow) returns to the list; the terminal
 * stays attached (and the foreground service keeps it while the app is in the background).
 */
@Composable
fun TerminalTab(model: AppModel, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val controller = remember(model) { TerminalController.of(context, model) }
    val macs by model.macs.collectAsState()
    val mac = macs.firstOrNull()
    val showing by controller.showing.collectAsState()
    val request by model.terminalRequest.collectAsState()

    DisposableEffect(context) {
        (context as? android.app.Activity)?.let(controller::watch)
        onDispose {}
    }
    // "Open Terminal" from the Overview: a new session on the Mac, shown.
    LaunchedEffect(request, mac) {
        if (request != null && mac != null) {
            controller.openNewTerminal(mac)
            model.terminalRequestHandled()
        }
    }

    val twoPane = LocalWindowLayout.current.twoPane
    // The terminal keeps its view (scrollback position, selection, keyboard) while the window changes its shape and
    // the terminal moves beside the list or back to a page of its own.
    val terminalScreen = remember(controller) {
        movableContentOf<MacTerminal, PairedMac, Boolean> { terminal, shownMac, inPane ->
            TerminalScreen(controller, terminal, shownMac, inPane) { controller.showing.value = null }
        }
    }
    Surface(modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        when {
            mac == null -> NoMac()
            // A wide window: the sessions beside the terminal.
            twoPane -> TwoPane(
                listWidth = 320.dp,
                list = { SessionList(controller, mac, inPane = true, shown = showing == mac.id) },
                detail = {
                    if (showing == mac.id) terminalScreen(controller.terminal(mac), mac, true)
                    else PanePlaceholder(Icons.Rounded.Terminal, stringResource(R.string.term_pane_empty)) {
                        Button(onClick = { controller.openNewTerminal(mac) }) { Text(stringResource(R.string.term_new_session)) }
                    }
                },
            )
            showing == mac.id -> terminalScreen(controller.terminal(mac), mac, false)
            else -> SessionList(controller, mac)
        }
    }
}

/** True while the Terminal tab shows a terminal (the shell may hide its tab bar then, as the iPhone does). */
@Composable
fun terminalIsShown(model: AppModel): Boolean {
    val context = LocalContext.current
    val controller = remember(model) { TerminalController.of(context, model) }
    val showing by controller.showing.collectAsState()
    return showing != null
}

@Composable
private fun NoMac() {
    Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(Icons.Rounded.Terminal, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(48.dp))
        Spacer(Modifier.height(12.dp))
        Text(stringResource(R.string.term_no_mac), style = MaterialTheme.typography.titleLarge)
        Spacer(Modifier.height(6.dp))
        Text(stringResource(R.string.term_no_mac_text), textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

// The session list

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SessionList(controller: TerminalController, mac: PairedMac, inPane: Boolean = false, shown: Boolean = false) {
    val model = controller.model
    val scope = rememberCoroutineScope()
    val sessions by controller.sessions.sessions.collectAsState()
    val loaded by controller.sessions.loaded.collectAsState()
    val connection by model.connection.collectAsState()
    val state by model.connectionState.collectAsState()
    val connected = state is MacConnection.State.Connected
    var refreshing by remember { mutableStateOf(false) }
    var ending by remember { mutableStateOf<MacTermSession?>(null) }
    var showSettings by remember { mutableStateOf(false) }
    val terminal = controller.existing(mac.id)
    val terminalPhase by (terminal?.phase ?: flowOf(MacTerminal.Phase.Idle)).collectAsState(MacTerminal.Phase.Idle)
    val terminalHolder by (terminal?.holderId ?: flowOf(null)).collectAsState(null)
    val home = "/Users/${mac.user}"

    // While the list is on screen: now and every 10 s (what runs in the sessions changes).
    LaunchedEffect(connected, model.demo) {
        while (true) {
            if (model.demo != null) controller.sessions.showDemo(connection?.phoneId) else controller.sessions.load(model)
            delay(10_000)
        }
    }

    fun open(session: MacTermSession) {
        val t = controller.terminal(mac)
        if (model.demo != null) t.showDemo(TerminalController.DEMO_TEXT, session.id) else t.switchTo(session.id)
        controller.showing.value = mac.id
    }

    fun newSession() = controller.openNewTerminal(mac)

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(stringResource(R.string.term_title)) },
            actions = {
                IconButton(onClick = { showSettings = true }) {
                    Icon(Icons.Rounded.Settings, contentDescription = stringResource(R.string.term_settings))
                }
            },
        )
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = {
                scope.launch {
                    refreshing = true
                    connection?.retryNow()
                    controller.sessions.load(model)
                    refreshing = false
                }
            },
            modifier = Modifier.fillMaxSize(),
        ) {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 24.dp)) {
                item {
                    Card(
                        onClick = ::newSession,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
                    ) {
                        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Rounded.AddCircle, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                            Spacer(Modifier.size(12.dp))
                            Text(stringResource(R.string.term_new_session), fontWeight = FontWeight.SemiBold,
                                color = MaterialTheme.colorScheme.primary)
                        }
                    }
                    Footnote(stringResource(R.string.term_new_session_footer, mac.name))
                    SectionHeader(stringResource(R.string.term_sessions_header))
                    connectionNote(model, connection)?.let { (text, icon) -> Note(text, icon) }
                    if (loaded && sessions.isEmpty() && connectionNote(model, connection) == null) {
                        Footnote(stringResource(R.string.term_no_sessions))
                    }
                }
                items(sessions, key = { it.id }) { session ->
                    val open = if (terminal != null && terminalPhase.isOpenPhase()) terminalHolder else null
                    val holder = session.holder(open, connection?.phoneId, terminalHolder ?: controller.settings.holderId(mac.id))
                    // Beside the terminal: the session it shows is marked.
                    SessionRow(session, home, holder, selected = inPane && shown && session.id == terminalHolder,
                        onOpen = { open(session) }, onEnd = { ending = session })
                }
                item { Footnote(stringResource(R.string.term_sessions_footer)) }
            }
        }
    }

    ending?.let { session ->
        EndConfirmation(onEnd = {
            ending = null
            scope.launch { controller.sessions.end(session, model, controller.existing(mac.id)) }
        }, onCancel = { ending = null })
    }
    if (showSettings) SettingsSheet { showSettings = false }
}

private fun MacTerminal.Phase.isOpenPhase() =
    this == MacTerminal.Phase.Connecting || this == MacTerminal.Phase.Connected || this == MacTerminal.Phase.Reconnecting

/** Why the list may be old or empty: the Mac sleeps, isn't reachable, or can't hold sessions. */
@Composable
private fun connectionNote(model: AppModel, connection: MacConnection?): Pair<String, ImageVector>? {
    if (model.demo != null || connection == null) return null
    val state by connection.state.collectAsState()
    val sleeping by connection.sleepingSince.collectAsState()
    val hello by connection.hello.collectAsState()
    val companion by connection.companionState.collectAsState()
    sleeping?.let { since ->
        val time = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).format(since.atZone(ZoneId.systemDefault()))
        return stringResource(R.string.term_mac_sleeping_since, time) to Icons.Rounded.Bedtime
    }
    return when (state) {
        is MacConnection.State.Connected -> {
            val h = hello
            if (h != null && companion == MacConnection.CompanionState.Ready && "term" !in h.features) {
                stringResource(R.string.term_update_aos_list) to Icons.Rounded.SystemUpdate
            } else null
        }
        MacConnection.State.Idle, MacConnection.State.Connecting -> stringResource(R.string.term_connecting_mac) to Icons.Rounded.Sync
        else -> stringResource(R.string.term_mac_unreachable_sessions) to Icons.Rounded.WifiOff
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
private fun SessionRow(session: MacTermSession, home: String, holder: MacTermSession.Holder, selected: Boolean = false, onOpen: () -> Unit,
                       onEnd: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val dismiss = rememberSwipeToDismissBoxState(confirmValueChange = { value ->
        // Swiped to end: ask first; the row springs back.
        if (value == SwipeToDismissBoxValue.EndToStart) onEnd()
        false
    })
    SwipeToDismissBox(
        state = dismiss,
        enableDismissFromStartToEnd = false,
        backgroundContent = {
            Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.errorContainer).padding(horizontal = 24.dp),
                contentAlignment = Alignment.CenterEnd) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.Cancel, contentDescription = null, tint = MaterialTheme.colorScheme.onErrorContainer)
                    Spacer(Modifier.size(6.dp))
                    Text(stringResource(R.string.term_end), color = MaterialTheme.colorScheme.onErrorContainer)
                }
            }
        },
    ) {
        Box {
            ListItem(
                // A secondary click (mouse, trackpad) opens the menu a long press opens.
                modifier = Modifier.contextClick { menu = true }.combinedClickable(onClick = onOpen, onLongClick = { menu = true }),
                colors = ListItemDefaults.colors(containerColor = if (selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)
                    .compositeOver(MaterialTheme.colorScheme.background) else MaterialTheme.colorScheme.background),
                leadingContent = {
                    Icon(Icons.Rounded.Terminal, contentDescription = null,
                        tint = if (holder == MacTermSession.Holder.Nobody) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary)
                },
                headlineContent = { Text(session.title ?: place(session, home), maxLines = 1, overflow = TextOverflow.Ellipsis) },
                supportingContent = { Text(detail(session, holder), maxLines = 1, overflow = TextOverflow.Ellipsis) },
            )
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text(stringResource(R.string.term_open_session)) }, leadingIcon = { Icon(Icons.Rounded.Terminal, null) },
                    onClick = { menu = false; onOpen() })
                DropdownMenuItem(text = { Text(stringResource(R.string.term_end_session), color = MaterialTheme.colorScheme.error) },
                    leadingIcon = { Icon(Icons.Rounded.Cancel, null, tint = MaterialTheme.colorScheme.error) },
                    onClick = { menu = false; onEnd() })
            }
        }
    }
}

/** "zsh in ~/Developer/aos", from the Mac user's home folder. */
@Composable
private fun place(session: MacTermSession, home: String): String {
    var folder = session.cwd ?: ""
    if (folder == home) folder = "~" else if (folder.startsWith("$home/")) folder = "~" + folder.substring(home.length)
    val program = session.command ?: "shell"
    return if (folder.isEmpty()) program else stringResource(R.string.term_place, program, folder)
}

@Composable
private fun detail(session: MacTermSession, holder: MacTermSession.Holder): String = when (holder) {
    MacTermSession.Holder.Here -> stringResource(R.string.term_open_here_phone)
    is MacTermSession.Holder.Elsewhere -> when (val from = holder.from) {
        // `term attach` in a terminal on the Mac itself says "local".
        "local" -> stringResource(R.string.term_open_on_mac)
        null -> stringResource(R.string.term_open_elsewhere)
        else -> stringResource(R.string.term_open_elsewhere_from, from)
    }
    MacTermSession.Holder.Nobody -> session.since?.let { since ->
        val local = since.atZone(ZoneId.systemDefault())
        val text = if (local.toLocalDate() == LocalDate.now()) DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).format(local)
        else DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).format(local)
        stringResource(R.string.term_not_open_since, text)
    } ?: stringResource(R.string.term_not_open)
}

@Composable
private fun SectionHeader(text: String) {
    Text(text.uppercase(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 32.dp, end = 32.dp, top = 16.dp, bottom = 4.dp))
}

@Composable
private fun Footnote(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 32.dp, vertical = 4.dp))
}

@Composable
private fun Note(text: String, icon: ImageVector) {
    Row(Modifier.padding(horizontal = 24.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(18.dp))
        Spacer(Modifier.size(8.dp))
        Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun EndConfirmation(onEnd: () -> Unit, onCancel: () -> Unit) {
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text(stringResource(R.string.term_end_confirm_title)) },
        text = { Text(stringResource(R.string.term_end_confirm_text)) },
        confirmButton = {
            TextButton(onClick = onEnd) { Text(stringResource(R.string.term_end_session), color = MaterialTheme.colorScheme.error) }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text(stringResource(R.string.term_cancel)) } },
    )
}

// The terminal

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun TerminalScreen(controller: TerminalController, terminal: MacTerminal, mac: PairedMac, inPane: Boolean, onBack: () -> Unit) {
    val context = LocalContext.current
    val model = controller.model
    val settings = controller.settings
    val phase by terminal.phase.collectAsState()
    val endReason by terminal.endReason.collectAsState()
    val notice by terminal.notice.collectAsState()
    val pendingPaste by terminal.pendingPaste.collectAsState()
    val holderId by terminal.holderId.collectAsState()
    val sessions by controller.sessions.sessions.collectAsState()
    val arrows by settings.arrowKeys.collectAsState()
    val keepScreenOn by settings.keepScreenOn.collectAsState()
    val keepConnected by settings.keepConnected.collectAsState()
    val connection by model.connection.collectAsState()
    val sleeping by (connection?.sleepingSince ?: flowOf(null)).collectAsState(null)
    val keyboardShown = WindowInsets.isImeVisible
    var host by remember { mutableStateOf<TerminalHost?>(null) }
    var showSettings by remember { mutableStateOf(false) }
    val home = "/Users/${mac.user}"
    val sessionName = controller.sessions.name(holderId, home) { it.place(home) }

    // Beside the session list the terminal isn't a page of its own: back leaves the app as from any tab.
    BackHandler(enabled = !inPane, onBack = onBack)
    val layout = LocalWindowLayout.current
    val density = LocalDensity.current
    // A device standing on its lower half: the terminal above the fold, the key bar below it.
    val table = layout.tableFold
    var top by remember { mutableFloatStateOf(0f) }

    LaunchedEffect(terminal) {
        if (terminal.phase.value == MacTerminal.Phase.Idle) {
            if (model.demo != null) terminal.showDemo(TerminalController.DEMO_TEXT) else terminal.connect()
        }
        if (model.demo == null) controller.sessions.load(model)
    }
    // A new session shows up in the menu's list once it runs.
    LaunchedEffect(phase) {
        if (phase == MacTerminal.Phase.Connected && model.demo == null) controller.sessions.load(model)
    }
    // The keyboard went away: the key bar's modifiers too.
    LaunchedEffect(keyboardShown) { if (!keyboardShown) terminal.resetModifiers() }
    // While the terminal is on screen and connected, if the person wants that.
    LaunchedEffect(host, keepScreenOn, phase) { host?.keepScreenOn = keepScreenOn && phase == MacTerminal.Phase.Connected }

    // The notification for the background needs the permission (Android 13+): asked once, when a terminal opens.
    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    LaunchedEffect(keepConnected) {
        if (keepConnected && model.demo == null && Build.VERSION.SDK_INT >= 33 && !settings.askedForNotifications &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            settings.askedForNotifications = true
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    Column(
        Modifier.fillMaxSize().then(if (table == null) Modifier.imePadding() else Modifier)
            .onGloballyPositioned { top = with(density) { it.positionInWindow().y.toDp().value } },
    ) {
        // The title bar and the terminal: all of the screen, or its part above the fold.
        Column(if (table != null) Modifier.height((table.top - top).coerceAtLeast(160f).dp) else Modifier.weight(1f)) {
            TopAppBar(
                navigationIcon = {
                    if (!inPane) {
                        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = stringResource(R.string.term_back)) }
                    }
                },
                title = {
                    Column {
                        val title by terminal.title.collectAsState()
                        Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleMedium)
                        if (sessionName != null) {
                            Text(sessionName, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                },
                actions = {
                    IconButton(onClick = { if (keyboardShown) host?.hideKeyboard() else host?.showKeyboard() }) {
                        Icon(if (keyboardShown) Icons.Rounded.KeyboardHide else Icons.Rounded.Keyboard,
                            contentDescription = stringResource(if (keyboardShown) R.string.term_hide_keyboard else R.string.term_show_keyboard))
                    }
                    TerminalMenu(controller, terminal, mac, sessions.filter { it.id != holderId }, home,
                        topRow = { host?.view?.topRow ?: 0 }, onSettings = { showSettings = true })
                },
            )
            Box(Modifier.weight(1f).fillMaxWidth()) {
                AndroidView(
                    factory = { TerminalHost(it, terminal, settings).also { created -> host = created } },
                    onRelease = { it.release() },
                    modifier = Modifier.fillMaxSize(),
                )
                when (phase) {
                    MacTerminal.Phase.Connecting -> Surface(Modifier.align(Alignment.Center), shape = RoundedCornerShape(20.dp),
                        color = MaterialTheme.colorScheme.surfaceContainerHigh, tonalElevation = 4.dp) {
                        Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.5.dp)
                            Spacer(Modifier.size(12.dp))
                            Text(stringResource(R.string.term_connecting))
                        }
                    }
                    is MacTerminal.Phase.Failed -> StateOverlay(Icons.Rounded.Warning,
                        (phase as MacTerminal.Phase.Failed).message ?: stringResource(R.string.term_doesnt_start),
                        stringResource(R.string.term_try_again)) { terminal.connect() }
                    MacTerminal.Phase.Ended -> when (endReason) {
                        MacTerminal.EndReason.TAKEN -> StateOverlay(Icons.Rounded.Logout, stringResource(R.string.term_taken),
                            stringResource(R.string.term_open_it_here)) { terminal.connect() }
                        MacTerminal.EndReason.EXITED -> StateOverlay(Icons.Rounded.PowerSettingsNew, stringResource(R.string.term_shell_ended),
                            stringResource(R.string.term_new_session)) { controller.openNewTerminal(mac) }
                        MacTerminal.EndReason.ENDED -> StateOverlay(Icons.Rounded.PowerSettingsNew, stringResource(R.string.term_session_was_ended),
                            stringResource(R.string.term_new_session)) { controller.openNewTerminal(mac) }
                        MacTerminal.EndReason.CLOSED -> StateOverlay(Icons.Rounded.PowerSettingsNew, stringResource(R.string.term_session_ended),
                            stringResource(R.string.term_connect_again)) { terminal.connect() }
                    }
                    else -> Unit
                }
                val banner: Pair<String, ImageVector>? = when {
                    phase == MacTerminal.Phase.Reconnecting && sleeping != null -> stringResource(R.string.term_mac_sleeping) to Icons.Rounded.Bedtime
                    phase == MacTerminal.Phase.Reconnecting -> stringResource(R.string.term_reconnecting) to Icons.Rounded.Sync
                    else -> notice?.let { noticeText(it) to null }?.let { (text, _) -> text to Icons.Rounded.Terminal }
                }
                Banner(banner, showIcon = phase == MacTerminal.Phase.Reconnecting, modifier = Modifier.align(Alignment.TopCenter).padding(top = 10.dp))
            }
        }
        // Nothing under the hinge.
        if (table != null) Spacer(Modifier.height((table.bottom - table.top).dp))
        TerminalKeyBar(terminal, arrows, onPaste = {
            val clip = context.getSystemService(ClipboardManager::class.java)?.primaryClip
            val text = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
            if (!text.isNullOrEmpty()) terminal.paste(text)
        })
        // The lower half below the key bar: where the on-screen keyboard comes up.
        if (table != null) Spacer(Modifier.weight(1f))
    }

    pendingPaste?.let { text ->
        val lines = text.lines().count { it.isNotEmpty() }.coerceAtLeast(1)
        AlertDialog(
            onDismissRequest = { terminal.cancelPaste() },
            title = { Text(stringResource(R.string.term_paste_lines_title, lines)) },
            text = { Text(stringResource(R.string.term_paste_lines_text)) },
            confirmButton = { TextButton(onClick = { terminal.confirmPaste(text) }) { Text(stringResource(R.string.term_paste)) } },
            dismissButton = { TextButton(onClick = { terminal.cancelPaste() }) { Text(stringResource(R.string.term_cancel)) } },
        )
    }
    if (showSettings) SettingsSheet { showSettings = false }
}

/** "Reconnecting …" or a notice, over the top of the terminal. */
@Composable
private fun Banner(banner: Pair<String, ImageVector>?, showIcon: Boolean, modifier: Modifier) {
    AnimatedVisibility(banner != null, enter = fadeIn(), exit = fadeOut(), modifier = modifier) {
        val (text, icon) = banner ?: ("" to Icons.Rounded.Terminal)
        Surface(shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.surfaceContainerHighest, tonalElevation = 4.dp,
            shadowElevation = 2.dp, modifier = Modifier.padding(horizontal = 16.dp)) {
            Row(Modifier.padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (showIcon) {
                    Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.size(6.dp))
                }
                Text(text, style = MaterialTheme.typography.labelLarge)
            }
        }
    }
}

@Composable
private fun noticeText(notice: MacTerminal.Notice): String = when (notice.kind) {
    MacTerminal.Notice.Kind.SESSION_WAS_NEW -> stringResource(R.string.term_session_was_new)
    MacTerminal.Notice.Kind.UPDATE_AOS -> stringResource(R.string.term_update_aos)
    MacTerminal.Notice.Kind.AOS_MISSING -> stringResource(R.string.term_aos_missing)
    MacTerminal.Notice.Kind.MAC_UNREACHABLE -> stringResource(R.string.term_mac_unreachable)
    MacTerminal.Notice.Kind.SCREEN_COPIED -> stringResource(R.string.term_screen_copied)
    MacTerminal.Notice.Kind.OUTPUT_COPIED -> stringResource(R.string.term_output_copied)
    MacTerminal.Notice.Kind.NO_OUTPUT -> stringResource(R.string.term_no_output)
    MacTerminal.Notice.Kind.COPIED -> stringResource(R.string.term_copied)
    MacTerminal.Notice.Kind.LINK_COPIED -> stringResource(R.string.term_link_copied)
    MacTerminal.Notice.Kind.FONT_SIZE -> stringResource(R.string.term_font_size_notice, notice.size, notice.columns, notice.rows)
}

@Composable
private fun StateOverlay(icon: ImageVector, text: String, action: String, perform: () -> Unit) {
    Box(Modifier.fillMaxSize().padding(16.dp), contentAlignment = Alignment.Center) {
        Surface(shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh, tonalElevation = 6.dp,
            shadowElevation = 4.dp, modifier = Modifier.widthIn(max = 340.dp)) {
            Column(Modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(36.dp))
                Text(text, textAlign = TextAlign.Center)
                Button(onClick = perform) { Text(action) }
            }
        }
    }
}

/** The terminal's menu: copying, text size, keeping the screen on, and the Mac's sessions (a new one, another one,
 *  ending this one). */
@Composable
private fun TerminalMenu(controller: TerminalController, terminal: MacTerminal, mac: PairedMac, others: List<MacTermSession>,
                         home: String, topRow: () -> Int, onSettings: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    var switching by remember { mutableStateOf(false) }
    var confirmEnd by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val holdsSession by terminal.holdsSession.collectAsState()
    val holderId by terminal.holderId.collectAsState()
    val phase by terminal.phase.collectAsState()
    val keepScreenOn by controller.settings.keepScreenOn.collectAsState()
    // Something to end: the session on the Mac, or a plain shell (an older aOS on the Mac).
    val canEnd = if (holdsSession) holderId != null else phase.isOpenPhase()
    val demo = controller.model.demo != null

    fun size(to: Int) {
        terminal.setFontSize(to)
        controller.settings.setFontSize(terminal.fontSize.value)
    }

    Box {
        IconButton(onClick = { open = true }) { Icon(Icons.Rounded.MoreVert, contentDescription = stringResource(R.string.term_more)) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false; switching = false }) {
            if (switching) {
                others.forEach { other ->
                    DropdownMenuItem(text = { Text(other.title ?: other.place(home), maxLines = 1, overflow = TextOverflow.Ellipsis) }, onClick = {
                        open = false
                        switching = false
                        if (demo) terminal.showDemo(TerminalController.DEMO_TEXT, other.id) else terminal.switchTo(other.id)
                    })
                }
                return@DropdownMenu
            }
            DropdownMenuItem(text = { Text(stringResource(R.string.term_copy_screen)) }, onClick = { open = false; terminal.copyScreen(topRow()) })
            DropdownMenuItem(text = { Text(stringResource(R.string.term_copy_last_output)) }, onClick = { open = false; terminal.copyLastOutput() })
            HorizontalDivider()
            DropdownMenuItem(text = { Text(stringResource(R.string.term_smaller_text)) }, onClick = { size(terminal.fontSize.value - 1) })
            DropdownMenuItem(text = { Text(stringResource(R.string.term_default_text_size)) }, onClick = { size(TerminalFontSize.STANDARD) })
            DropdownMenuItem(text = { Text(stringResource(R.string.term_bigger_text)) }, onClick = { size(terminal.fontSize.value + 1) })
            HorizontalDivider()
            DropdownMenuItem(text = { Text(stringResource(R.string.term_keep_screen_on)) },
                trailingIcon = { Switch(checked = keepScreenOn, onCheckedChange = null) },
                onClick = { controller.settings.setKeepScreenOn(!keepScreenOn) })
            DropdownMenuItem(text = { Text(stringResource(R.string.term_settings)) }, onClick = { open = false; onSettings() })
            HorizontalDivider()
            DropdownMenuItem(text = { Text(stringResource(R.string.term_new_session)) }, onClick = { open = false; controller.openNewTerminal(mac) })
            if (others.isNotEmpty()) {
                DropdownMenuItem(text = { Text(stringResource(R.string.term_switch_session)) }, onClick = { switching = true })
            }
            if (canEnd) {
                DropdownMenuItem(text = { Text(stringResource(R.string.term_end_session), color = MaterialTheme.colorScheme.error) },
                    onClick = { open = false; confirmEnd = true })
            }
            Text(stringResource(R.string.term_sessions_keep_running), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp).widthIn(max = 240.dp))
        }
    }
    if (confirmEnd) {
        EndConfirmation(onEnd = {
            confirmEnd = false
            scope.launch { terminal.endSession() }
        }, onCancel = { confirmEnd = false })
    }
}

// Settings

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsSheet(onDone: () -> Unit) {
    // From the bottom edge on a phone, a dialog in the middle of a large window.
    AdaptiveSheet(onDismiss = onDone, containerColor = MaterialTheme.colorScheme.surfaceContainerLow) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(top = 12.dp, bottom = 24.dp)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.term_title), style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                TextButton(onClick = onDone) { Text(stringResource(R.string.term_done)) }
            }
            TerminalSettingsSection()
        }
    }
}

/**
 * Settings > Terminal (for the settings page): the key bar's arrows, swiping for arrow keys, the text size, keeping the
 * screen on, and keeping the connection in the background.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalSettingsSection(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val settings = remember { TerminalSettings.get(context) }
    val arrows by settings.arrowKeys.collectAsState()
    val swipe by settings.swipeArrows.collectAsState()
    val fontSize by settings.fontSize.collectAsState()
    val keepScreenOn by settings.keepScreenOn.collectAsState()
    val keepConnected by settings.keepConnected.collectAsState()

    Column(modifier.fillMaxWidth()) {
        SectionHeader(stringResource(R.string.term_settings_keys))
        Column(Modifier.padding(horizontal = 16.dp)) {
            Text(stringResource(R.string.term_settings_arrow_keys), style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.padding(vertical = 8.dp))
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                listOf(TerminalArrowKeys.PAD to R.string.term_arrow_pad, TerminalArrowKeys.FOUR_KEYS to R.string.term_settings_four_keys)
                    .forEachIndexed { index, (value, label) ->
                        SegmentedButton(selected = arrows == value, onClick = { settings.setArrowKeys(value) },
                            shape = SegmentedButtonDefaults.itemShape(index, 2)) { Text(stringResource(label)) }
                    }
            }
        }
        SwitchRow(stringResource(R.string.term_settings_swipe), swipe, settings::setSwipeArrows)
        Footnote(stringResource(R.string.term_settings_keys_footer))

        SectionHeader(stringResource(R.string.term_text_size))
        Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Slider(value = fontSize.toFloat(), onValueChange = { new -> settings.setFontSize(new.toInt()) }, valueRange = TerminalFontSize.MIN.toFloat()..TerminalFontSize.MAX.toFloat(),
                steps = TerminalFontSize.MAX - TerminalFontSize.MIN - 1, modifier = Modifier.weight(1f))
            Spacer(Modifier.size(12.dp))
            Text("$fontSize pt", style = MaterialTheme.typography.bodyMedium)
        }
        SwitchRow(stringResource(R.string.term_keep_screen_on), keepScreenOn, settings::setKeepScreenOn)
        Footnote(stringResource(R.string.term_settings_screen_on_footer))

        SectionHeader(stringResource(R.string.term_settings_background))
        SwitchRow(stringResource(R.string.term_settings_keep_connected), keepConnected, settings::setKeepConnected)
        Footnote(stringResource(R.string.term_settings_background_footer))
        if (keepConnected && !NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            Note(stringResource(R.string.term_settings_notifications_off), Icons.Rounded.Warning)
        }
    }
}

@Composable
private fun SwitchRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    ListItem(
        headlineContent = { Text(title) },
        trailingContent = { Switch(checked = checked, onCheckedChange = onChange) },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = Modifier.padding(horizontal = 4.dp),
    )
}
