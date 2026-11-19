package dev.marquart.aos.ui.overview

import dev.marquart.aos.ui.platform.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Message
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.HourglassTop
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.PowerSettingsNew
import androidx.compose.material.icons.rounded.Schedule
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import dev.marquart.aos.ui.platform.locale
import dev.marquart.aos.ui.platform.platformContext
import dev.marquart.aos.ui.platform.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import dev.marquart.aos.R
import dev.marquart.aos.core.MacAction
import dev.marquart.aos.core.MacStatus
import dev.marquart.aos.ui.LocalAosUi
import dev.marquart.aos.ui.Txt
import dev.marquart.aos.ui.components.ConfirmDialog
import dev.marquart.aos.ui.components.EmptyState
import dev.marquart.aos.ui.components.Page
import dev.marquart.aos.ui.components.PageColumn
import dev.marquart.aos.ui.components.Section
import dev.marquart.aos.ui.components.SectionRow
import dev.marquart.aos.ui.components.TextRow
import dev.marquart.aos.ui.text
import dev.marquart.aos.ui.theme.AosTheme
import java.text.DateFormatSymbols
import java.util.Calendar
import java.util.UUID

/** Short weekday names, Sunday first, and the first day of the week, in the app's language. */
@Composable
fun weekdayNames(): Pair<List<String>, Int> {
    val locale = platformContext().locale
    val symbols = DateFormatSymbols.getInstance(locale).shortWeekdays
    return (1..7).map { symbols[it].trimEnd('.') } to (Calendar.getInstance(locale).firstDayOfWeek - 1)
}

/** aOS's session's routines on the Mac: on or off, run now, add, change, delete; reminders waiting and what went in
 *  lately. Every change goes to the Mac as a signed action and comes back in its status. */
@Composable
fun RoutinesPage(onBack: () -> Unit) {
    val ui = LocalAosUi.current
    val colors = AosTheme.colors
    val connection by ui.model.connection.collectAsState()
    val c = connection
    val status = c?.macStatus?.collectAsState()?.value
    val routines = status?.routines
    val actions = rememberActionState()
    var editing by remember { mutableStateOf<MacStatus.Routines.Item?>(null) }
    var deleting by remember { mutableStateOf<MacStatus.Routines.Item?>(null) }
    val (names, firstDay) = weekdayNames()
    LaunchedEffect(c) { c?.refreshMacStatus() }
    LaunchedEffect(ui.demo?.sheet, routines != null) {
        if (ui.demo?.sheet == "routine-edit") routines?.items?.firstOrNull()?.let { editing = it }
    }

    fun save(r: MacStatus.Routines.Item) {
        c?.let { actions.run(MacAction.ROUTINE_SET, it, r.json) }
    }

    editing?.let { r ->
        val isNew = routines?.items?.none { it.id == r.id } ?: true
        RoutineEditor(r, isNew, onSave = { save(it); editing = null }, onCancel = { editing = null })
        return
    }

    Page(stringResource(R.string.routines), onBack = onBack, bottom = { BottomProblem(actions.problem) }, actions = {
        if (routines != null) {
            IconButton(onClick = {
                editing = MacStatus.Routines.Item(UUID.randomUUID().toString().uppercase(), "", "0 8 * * *", "", true)
            }) { Icon(Icons.Rounded.Add, contentDescription = stringResource(R.string.routine_add)) }
        }
    }) { padding ->
        PageColumn(padding) {
            if (routines == null) {
                EmptyState(Icons.Rounded.Schedule, stringResource(R.string.not_available), stringResource(R.string.not_available_explain))
                return@PageColumn
            }
            Section(footer = stringResource(R.string.routines_footer)) {
                if (routines.items.isEmpty()) TextRow(stringResource(R.string.routines_none), divider = false, color = colors.secondary)
                routines.items.forEachIndexed { index, r ->
                    RoutineRow(r, names, firstDay, busy = actions.running != null, divider = index < routines.items.lastIndex,
                        onToggle = { on -> save(r.copy(enabled = on)) },
                        onEdit = { editing = r }, onRun = { actions.run(MacAction.ROUTINE_RUN, c, r.id) },
                        onDelete = { deleting = r })
                }
            }
            if (routines.reminders.isNotEmpty() || routines.queued > 0) {
                Section(header = stringResource(R.string.routines_waiting)) {
                    if (routines.queued > 0) {
                        SectionRow(divider = routines.reminders.isNotEmpty()) {
                            Icon(Icons.Rounded.HourglassTop, contentDescription = null, tint = colors.secondary)
                            Text(Txt.plural(R.plurals.routines_queued, routines.queued).text(), color = colors.secondary,
                                modifier = Modifier.weight(1f))
                        }
                    }
                    routines.reminders.forEachIndexed { i, r ->
                        SectionRow(divider = i < routines.reminders.lastIndex) {
                            Icon(Icons.Rounded.Notifications, contentDescription = null, tint = colors.indigo)
                            Text(r.name, maxLines = 2, modifier = Modifier.weight(1f))
                            Text(Txt.Time(r.at, Txt.TimeStyle.DATE_TIME).text(), style = MaterialTheme.typography.bodySmall, color = colors.secondary)
                        }
                    }
                }
            }
            if (routines.recent.isNotEmpty()) {
                Section(header = stringResource(R.string.routines_recent)) {
                    routines.recent.forEachIndexed { i, d ->
                        SectionRow(divider = i < routines.recent.lastIndex) {
                            Icon(when (d.kind) {
                                "reminder" -> Icons.Rounded.Notifications
                                "note" -> Icons.AutoMirrored.Rounded.Message
                                "start" -> Icons.Rounded.PowerSettingsNew
                                else -> Icons.Rounded.Schedule
                            }, contentDescription = null, tint = colors.indigo)
                            Text(sentTitle(d).text(), modifier = Modifier.weight(1f))
                            Text(Txt.Time(d.at, Txt.TimeStyle.RELATIVE).text(), style = MaterialTheme.typography.bodySmall, color = colors.secondary)
                        }
                    }
                }
            }
        }
    }
    deleting?.let { r ->
        ConfirmDialog(stringResource(R.string.routine_delete_question), r.name, stringResource(R.string.delete),
            onConfirm = { c?.let { actions.run(MacAction.ROUTINE_DELETE, it, r.id) } }, onDismiss = { deleting = null })
    }
}

