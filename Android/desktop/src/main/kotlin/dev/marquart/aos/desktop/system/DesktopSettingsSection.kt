package dev.marquart.aos.desktop.system

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.Fingerprint
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.marquart.aos.R
import dev.marquart.aos.desktop.DesktopGraph
import dev.marquart.aos.desktop.Os
import dev.marquart.aos.desktop.store.Prefs
import dev.marquart.aos.desktop.store.Sealer
import dev.marquart.aos.ui.components.Section
import dev.marquart.aos.ui.components.SectionRow
import dev.marquart.aos.ui.platform.stringResource
import dev.marquart.aos.ui.theme.AosTheme

/**
 * Settings > This computer (the desktop only, under Notifications): how approvals are confirmed (Windows Hello,
 * polkit, the account's password, or not at all), start at login, closing the window to the tray, and how the
 * secrets are kept.
 */
@Composable
fun DesktopSettingsSection() {
    val graph = DesktopGraph.current
    val settings = graph?.desktopSettings ?: remember { DesktopSettings(Prefs(java.io.File(Os.configDir, "cache/demo-desktop.json"))) }
    val presence by settings.presence.collectAsState()
    val startAtLogin by settings.startAtLogin.collectAsState()
    val keepRunning by settings.keepRunning.collectAsState()
    Section(header = stringResource(R.string.desktop_confirm_header), footer = stringResource(when {
        Os.isWindows -> R.string.desktop_confirm_footer_windows
        Os.isLinux -> R.string.desktop_confirm_footer_linux
        else -> R.string.desktop_confirm_footer_other
    })) {
        val choices = PresenceMethod.choices
        choices.forEachIndexed { i, method ->
            SectionRow(onClick = { settings.setPresence(method) }, divider = i < choices.lastIndex) {
                Icon(Icons.Rounded.Fingerprint, contentDescription = null, tint = AosTheme.colors.indigo, modifier = Modifier.size(22.dp))
                Text(stringResource(when (method) {
                    PresenceMethod.SYSTEM -> if (Os.isWindows) R.string.desktop_confirm_hello else R.string.desktop_confirm_polkit
                    PresenceMethod.PASSWORD -> R.string.desktop_confirm_password
                    PresenceMethod.OFF -> R.string.desktop_confirm_off
                }), modifier = Modifier.weight(1f))
                RadioButton(selected = presence == method, onClick = { settings.setPresence(method) })
            }
        }
    }
    Section(header = stringResource(R.string.desktop_this_computer), footer = stringResource(R.string.desktop_background_footer)) {
        if (Autostart.isSupported) {
            SectionRow {
                Icon(Icons.Rounded.Computer, contentDescription = null, tint = AosTheme.colors.indigo, modifier = Modifier.size(22.dp))
                Text(stringResource(R.string.desktop_start_at_login), modifier = Modifier.weight(1f))
                Switch(startAtLogin, { on ->
                    settings.setStartAtLogin(on)
                    runCatching { Autostart.set(on) }
                })
            }
        }
        SectionRow(divider = false) {
            Text(stringResource(R.string.desktop_keep_running), modifier = Modifier.weight(1f))
            Switch(keepRunning, { settings.setKeepRunning(it) })
        }
    }
    val sealer = graph?.sealer?.kind
    if (sealer != null) {
        Section(footer = stringResource(when (sealer) {
            Sealer.Kind.DPAPI -> R.string.desktop_secrets_dpapi
            Sealer.Kind.SECRET_SERVICE -> R.string.desktop_secrets_secret_service
            Sealer.Kind.NONE -> R.string.desktop_secrets_none
        })) {
            SectionRow(divider = false) {
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.desktop_secrets), style = MaterialTheme.typography.bodyLarge)
                    Text(Os.configDir.path, style = MaterialTheme.typography.bodySmall, color = AosTheme.colors.secondary)
                }
            }
        }
    }
}
