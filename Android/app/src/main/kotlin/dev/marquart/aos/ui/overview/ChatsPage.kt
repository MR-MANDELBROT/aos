package dev.marquart.aos.ui.overview

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AddComment
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.DesktopWindows
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.PushPin
import androidx.compose.material.icons.rounded.QuestionAnswer
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material.icons.rounded.Terminal
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.marquart.aos.R
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.core.ChatList
import dev.marquart.aos.core.ChatOffer
import dev.marquart.aos.core.MacAction
import dev.marquart.aos.ui.LocalAosUi
import dev.marquart.aos.ui.OverviewPage
import dev.marquart.aos.ui.Txt
import dev.marquart.aos.ui.components.ActionRow
import dev.marquart.aos.ui.components.Chevron
import dev.marquart.aos.ui.components.ConfirmDialog
import dev.marquart.aos.ui.components.EmptyState
import dev.marquart.aos.ui.components.HeroSymbol
import dev.marquart.aos.ui.components.LabeledRow
import dev.marquart.aos.ui.components.OverviewRow
import dev.marquart.aos.ui.components.Page
import dev.marquart.aos.ui.components.PageColumn
import dev.marquart.aos.ui.components.ProblemLine
import dev.marquart.aos.ui.components.Section
import dev.marquart.aos.ui.components.SectionRow
import dev.marquart.aos.ui.components.SmallSpinner
import dev.marquart.aos.ui.components.StatusDot
import dev.marquart.aos.ui.components.TextRow
import dev.marquart.aos.ui.text
import dev.marquart.aos.ui.theme.AosTheme
import kotlinx.coroutines.delay

/** What can be done with a chat, as the menus and buttons say it. */
sealed interface ChatCommand {
    data class Start(val action: MacAction) : ChatCommand
    data object Restart : ChatCommand
    data class Stop(val action: MacAction) : ChatCommand
    data object Delete : ChatCommand
}

/** An action that asks first: whatever ends or removes something (Stop, Restart, Delete). Start doesn't ask. */
data class ChatQuestion(val command: ChatCommand, val chat: ChatList.Chat) {
    val action: MacAction
        get() = when (command) {
            is ChatCommand.Start -> command.action
            ChatCommand.Restart -> MacAction.CHATS_RESTART
            is ChatCommand.Stop -> command.action
            ChatCommand.Delete -> MacAction.CHATS_DELETE
        }

    companion object {
        fun of(command: ChatCommand, chat: ChatList.Chat): ChatQuestion? = if (command is ChatCommand.Start) null else ChatQuestion(command, chat)
    }
}

@Composable
fun chatTint(chat: ChatList.Chat): Color {
    val c = AosTheme.colors
    return when (ChatsText.tint(chat)) {
        ChatsText.Tint.GREEN -> c.green
        ChatsText.Tint.INDIGO -> c.indigo
        ChatsText.Tint.YELLOW -> c.yellow
        ChatsText.Tint.ORANGE -> c.orange
        ChatsText.Tint.GRAY -> c.gray
    }
}

/** Polls the chats every 15 s while a chats page is on screen and the app is active. */
@Composable
private fun PollChats(connection: MacConnection?) {
    val resumed = isResumed()
    val companion = connection?.companionState?.collectAsState()?.value
    LaunchedEffect(connection, companion == MacConnection.CompanionState.Ready, resumed) {
        if (connection == null || !resumed) return@LaunchedEffect
        while (true) {
            connection.refreshChats()
            delay(15_000)
        }
    }
}

/** The Claude Code chats aOS keeps reachable for the Claude app, in the Mac's order; a tap opens a chat's page, a long
 *  press its actions. */
