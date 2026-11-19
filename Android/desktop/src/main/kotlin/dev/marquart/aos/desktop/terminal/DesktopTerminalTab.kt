package dev.marquart.aos.desktop.terminal

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.AddCircle
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.SystemUpdate
import androidx.compose.material.icons.rounded.Terminal
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.awt.SwingPanel
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.marquart.aos.R
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.core.MacTermSession
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.terminal.MacTerminal
import dev.marquart.aos.terminal.TerminalFontSize
import dev.marquart.aos.ui.components.Section
import dev.marquart.aos.ui.components.SectionRow
import dev.marquart.aos.ui.platform.BackHandler
import dev.marquart.aos.ui.platform.stringResource
import dev.marquart.aos.ui.theme.AosTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * The Terminal tab on the desktop: the sessions on the Mac (as on Android and the iPhone) and the terminal itself,
 * JetBrains' JediTerm in a SwingPanel. Keyboard: everything goes to the Mac (Ctrl, Alt, function keys); copy and paste
 * with Ctrl+Shift+C / Ctrl+Shift+V (Cmd on macOS) or the right-click menu; the window's size is the terminal's.
 */
@Composable
fun DesktopTerminalTab(model: AppModel, modifier: Modifier = Modifier) {
    val terminals = remember(model) { DesktopTerminals.of(model) }
    terminals.dark = AosTheme.colors.isDark
    val macs by model.macs.collectAsState()
    val mac = macs.firstOrNull()
    val showing by terminals.showing.collectAsState()
    val request by model.terminalRequest.collectAsState()
    LaunchedEffect(request, mac) {
        if (request != null && mac != null) {
            terminals.openNew(mac)
            model.terminalRequestHandled()
        }
    }
    androidx.compose.material3.Surface(modifier.fillMaxSize(), color = AosTheme.colors.background) {
        when {
            mac == null -> NoMac()
            showing == mac.id && terminals.existing(mac.id) != null ->
                TerminalView(terminals, terminals.existing(mac.id)!!, mac) { terminals.showing.value = null }
            else -> SessionList(terminals, mac)
        }
    }
}

@Composable
private fun NoMac() {
    Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically)) {
        Icon(Icons.Rounded.Terminal, contentDescription = null, tint = AosTheme.colors.secondary, modifier = Modifier.size(56.dp))
        Text(stringResource(R.string.term_no_mac), style = MaterialTheme.typography.titleLarge)
        Text(stringResource(R.string.term_no_mac_text), color = AosTheme.colors.secondary)
    }
}

