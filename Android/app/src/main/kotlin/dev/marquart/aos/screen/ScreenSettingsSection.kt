// Settings > Screen (iOS/Sources/Screen/ScreenSettings.swift for Android): one setting for both screens, the phone's
// size and Open Screen Sharing's resolution, how fingers work, and where the screen comes from (its license).
// Written for aOS's Android app on 2026-11-19.

package dev.marquart.aos.screen

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.marquart.aos.R

/** The Screen part of the settings page: display, touch, and Open Screen Sharing's license. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ScreenSettingsSection() {
    val context = LocalContext.current
    val store = remember { ScreenHub.get(context).store }
    val matchesPhone by store.matchesPhone.collectAsState()
    val resolution by store.resolutionScale.collectAsState()
    val touchMode by store.touchMode.collectAsState()
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(stringResource(R.string.screen_display), style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.screen_matches_phone), Modifier.weight(1f))
            Switch(matchesPhone, { store.setMatchesPhone(it) })
        }
        Text(stringResource(R.string.screen_resolution))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (scale in DisplayMode.resolutionScales) {
                FilterChip(resolution == scale, { store.setResolutionScale(scale) },
                    { Text(DisplayMode.resolutionTitle(scale, stringResource(R.string.screen_native))) }, enabled = matchesPhone)
            }
        }
        Text(stringResource(R.string.screen_display_footer), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

        Text(stringResource(R.string.screen_touch), style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(top = 8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(touchMode == TouchMode.TRACKPAD, { store.setTouchMode(TouchMode.TRACKPAD) }, { Text(stringResource(R.string.screen_touch_trackpad)) })
            FilterChip(touchMode == TouchMode.DIRECT, { store.setTouchMode(TouchMode.DIRECT) }, { Text(stringResource(R.string.screen_touch_direct)) })
        }
        Text(
            stringResource(if (touchMode == TouchMode.TRACKPAD) R.string.screen_touch_trackpad_footer else R.string.screen_touch_direct_footer),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        ScreenAcknowledgements(Modifier.padding(top = 8.dp))
    }
}

/** Where the screen comes from: Open Screen Sharing, its license notice and the GPL (for the acknowledgements too). */
@Composable
fun ScreenAcknowledgements(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var shown by remember { mutableStateOf<Pair<String, String>?>(null) }
    val noticeTitle = stringResource(R.string.screen_license_notice)
    val gplTitle = stringResource(R.string.screen_gpl3)
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(stringResource(R.string.screen_oss), style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
        Text(stringResource(R.string.screen_oss_text), style = MaterialTheme.typography.bodyMedium)
        Link(stringResource(R.string.screen_oss_source)) {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(OSS_SOURCE)))
        }
        Link(noticeTitle) { shown = noticeTitle to asset(context, "open-screen-sharing/LICENSE") }
        Link(gplTitle) { shown = gplTitle to asset(context, "open-screen-sharing/COPYING") }
        Text(stringResource(R.string.screen_oss_not_associated), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    shown?.let { (title, text) ->
        AlertDialog(
            onDismissRequest = { shown = null },
            title = { Text(title) },
            text = {
                Text(text, fontFamily = FontFamily.Monospace, fontSize = 11.sp,
                    modifier = Modifier.heightIn(max = 480.dp).verticalScroll(rememberScrollState()))
            },
            confirmButton = { TextButton(onClick = { shown = null }) { Text(stringResource(R.string.screen_done)) } },
        )
    }
}

@Composable
private fun Link(text: String, onClick: () -> Unit) {
    Text(text, color = MaterialTheme.colorScheme.primary, modifier = Modifier.clickable(onClick = onClick).padding(vertical = 6.dp))
}

private const val OSS_SOURCE = "https://github.com/nekohasekai/open-screen-sharing"

/** A text from the app's assets (the license files). */
fun asset(context: android.content.Context, path: String): String =
    runCatching { context.assets.open(path).bufferedReader().use { it.readText() } }.getOrDefault("")