@Composable
fun ChatsPage() {
    val ui = LocalAosUi.current
    val connection by ui.model.connection.collectAsState()
    val c = connection
    val list = c?.chats?.collectAsState()?.value
    val status = c?.macStatus?.collectAsState()?.value
    val hello = c?.hello?.collectAsState()?.value
    val companion = c?.companionState?.collectAsState()?.value
    val features = hello?.features ?: emptySet()
    val actions = ui.chatActions
    var asking by remember { mutableStateOf<ChatQuestion?>(null) }
    PollChats(c)

    fun perform(command: ChatCommand, chat: ChatList.Chat) {
        val conn = c ?: return
        val question = ChatQuestion.of(command, chat)
        if (question != null) asking = question
        else if (command is ChatCommand.Start) actions.run(command.action, conn, chat.id)
    }

    Page(stringResource(R.string.chats), onBack = { ui.overview.pop() }, bottom = { BottomProblem(actions.problem) }) { padding ->
        PageColumn(padding) {
            status?.newChats?.let { newChats ->
                Section {
                    SectionRow(divider = false) {
                        OverviewRow(Icons.Rounded.AddComment, stringResource(R.string.new_chats_title), detail = AosText.newChats(newChats).text(),
                            detailTint = if (newChats.enabled && newChats.state == "needsLogin") AosTheme.colors.orange else AosTheme.colors.secondary)
                    }
                    if (newChats.enabled && newChats.state == "needsLogin") {
                        Box(Modifier.padding(bottom = 12.dp)) { SignInHelp { ui.model.openNewTerminal() } }
                    }
                }
            }
            when {
                list != null -> {
                    val footer = if (list.chats.isEmpty()) null
                        else stringResource(if (MacAction.CHATS_DELETE.raw in features) R.string.chats_footer else R.string.chats_footer_no_delete)
                    Section(header = ChatsText.summary(list).text(), footer = footer) {
                        if (!list.enabled) TextRow(stringResource(R.string.chats_switch_on), divider = list.chats.isNotEmpty(), color = AosTheme.colors.secondary)
                        else if (list.chats.isEmpty()) TextRow(stringResource(R.string.chats_none), divider = false, color = AosTheme.colors.secondary)
                        list.chats.forEachIndexed { index, chat ->
                            ChatRow(chat, list, ChatOffer.now(chat, list, features), busy = actions.isRunning(chat.id),
                                divider = index < list.chats.lastIndex,
                                onOpen = { ui.overview.push(OverviewPage.Chat(chat.id)) }, onCommand = { perform(it, chat) })
                        }
                    }
                }
                companion == MacConnection.CompanionState.Ready && features.contains(MacAction.CHATS_LIST.raw) ->
                    Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                else -> EmptyState(Icons.Rounded.QuestionAnswer, stringResource(R.string.not_available), stringResource(R.string.not_available_explain))
            }
        }
    }
    asking?.let { q -> ChatQuestionDialog(q, onDismiss = { asking = null }) { c?.let { actions.run(q.action, it, q.chat.id) } } }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ChatRow(chat: ChatList.Chat, list: ChatList, offer: ChatOffer, busy: Boolean, divider: Boolean, onOpen: () -> Unit,
                    onCommand: (ChatCommand) -> Unit) {
    val colors = AosTheme.colors
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.fillMaxWidth().combinedClickable(onClick = onOpen, onLongClick = { if (!offer.isEmpty) menu = true })
                .padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(if (chat.origin == "terminal") Icons.Rounded.Terminal else Icons.Rounded.DesktopWindows, contentDescription = null,
                tint = colors.indigo, modifier = Modifier.width(28.dp).size(22.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(chat.title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold, maxLines = 2,
                        overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    if (chat.pinned) Icon(Icons.Rounded.PushPin, contentDescription = stringResource(R.string.pinned), tint = colors.indigo,
                        modifier = Modifier.size(14.dp))
                    if (busy) SmallSpinner()
                    else chat.activity?.let {
                        Text(Txt.Time(it, Txt.TimeStyle.RELATIVE).text(), style = MaterialTheme.typography.bodySmall, color = colors.secondary, maxLines = 1)
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    StatusDot(chatTint(chat))
                    Text(ChatsText.state(chat, list).text(), style = MaterialTheme.typography.bodyMedium, color = colors.secondary, maxLines = 2)
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    if (chat.folder.isNotEmpty()) {
                        Icon(Icons.Rounded.Folder, contentDescription = null, tint = colors.tertiary, modifier = Modifier.size(13.dp))
                        Text(chat.folder, style = MaterialTheme.typography.bodySmall, color = colors.tertiary, maxLines = 1,
                            overflow = TextOverflow.MiddleEllipsis, modifier = Modifier.weight(1f, fill = false))
                        Text("·", style = MaterialTheme.typography.bodySmall, color = colors.tertiary)
                    }
                    Text(ChatsText.originShort(chat).text(), style = MaterialTheme.typography.bodySmall, color = colors.tertiary, maxLines = 1)
                }
            }
            Chevron()
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            chatCommands(offer).forEach { (command, label) ->
                DropdownMenuItem(text = { Text(label.text(), color = if (command is ChatCommand.Stop || command == ChatCommand.Delete) colors.red else Color.Unspecified) },
                    leadingIcon = { Icon(commandIcon(command), contentDescription = null) },
                    onClick = { menu = false; onCommand(command) })
            }
        }
    }
    if (divider) HorizontalDivider(Modifier.padding(start = 56.dp), color = colors.separator)
}

/** A chat's actions in one order everywhere. */
fun chatCommands(offer: ChatOffer): List<Pair<ChatCommand, Txt>> = buildList {
    offer.start?.let { add(ChatCommand.Start(it) to Txt.res(R.string.start)) }
    if (offer.restart) add(ChatCommand.Restart to Txt.res(R.string.restart))
    offer.stop?.let { add(ChatCommand.Stop(it) to Txt.res(R.string.stop)) }
    if (offer.delete) add(ChatCommand.Delete to Txt.res(R.string.delete))
}

private fun commandIcon(command: ChatCommand) = when (command) {
    is ChatCommand.Start -> Icons.Rounded.PlayArrow
    ChatCommand.Restart -> Icons.Rounded.Refresh
    is ChatCommand.Stop -> Icons.Rounded.Stop
    ChatCommand.Delete -> Icons.Rounded.Delete
}

@Composable
private fun ChatQuestionDialog(q: ChatQuestion, onDismiss: () -> Unit, run: () -> Unit) {
    val (title, message, confirm) = when (q.command) {
        is ChatCommand.Stop -> Triple(R.string.chat_stop_question, R.string.chat_stop_explain, R.string.stop)
        ChatCommand.Restart -> Triple(R.string.chat_restart_question, R.string.chat_restart_explain, R.string.restart)
        else -> Triple(R.string.chat_delete_question, R.string.chat_delete_explain, R.string.delete)
    }
    ConfirmDialog(stringResource(title, q.chat.title), stringResource(message), stringResource(confirm),
        destructive = q.command != ChatCommand.Restart, onConfirm = run, onDismiss = onDismiss)
}

@Composable
fun BottomProblem(text: String?) {
    if (text == null) return
    Box(Modifier.fillMaxWidth().padding(16.dp)) {
        dev.marquart.aos.ui.components.AosCard { ProblemLine(text) }
    }
}

/** A chat's page: what aOS does with it and why, its actions, where it is. */
@Composable
fun ChatPage(id: String) {
    val ui = LocalAosUi.current
    val connection by ui.model.connection.collectAsState()
    val c = connection
    val list = c?.chats?.collectAsState()?.value
    val hello = c?.hello?.collectAsState()?.value
    val chat = list?.chats?.firstOrNull { it.id == id }
    val actions = ui.chatActions
    var asking by remember { mutableStateOf<ChatQuestion?>(null) }
    val colors = AosTheme.colors
    PollChats(c)

    Page(stringResource(R.string.chat), onBack = { ui.overview.pop() }, bottom = { BottomProblem(actions.problem) }) { padding ->
        PageColumn(padding) {
            if (list == null || chat == null) {
                EmptyState(Icons.Rounded.QuestionAnswer, stringResource(R.string.chat_gone))
                return@PageColumn
            }
            val offer = ChatOffer.now(chat, list, hello?.features ?: emptySet())
            Section {
                SectionRow(divider = false) {
                    HeroSymbol(if (chat.origin == "terminal") Icons.Rounded.Terminal else Icons.Rounded.DesktopWindows,
                        tint = chatTint(chat), size = 44.dp)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(chat.title, style = MaterialTheme.typography.titleMedium)
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            StatusDot(chatTint(chat))
                            Text(ChatsText.state(chat, list).text(), style = MaterialTheme.typography.bodyMedium, color = colors.secondary)
                        }
                    }
                    if (actions.isRunning(chat.id)) SmallSpinner()
                }
                ChatsText.explanation(chat, list)?.let {
                    Text(it.text(), style = MaterialTheme.typography.bodySmall, color = colors.secondary,
                        modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp))
                }
                if (chat.note == "signIn") {
                    ActionRow(Icons.Rounded.Terminal, stringResource(R.string.open_terminal), divider = false) { ui.model.openNewTerminal() }
                }
            }
            if (!offer.isEmpty) {
                Section(footer = stringResource(if (offer.delete) R.string.chats_footer else R.string.chats_footer_no_delete)) {
                    val commands = chatCommands(offer)
                    commands.forEachIndexed { index, (command, label) ->
                        ActionRow(commandIcon(command), label.text(), divider = index < commands.lastIndex,
                            destructive = command is ChatCommand.Stop || command == ChatCommand.Delete, enabled = actions.running == null) {
                            val q = ChatQuestion.of(command, chat)
                            if (q != null) asking = q else if (command is ChatCommand.Start) actions.run(command.action, c, chat.id)
                        }
                    }
                }
            }
            Section {
                if (chat.folder.isNotEmpty()) LabeledRow(stringResource(R.string.chat_folder), chat.folder)
                LabeledRow(stringResource(R.string.chat_started_in), ChatsText.origin(chat).text(), divider = chat.activity != null || chat.pinned)
                chat.activity?.let { LabeledRow(stringResource(R.string.chat_last_used), Txt.Time(it, Txt.TimeStyle.DATE_TIME).text(), divider = chat.pinned) }
                if (chat.pinned) LabeledRow(stringResource(R.string.pinned), stringResource(R.string.chat_always_kept), divider = false)
            }
            Spacer(Modifier.size(1.dp))
        }
    }
    asking?.let { q ->
        ChatQuestionDialog(q, onDismiss = { asking = null }) {
            c?.let { conn ->
                actions.run(q.action, conn, q.chat.id) { if (q.action == MacAction.CHATS_DELETE) ui.overview.pop() }
            }
        }
    }
}
