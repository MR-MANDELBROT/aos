package dev.marquart.aos.ui.overview

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.HelpOutline
import androidx.compose.material.icons.rounded.Apps
import androidx.compose.material.icons.rounded.Cable
import androidx.compose.material.icons.rounded.Cancel
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.HourglassTop
import androidx.compose.material.icons.rounded.PauseCircle
import androidx.compose.material.icons.rounded.Schedule
import androidx.compose.material.icons.rounded.SignalCellularAlt
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import dev.marquart.aos.ui.platform.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.marquart.aos.R
import dev.marquart.aos.ui.OverviewPage
import dev.marquart.aos.ui.layout.LocalWindowLayout
import dev.marquart.aos.ui.layout.TwoPane
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.core.MacStatus
import dev.marquart.aos.ui.LocalAosUi
import dev.marquart.aos.ui.Txt
import dev.marquart.aos.ui.components.EmptyState
import dev.marquart.aos.ui.components.LabeledRow
import dev.marquart.aos.ui.components.OverviewRow
import dev.marquart.aos.ui.components.Page
import dev.marquart.aos.ui.components.PageColumn
import dev.marquart.aos.ui.components.Section
import dev.marquart.aos.ui.components.SectionRow
import dev.marquart.aos.ui.components.TextRow
import dev.marquart.aos.ui.text
import dev.marquart.aos.ui.theme.AosTheme
import kotlinx.coroutines.delay

/** Apps that agents put on this phone through aOS on the Mac: the Mac's connection to it and the latest installs.
 *  Read only. (The Mac installs on an iPhone today; the page shows what it reports.) */
@Composable
fun AppsPage() {
    val ui = LocalAosUi.current
    val colors = AosTheme.colors
    val connection by ui.model.connection.collectAsState()
    val c = connection
    val status = c?.macStatus?.collectAsState()?.value
    val companion = c?.companionState?.collectAsState()?.value
    val apps = status?.apps
    val resumed = isResumed()
    // Every 5 s while an install waits or runs, else every 15 s.
    LaunchedEffect(c, companion == MacConnection.CompanionState.Ready, resumed) {
        if (c == null || !resumed) return@LaunchedEffect
        while (true) {
            c.refreshMacStatus()
            val a = c.macStatus.value?.apps
            delay(if ((a?.queued ?: 0) + (a?.installing ?: 0) > 0) 5_000 else 15_000)
        }
    }

    val twoPane = LocalWindowLayout.current.twoPane
    val phone: @Composable () -> Unit = {
        if (apps != null) Section {
            SectionRow(divider = true) {
                OverviewRow(connectionIcon(apps), AppsText.connectionTitle(apps).text(), detail = AppsText.connectionExplanation(apps)?.text(),
                    tint = when (apps.state) {
                        "connected" -> colors.green
                        "notPaired" -> colors.orange
                        else -> colors.secondary
                    })
            }
            apps.device?.takeIf { it.isNotEmpty() }?.let { LabeledRow(stringResource(R.string.apps_device), it) }
            if (apps.isConnected) apps.since?.let { LabeledRow(stringResource(R.string.apps_connected_since), AppsText.since(it).text()) }
            if (apps.isConnected) apps.network?.let { LabeledRow(stringResource(R.string.apps_network), AppsText.networkName(it).text()) }
            apps.previousSeconds?.let { LabeledRow(stringResource(R.string.apps_previous), AppsText.duration(it).text(), divider = false) }
        }
    }
    val installs: @Composable (Boolean) -> Unit = { header ->
        if (apps != null) Section(header = if (header) stringResource(R.string.apps_installs) else null, footer = stringResource(R.string.apps_footer)) {
            if (apps.jobs.isEmpty()) TextRow(stringResource(R.string.apps_nothing_yet), divider = false, color = colors.secondary)
            apps.jobs.forEachIndexed { index, job -> JobRow(job, divider = index < apps.jobs.lastIndex) }
        }
    }
    if (twoPane && apps != null) {
        // A wide window: the connection to the phone on one side, what was installed on the other.
        TwoPane(
            list = {
                Page(stringResource(R.string.apps), onBack = { ui.overview.pop() }) { padding ->
                    PageColumn(padding, scrollKey = "overview/${OverviewPage.Apps}") { phone() }
                }
            },
            detail = {
                Page(stringResource(R.string.apps_installs)) { padding ->
                    PageColumn(padding, scrollKey = "overview/${OverviewPage.Apps}/installs") { installs(false) }
                }
            },
        )
        return
    }
    Page(stringResource(R.string.apps), onBack = { ui.overview.pop() }) { padding ->
        PageColumn(padding, scrollKey = "overview/${OverviewPage.Apps}") {
            if (apps == null) {
                EmptyState(Icons.Rounded.Apps, stringResource(R.string.apps_off_title), stringResource(R.string.apps_off_text))
                return@PageColumn
            }
            phone()
            installs(true)
        }
    }
}

private fun connectionIcon(apps: MacStatus.Apps): ImageVector = when (apps.state) {
    "connected" -> if (apps.network == "cellular") Icons.Rounded.SignalCellularAlt else Icons.Rounded.Wifi
    "searching", "connecting", "starting" -> Icons.Rounded.HourglassTop
    "notPaired" -> Icons.Rounded.Cable
    "stopped" -> Icons.Rounded.PauseCircle
    else -> Icons.AutoMirrored.Rounded.HelpOutline
}

@Composable
private fun JobRow(job: MacStatus.Apps.Job, divider: Boolean) {
    val colors = AosTheme.colors
    val (icon, tint) = when (job.state) {
        "done" -> Icons.Rounded.CheckCircle to colors.green
        "failed" -> Icons.Rounded.Cancel to colors.red
        "installing" -> Icons.Rounded.Schedule to colors.indigo
        "queued" -> Icons.Rounded.Schedule to colors.secondary
        else -> Icons.AutoMirrored.Rounded.HelpOutline to colors.secondary
    }
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.width(28.dp).size(22.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(job.name, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold, maxLines = 2,
                    modifier = Modifier.weight(1f, fill = false))
                job.version?.takeIf { it.isNotEmpty() }?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = colors.secondary, maxLines = 1) }
                Row(Modifier.weight(1f)) {}
                (job.finished ?: job.created)?.let {
                    Text(Txt.Time(it, Txt.TimeStyle.RELATIVE).text(), style = MaterialTheme.typography.bodySmall, color = colors.secondary, maxLines = 1)
                }
            }
            Text(AppsText.stateLine(job).text(), style = MaterialTheme.typography.bodyMedium, color = colors.secondary, maxLines = 2)
            Text(AppsText.detail(job).text(), style = MaterialTheme.typography.bodySmall, color = colors.tertiary, maxLines = 2)
            if (job.state == "failed" && !job.message.isNullOrEmpty()) {
                Text(job.message!!, style = MaterialTheme.typography.bodySmall, color = colors.red)
            }
        }
    }
    if (divider) HorizontalDivider(Modifier.padding(start = 56.dp), color = colors.separator)
}