fun sentTitle(d: MacStatus.Routines.Sent): Txt = when (d.kind) {
    "reminder" -> Txt.res(R.string.routine_reminder)
    "note" -> if (d.name.isEmpty()) Txt.res(R.string.routine_note) else Txt.res(R.string.routine_note_from, d.name)
    "start" -> Txt.res(R.string.routine_start_message)
    else -> Txt.raw(d.name)
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun RoutineRow(r: MacStatus.Routines.Item, names: List<String>, firstDay: Int, busy: Boolean, divider: Boolean,
                       onToggle: (Boolean) -> Unit, onEdit: () -> Unit, onRun: () -> Unit, onDelete: () -> Unit) {
    val colors = AosTheme.colors
    var menu by remember { mutableStateOf(false) }
    Box {
        SectionRow(Modifier.combinedClickable(onClick = onEdit, onLongClick = { menu = true }), divider = divider) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(r.name, maxLines = 1)
                Text(RoutineSchedule.text(r.schedule, names, firstDay).text(), style = MaterialTheme.typography.bodySmall, color = colors.secondary)
                if (r.enabled && r.next != null) {
                    Text(stringResource(R.string.routine_next, Txt.Time(r.next!!, Txt.TimeStyle.RELATIVE_INLINE).text()),
                        style = MaterialTheme.typography.bodySmall, color = colors.tertiary)
                }
            }
            Switch(checked = r.enabled, onCheckedChange = onToggle, enabled = !busy)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text(stringResource(R.string.routine_run_now)) }, leadingIcon = { Icon(Icons.Rounded.PlayArrow, null) },
                onClick = { menu = false; onRun() })
            DropdownMenuItem(text = { Text(stringResource(R.string.edit)) }, leadingIcon = { Icon(Icons.Rounded.Edit, null) },
                onClick = { menu = false; onEdit() })
            DropdownMenuItem(text = { Text(stringResource(R.string.delete), color = colors.red) }, leadingIcon = { Icon(Icons.Rounded.Delete, null) },
                onClick = { menu = false; onDelete() })
        }
    }
}

private enum class Mode { TIMES, INTERVAL, CRON }