@Composable
private fun SessionList(terminals: DesktopTerminals, mac: PairedMac) {
    val model = terminals.model
    val scope = rememberCoroutineScope()
    val sessions by terminals.sessions.sessions.collectAsState()
    val loaded by terminals.sessions.loaded.collectAsState()
    val connection by model.connection.collectAsState()
    val state by model.connectionState.collectAsState()
    val connected = state is MacConnection.State.Connected
    var ending by remember { mutableStateOf<MacTermSession?>(null) }
    val terminal = terminals.existing(mac.id)
    val phase by (terminal?.phase ?: flowOf(MacTerminal.Phase.Idle)).collectAsState(MacTerminal.Phase.Idle)
    val holderId by (terminal?.holderId ?: flowOf(null)).collectAsState(null)
    val home = "/Users/${mac.user}"
    LaunchedEffect(connected, model.demo) {
        while (true) {
            if (model.demo != null) terminals.sessions.showDemo(connection?.phoneId) else terminals.sessions.load(model)
            delay(10_000)
        }
    }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(start = 24.dp, end = 12.dp, top = 16.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.term_title), style = MaterialTheme.typography.headlineMedium, modifier = Modifier.weight(1f))
            IconButton(onClick = { scope.launch { connection?.retryNow(); terminals.sessions.load(model) } }) {
                Icon(Icons.Rounded.Refresh, contentDescription = null)
            }
        }
        LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp).widthIn(max = 760.dp)) {
            item {
                Card(onClick = { terminals.openNew(mac) }, modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                    colors = CardDefaults.cardColors(containerColor = AosTheme.colors.card)) {
                    Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.AddCircle, contentDescription = null, tint = AosTheme.colors.indigo)
                        Spacer(Modifier.size(12.dp))
                        Text(stringResource(R.string.term_new_session), fontWeight = FontWeight.SemiBold, color = AosTheme.colors.indigo)
                    }
                }
                Footnote(stringResource(R.string.term_new_session_footer, mac.name))
                Text(stringResource(R.string.term_sessions_header), style = MaterialTheme.typography.titleSmall,
                    color = AosTheme.colors.secondary, modifier = Modifier.padding(start = 4.dp, top = 16.dp, bottom = 8.dp))
                connectionNote(model, connection)?.let { (text, icon) ->
                    Row(Modifier.padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(icon, contentDescription = null, tint = AosTheme.colors.secondary, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(8.dp))
                        Text(text, color = AosTheme.colors.secondary)
                    }
                }
                if (loaded && sessions.isEmpty()) Footnote(stringResource(R.string.term_no_sessions))
            }
            items(sessions, key = { it.id }) { session ->
                val open = phase == MacTerminal.Phase.Connecting || phase == MacTerminal.Phase.Connected || phase == MacTerminal.Phase.Reconnecting
                val holder = session.holder(if (terminal != null && open) holderId else null, connection?.phoneId,
                    holderId ?: terminals.settings.holderId(mac.id))
                Section {
                    SectionRow(onClick = { terminals.open(mac, session.id) }, divider = false) {
                        Icon(Icons.Rounded.Terminal, contentDescription = null, tint = AosTheme.colors.indigo)
                        Column(Modifier.weight(1f)) {
                            Text(session.title ?: place(session, home), fontWeight = FontWeight.Medium)
                            Text(detail(session, holder), style = MaterialTheme.typography.bodySmall, color = AosTheme.colors.secondary)
                        }
                        TextButton(onClick = { terminals.open(mac, session.id) }) { Text(stringResource(R.string.term_open_session)) }
                        TextButton(onClick = { ending = session }) { Text(stringResource(R.string.term_end), color = AosTheme.colors.red) }
                    }
                }
            }
            item { Footnote(stringResource(R.string.term_sessions_footer)) }
        }
    }
    ending?.let { session ->
        AlertDialog(onDismissRequest = { ending = null },
            title = { Text(stringResource(R.string.term_end_confirm_title)) },
            text = { Text(stringResource(R.string.term_end_confirm_text)) },
            confirmButton = {
                Button(onClick = {
                    ending = null
                    scope.launch { terminals.sessions.end(session, model, terminals.existing(mac.id)) }
                }) { Text(stringResource(R.string.term_end_session)) }
            },
            dismissButton = { TextButton(onClick = { ending = null }) { Text(stringResource(R.string.term_cancel)) } })
    }
}