/** Adding or changing a routine: a name, the message, and when: at times on weekdays, every few hours, or cron. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RoutineEditor(routine: MacStatus.Routines.Item, isNew: Boolean, onSave: (MacStatus.Routines.Item) -> Unit, onCancel: () -> Unit) {
    val colors = AosTheme.colors
    val (names, firstDay) = weekdayNames()
    BackHandler(onBack = onCancel)
    val simple = remember { RoutineSchedule.simple(routine.schedule) }
    val interval = remember { RoutineSchedule.interval(routine.schedule) }
    var name by remember { mutableStateOf(routine.name) }
    var prompt by remember { mutableStateOf(routine.prompt) }
    var enabled by remember { mutableStateOf(routine.enabled) }
    var mode by remember {
        mutableStateOf(when {
            interval != null && (interval.hours > 1 || simple == null) -> Mode.INTERVAL
            simple != null -> Mode.TIMES
            else -> Mode.CRON
        })
    }
    val times = remember { mutableStateListOf<RoutineSchedule.Time>().apply { addAll(simple?.times ?: listOf(RoutineSchedule.Time(8, 0))) } }
    var weekdays by remember { mutableStateOf(simple?.weekdays ?: interval?.weekdays ?: RoutineSchedule.ALL_DAYS) }
    var every by remember { mutableStateOf(interval?.hours ?: 2) }
    var from by remember { mutableStateOf(interval?.from ?: 8) }
    var to by remember { mutableStateOf(interval?.to ?: 20) }
    var minute by remember { mutableStateOf(interval?.minute ?: 0) }
    var cronText by remember { mutableStateOf(routine.schedule) }
    var pickingTime by remember { mutableStateOf<Int?>(null) }

    val schedule = when (mode) {
        Mode.CRON -> cronText.split(';').map { it.trim().split(Regex("\\s+")).filter(String::isNotEmpty).joinToString(" ") }
            .filter { it.isNotEmpty() }.joinToString("; ")
        Mode.INTERVAL -> RoutineSchedule.every(every, minOf(from, to), maxOf(from, to), minute, weekdays)
        Mode.TIMES -> RoutineSchedule.cron(times.toList(), weekdays)
    }
    val valid = name.isNotBlank() && prompt.isNotBlank() && RoutineSchedule.looksValid(schedule) &&
        (mode == Mode.CRON || weekdays.isNotEmpty()) && (mode != Mode.TIMES || times.isNotEmpty())

    Page(if (isNew) stringResource(R.string.routine_new) else routine.name, onBack = onCancel, actions = {
        TextButton(onClick = {
            onSave(routine.copy(name = name.trim(), prompt = prompt.trim(), schedule = schedule, enabled = enabled))
        }, enabled = valid) { Text(stringResource(if (isNew) R.string.add else R.string.save)) }
    }) { padding ->
        PageColumn(padding) {
            OutlinedTextField(name, { name = it }, label = { Text(stringResource(R.string.name)) }, singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
            OutlinedTextField(prompt, { prompt = it }, label = { Text(stringResource(R.string.routine_message)) },
                placeholder = { Text(stringResource(R.string.routine_message_hint)) }, minLines = 4, maxLines = 12,
                modifier = Modifier.fillMaxWidth())
            Text(stringResource(R.string.routine_when), style = MaterialTheme.typography.labelLarge, color = colors.secondary,
                modifier = Modifier.padding(start = 16.dp, top = 8.dp))
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                val modes = listOf(Mode.TIMES to R.string.routine_at_times, Mode.INTERVAL to R.string.routine_every_few_hours, Mode.CRON to R.string.routine_cron)
                modes.forEachIndexed { i, (m, label) ->
                    SegmentedButton(selected = mode == m, onClick = { mode = m }, shape = SegmentedButtonDefaults.itemShape(i, modes.size),
                        icon = {}) {
                        Text(stringResource(label), maxLines = 2, style = MaterialTheme.typography.labelMedium,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    }
                }
            }
            Section(footer = if (mode == Mode.CRON) stringResource(R.string.routine_cron_footer) else RoutineSchedule.text(schedule, names, firstDay).text()) {
                when (mode) {
                    Mode.TIMES -> {
                        times.forEachIndexed { i, t ->
                            SectionRow(onClick = { pickingTime = i }) {
                                Text(stringResource(R.string.routine_time), modifier = Modifier.weight(1f))
                                Text(RoutineSchedule.clock(t.hour, t.minute), color = colors.indigo)
                                if (times.size > 1) IconButton(onClick = { times.removeAt(i) }) {
                                    Icon(Icons.Rounded.Close, contentDescription = stringResource(R.string.delete), tint = colors.secondary)
                                }
                            }
                        }
                        SectionRow(onClick = {
                            val last = times.lastOrNull() ?: RoutineSchedule.Time(6, 0)
                            times.add(RoutineSchedule.Time((last.hour + 2) % 24, last.minute))
                        }) {
                            Icon(Icons.Rounded.Add, contentDescription = null, tint = colors.indigo)
                            Text(stringResource(R.string.routine_add_time), color = colors.indigo)
                        }
                        SectionRow(divider = false) { WeekdayToggles(weekdays, names, firstDay) { weekdays = it } }
                    }
                    Mode.INTERVAL -> {
                        SectionRow {
                            Text(stringResource(R.string.routine_every), modifier = Modifier.weight(1f))
                            Picker(if (every == 1) stringResource(R.string.routine_hour) else stringResource(R.string.routine_hours, every),
                                listOf(1, 2, 3, 4, 6, 8, 12).map { h -> h to if (h == 1) Txt.res(R.string.routine_hour) else Txt.res(R.string.routine_hours, h) }
                                    .map { (h, t) -> h to t.text() }) { every = it }
                        }
                        SectionRow {
                            Text(stringResource(R.string.routine_from), modifier = Modifier.weight(1f))
                            Picker(RoutineSchedule.clock(from, 0), (0..23).map { it to RoutineSchedule.clock(it, 0) }) { from = it }
                        }
                        SectionRow {
                            Text(stringResource(R.string.routine_until), modifier = Modifier.weight(1f))
                            Picker(RoutineSchedule.clock(to, 0), (0..23).map { it to RoutineSchedule.clock(it, 0) }) { to = it }
                        }
                        SectionRow {
                            Text(stringResource(R.string.routine_at_minute, minute), modifier = Modifier.weight(1f))
                            Picker(minute.toString(), (0..55 step 5).map { it to it.toString() }) { minute = it }
                        }
                        SectionRow(divider = false) { WeekdayToggles(weekdays, names, firstDay) { weekdays = it } }
                    }
                    Mode.CRON -> SectionRow(divider = false) {
                        OutlinedTextField(cronText, { cronText = it }, placeholder = { Text(stringResource(R.string.routine_cron_fields)) },
                            textStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace), singleLine = true,
                            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
                            modifier = Modifier.fillMaxWidth())
                    }
                }
            }
            Section {
                SectionRow(divider = false) {
                    Text(stringResource(R.string.on), modifier = Modifier.weight(1f))
                    Switch(checked = enabled, onCheckedChange = { enabled = it })
                }
            }
        }
    }
    pickingTime?.let { index ->
        val t = times.getOrNull(index) ?: return@let
        val state = rememberTimePickerState(t.hour, t.minute, is24Hour = true)
        AlertDialog(
            onDismissRequest = { pickingTime = null },
            confirmButton = { TextButton(onClick = { times[index] = RoutineSchedule.Time(state.hour, state.minute); pickingTime = null }) {
                Text(stringResource(R.string.ok)) } },
            dismissButton = { TextButton(onClick = { pickingTime = null }) { Text(stringResource(R.string.cancel)) } },
            text = { TimePicker(state) },
        )
    }
}

/** The days of the week as round toggles, in the order of the locale's week (0 is Sunday, as in cron). */
@Composable
private fun WeekdayToggles(selection: Set<Int>, names: List<String>, firstDay: Int, onChange: (Set<Int>) -> Unit) {
    val colors = AosTheme.colors
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        for (i in 0 until 7) {
            val day = (firstDay + i) % 7
            val on = day in selection
            Box(
                Modifier.size(38.dp).background(if (on) colors.indigo else colors.gray.copy(alpha = 0.15f), CircleShape)
                    .clickable { onChange(if (on) selection - day else selection + day) },
                contentAlignment = Alignment.Center,
            ) {
                Text(names[day].take(2), style = MaterialTheme.typography.labelMedium, color = if (on) Color.White else MaterialTheme.colorScheme.onSurface)
            }
        }
    }
}