@Composable
private fun Footnote(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = AosTheme.colors.secondary, modifier = Modifier.padding(horizontal = 4.dp, vertical = 6.dp))
}

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
private fun TerminalView(terminals: DesktopTerminals, terminal: MacTerminal, mac: PairedMac, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    val phase by terminal.phase.collectAsState()
    val endReason by terminal.endReason.collectAsState()
    val notice by terminal.notice.collectAsState()
    val pendingPaste by terminal.pendingPaste.collectAsState()
    val title by terminal.title.collectAsState()
    val fontSize by terminals.settings.fontSize.collectAsState()
    val screen = terminals.screenOf(terminal)
    var menu by remember { mutableStateOf(false) }
    BackHandler(onBack = onBack)
    LaunchedEffect(terminal) {
        if (phase == MacTerminal.Phase.Idle) {
            if (terminals.model.demo != null) terminal.showDemo(dev.marquart.aos.terminal.TerminalDemo.TEXT) else terminal.connect()
        }
        screen.widget.requestFocusInWindow()
    }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = stringResource(R.string.term_back)) }
            Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            if (phase == MacTerminal.Phase.Connecting || phase == MacTerminal.Phase.Reconnecting) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                Spacer(Modifier.size(8.dp))
            }
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Rounded.MoreVert, contentDescription = stringResource(R.string.term_more)) }
                DropdownMenu(menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.term_new_session)) }, onClick = { menu = false; terminals.openNew(mac) })
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text(stringResource(R.string.term_copy_screen)) }, onClick = { menu = false; terminal.copyScreen() })
                    DropdownMenuItem(text = { Text(stringResource(R.string.term_copy_last_output)) }, onClick = { menu = false; terminal.copyLastOutput() })
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text(stringResource(R.string.term_bigger_text)) }, onClick = { terminals.setFontSize(fontSize + 1) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.term_smaller_text)) }, onClick = { terminals.setFontSize(fontSize - 1) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.term_default_text_size)) }, onClick = { terminals.setFontSize(TerminalFontSize.STANDARD) })
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text(stringResource(R.string.term_end_session), color = AosTheme.colors.red) }, onClick = {
                        menu = false
                        scope.launch { terminal.endSession() }
                    })
                }
            }
        }
        banner(phase, endReason)?.let { (text, action) ->
            Row(Modifier.fillMaxWidth().background(AosTheme.colors.card).padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Text(text, modifier = Modifier.weight(1f), color = AosTheme.colors.secondary)
                if (action != null) TextButton(onClick = action.second) { Text(action.first) }
            }
        }
        Box(Modifier.weight(1f).fillMaxWidth().padding(4.dp)) {
            SwingPanel(factory = { screen.widget }, modifier = Modifier.fillMaxSize())
            notice?.let {
                Text(noticeText(it), color = androidx.compose.ui.graphics.Color.White, modifier = Modifier.align(Alignment.TopCenter).padding(12.dp)
                    .background(androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.7f), RoundedCornerShape(50)).padding(horizontal = 14.dp, vertical = 6.dp))
            }
        }
    }
    pendingPaste?.let { text ->
        AlertDialog(onDismissRequest = terminal::cancelPaste,
            title = { Text(stringResource(R.string.term_paste_lines_title, text.lines().size)) },
            text = { Text(stringResource(R.string.term_paste_lines_text)) },
            confirmButton = { Button(onClick = { terminal.confirmPaste(text) }) { Text(stringResource(R.string.term_paste)) } },
            dismissButton = { TextButton(onClick = terminal::cancelPaste) { Text(stringResource(R.string.term_cancel)) } })
    }
}

@Composable
private fun banner(phase: MacTerminal.Phase, reason: MacTerminal.EndReason): Pair<String, Pair<String, () -> Unit>?>? =
    when (phase) {
        MacTerminal.Phase.Reconnecting -> stringResource(R.string.term_reconnecting) to null
        MacTerminal.Phase.Ended -> stringResource(when (reason) {
            MacTerminal.EndReason.TAKEN -> R.string.term_taken
            MacTerminal.EndReason.EXITED -> R.string.term_shell_ended
            MacTerminal.EndReason.ENDED -> R.string.term_session_was_ended
            MacTerminal.EndReason.CLOSED -> R.string.term_session_ended
        }) to null
        is MacTerminal.Phase.Failed -> (phase.message ?: stringResource(R.string.term_doesnt_start)) to null
        else -> null
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

/** Settings > Terminal on the desktop: the text size. */
@Composable
fun TerminalSettingsSection() {
    val terminals = DesktopTerminals.of(dev.marquart.aos.ui.LocalAosUi.current.model)
    val size by terminals.settings.fontSize.collectAsState()
    Section(header = stringResource(R.string.term_text_size)) {
        SectionRow(divider = false) {
            Text("$size pt", modifier = Modifier.weight(1f))
            TextButton(onClick = { terminals.setFontSize(size - 1) }, enabled = size > TerminalFontSize.MIN) { Text("A−") }
            TextButton(onClick = { terminals.setFontSize(size + 1) }, enabled = size < TerminalFontSize.MAX) { Text("A+") }
        }
    }
}
