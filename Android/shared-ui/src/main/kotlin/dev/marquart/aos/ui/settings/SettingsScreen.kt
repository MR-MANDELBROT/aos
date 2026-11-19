package dev.marquart.aos.ui.settings

import dev.marquart.aos.ui.platform.text
import dev.marquart.aos.ui.platform.Platform
import dev.marquart.aos.ui.platform.PresenceOutcome
import dev.marquart.aos.ui.platform.platformContext
import dev.marquart.aos.ui.platform.rawText
import dev.marquart.aos.ui.platform.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.CompareArrows
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.DesktopWindows
import androidx.compose.material.icons.rounded.Fingerprint
import androidx.compose.material.icons.rounded.Hub
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material.icons.rounded.LinkOff
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.QrCodeScanner
import androidx.compose.material.icons.rounded.Schedule
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.Terminal
import androidx.compose.material.icons.rounded.VolunteerActivism
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
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
import dev.marquart.aos.ui.platform.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import dev.marquart.aos.R
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.keys.DeviceKey
import dev.marquart.aos.keys.KeyStorage
import dev.marquart.aos.ui.LicenseKind
import dev.marquart.aos.ui.LocalAosUi
import dev.marquart.aos.ui.SettingsPage
import dev.marquart.aos.ui.Txt
import dev.marquart.aos.ui.components.ActionRow
import dev.marquart.aos.ui.components.AosCard
import dev.marquart.aos.ui.components.AppIconImage
import dev.marquart.aos.ui.components.ConfirmDialog
import dev.marquart.aos.ui.components.KeyText
import dev.marquart.aos.ui.components.LabeledRow
import dev.marquart.aos.ui.components.NavRow
import dev.marquart.aos.ui.components.Page
import dev.marquart.aos.ui.components.PageColumn
import dev.marquart.aos.ui.components.Section
import dev.marquart.aos.ui.components.SectionRow
import dev.marquart.aos.ui.components.TextRow
import dev.marquart.aos.ui.lock.AppLock
import dev.marquart.aos.ui.overview.Picker
import dev.marquart.aos.ui.overview.RoutinesPage
import dev.marquart.aos.ui.text
import dev.marquart.aos.ui.theme.AosTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Where the terminal and the screen put their settings pages (their agents own them): set at start, null leaves the
 * row out. Each gets a way back.
 */
object SettingsSlots {
    var terminal: (@Composable (onBack: () -> Unit) -> Unit)? = null
    var screen: (@Composable (onBack: () -> Unit) -> Unit)? = null

    /** Settings of this device only, under Notifications (the desktop: start at login, how approvals are confirmed). */
    var device: (@Composable () -> Unit)? = null
}

/** The Settings tab and the pages it pushes. */
@Composable
fun SettingsTab() {
    val ui = LocalAosUi.current
    val page = ui.settingsPages.top
    val back = { ui.settingsPages.pop() }
    BackHandler(enabled = page != null) { back() }
    AnimatedContent(targetState = page, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "settings") { shown ->
        when (shown) {
            null -> SettingsScreen()
            is SettingsPage.Mac -> MacDetailPage(shown.id, back)
            SettingsPage.Connection -> ConnectionPage(back)
            SettingsPage.DeviceKey -> DeviceKeyPage(back)
            SettingsPage.About -> AboutPage(back)
            SettingsPage.Acknowledgements -> AcknowledgementsPage(back)
            is SettingsPage.License -> LicensePage(shown.kind, back)
            SettingsPage.Routines -> RoutinesPage(onBack = back)
            SettingsPage.Terminal -> SettingsSlots.terminal?.invoke(back) ?: back()
            SettingsPage.Screen -> SettingsSlots.screen?.invoke(back) ?: back()
        }
    }
}

@Composable
private fun SettingsScreen() {
    val ui = LocalAosUi.current
    val colors = AosTheme.colors
    val context = platformContext()
    val scope = rememberCoroutineScope()
    val macs by ui.model.macs.collectAsState()
    val settings by ui.settings.settings.collectAsState(initial = null)
    val connection by ui.model.connection.collectAsState()
    val status = connection?.macStatus?.collectAsState()?.value
    val requireUnlock = settings?.requireUnlock ?: ui.lock.isRequired
    val companion = connection?.companionState?.collectAsState()?.value
    // The routines' row needs the Mac's status (the Overview asks for it while it is on screen).
    LaunchedEffect(connection, companion) { connection?.refreshMacStatus() }

    Page(stringResource(R.string.settings)) { padding ->
        PageColumn(padding) {
            Section(header = stringResource(R.string.settings_paired_macs)) {
                macs.forEachIndexed { index, mac ->
                    NavRow(Icons.Rounded.Laptop, mac.name, detail = "${mac.user}@${mac.lastHost ?: mac.hosts.firstOrNull() ?: ""}" +
                        if (index == 0 && macs.size > 1) " · " + stringResource(R.string.settings_in_use) else "") {
                        ui.settingsPages.push(SettingsPage.Mac(mac.id))
                    }
                }
                ActionRow(Icons.Rounded.QrCodeScanner, stringResource(R.string.pair_with_a_mac), divider = false) { ui.startPairing() }
            }
            Section {
                NavRow(Icons.Rounded.Hub, stringResource(R.string.connection), divider = false) { ui.settingsPages.push(SettingsPage.Connection) }
            }
            Section(header = stringResource(R.string.settings_security), footer = stringResource(R.string.settings_security_footer)) {
                SectionRow(divider = requireUnlock) {
                    Icon(Icons.Rounded.Fingerprint, contentDescription = null, tint = colors.indigo, modifier = Modifier.size(24.dp))
                    Text(stringResource(R.string.settings_unlock_to_open), modifier = Modifier.weight(1f))
                    Switch(checked = requireUnlock, onCheckedChange = { on ->
                        scope.launch {
                            if (on) {
                                val outcome = if (ui.isDemo) PresenceOutcome.SUCCESS
                                    else Platform.current.confirmPresence(context.text(R.string.lock_turn_on_prompt))
                                ui.lock.setRequired(true, outcome)
                            } else {
                                ui.lock.setRequired(false)
                            }
                        }
                    })
                }
                if (requireUnlock) {
                    SectionRow(divider = false) {
                        Text(stringResource(R.string.settings_lock_again), modifier = Modifier.weight(1f))
                        val minutes = settings?.autoLockMinutes ?: 5
                        Picker(lockText(minutes).text(), AppLock.AUTO_LOCK_CHOICES.map { it to lockText(it).text() }) { m ->
                            scope.launch { ui.lock.setAutoLockMinutes(m) }
                        }
                    }
                }
            }
            NotificationsSection()
            SettingsSlots.device?.invoke()
            val terminal = SettingsSlots.terminal
            val screen = SettingsSlots.screen
            if (terminal != null || screen != null) {
                Section {
                    if (terminal != null) NavRow(Icons.Rounded.Terminal, stringResource(R.string.terminal), divider = screen != null) {
                        ui.settingsPages.push(SettingsPage.Terminal)
                    }
                    if (screen != null) NavRow(Icons.Rounded.DesktopWindows, stringResource(R.string.screen), divider = false) {
                        ui.settingsPages.push(SettingsPage.Screen)
                    }
                }
            }
            if (status?.routines != null) {
                Section(header = stringResource(R.string.settings_aos_session), footer = stringResource(R.string.settings_routines_footer)) {
                    NavRow(Icons.Rounded.Schedule, stringResource(R.string.routines), divider = false) { ui.settingsPages.push(SettingsPage.Routines) }
                }
            }
            Section(header = stringResource(R.string.settings_this_phone)) {
                NavRow(Icons.Rounded.Key, stringResource(R.string.settings_ssh_key), divider = false) { ui.settingsPages.push(SettingsPage.DeviceKey) }
            }
            Section {
                NavRow(Icons.Rounded.Info, stringResource(R.string.about_title)) { ui.settingsPages.push(SettingsPage.About) }
                NavRow(Icons.Rounded.VolunteerActivism, stringResource(R.string.acknowledgements)) { ui.settingsPages.push(SettingsPage.Acknowledgements) }
                LabeledRow(stringResource(R.string.version), Platform.current.appVersion, divider = false)
            }
        }
    }
}

fun lockText(minutes: Int): Txt = when (minutes) {
    0 -> Txt.res(R.string.lock_right_away)
    60 -> Txt.res(R.string.lock_after_hour)
    else -> Txt.res(R.string.lock_after_minutes, minutes)
}

/** Notifications for requests while the app is in the background (Android 13 asks for them). */
@Composable
private fun NotificationsSection() {
    val platform = Platform.current
    var enabled by remember { mutableStateOf(platform.notificationsEnabled()) }
    val action = platform.rememberNotificationsAction { enabled = platform.notificationsEnabled() }
    Section(footer = stringResource(R.string.settings_notifications_footer)) {
        SectionRow(onClick = action, divider = false) {
            Icon(Icons.Rounded.Notifications, contentDescription = null, tint = AosTheme.colors.indigo, modifier = Modifier.size(24.dp))
            Text(stringResource(R.string.settings_notifications), modifier = Modifier.weight(1f))
            Text(stringResource(if (enabled) R.string.on else R.string.off), color = AosTheme.colors.secondary)
        }
    }
}

// The paired Mac

@Composable
private fun MacDetailPage(id: String, onBack: () -> Unit) {
    val ui = LocalAosUi.current
    val colors = AosTheme.colors
    val scope = rememberCoroutineScope()
    val macs by ui.model.macs.collectAsState()
    val mac = macs.firstOrNull { it.id == id }
    var confirmUnpair by remember { mutableStateOf(false) }
    if (mac == null) {
        LaunchedEffect(Unit) { onBack() }
        return
    }
    Page(mac.name, onBack = onBack) { padding ->
        PageColumn(padding) {
            Section {
                LabeledRow(stringResource(R.string.user), mac.user)
                LabeledRow(stringResource(R.string.paired), Txt.Time(java.time.Instant.ofEpochMilli(mac.pairedAt), Txt.TimeStyle.DATE_TIME).text(),
                    divider = false)
            }
            Section(header = stringResource(R.string.addresses)) {
                mac.hosts.forEachIndexed { i, host ->
                    SectionRow(divider = i < mac.hosts.lastIndex) {
                        Text(host, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                        if (host == mac.lastHost) Text(stringResource(R.string.worked_last), style = MaterialTheme.typography.bodySmall,
                            color = colors.secondary)
                    }
                }
            }
            Section(header = stringResource(R.string.mac_ssh_key), footer = stringResource(R.string.mac_ssh_key_footer)) {
                SectionRow(divider = false) { KeyText(mac.hostKeyFingerprint, Modifier.weight(1f)) }
            }
            if (macs.size > 1 && macs.first().id != mac.id) {
                Section {
                    ActionRow(Icons.AutoMirrored.Rounded.CompareArrows, stringResource(R.string.mac_connect_to_this), divider = false) {
                        scope.launch { ui.model.makeActive(mac) }
                    }
                }
            }
            Section(footer = stringResource(R.string.mac_pair_again_footer)) {
                ActionRow(Icons.Rounded.QrCodeScanner, stringResource(R.string.pair_again), divider = false) { ui.startPairing() }
            }
            Section(footer = stringResource(R.string.mac_unpair_footer)) {
                ActionRow(Icons.Rounded.LinkOff, stringResource(R.string.unpair), destructive = true, divider = false) { confirmUnpair = true }
            }
        }
    }
    if (confirmUnpair) {
        ConfirmDialog(stringResource(R.string.mac_unpair_question, mac.name), stringResource(R.string.mac_unpair_explain),
            stringResource(R.string.unpair), onConfirm = {
                scope.launch {
                    ui.model.unpair(mac)
                    onBack()
                }
            }, onDismiss = { confirmUnpair = false })
    }
}

// This phone's key

@Composable
private fun DeviceKeyPage(onBack: () -> Unit) {
    val ui = LocalAosUi.current
    val context = platformContext()
    var key by remember { mutableStateOf<DeviceKey?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var copied by remember { mutableStateOf(false) }
    var attempt by remember { mutableStateOf(0) }
    LaunchedEffect(attempt) {
        withContext(Dispatchers.IO) {
            try {
                key = ui.keys.sshKey()
                error = null
            } catch (e: Exception) {
                error = e.message ?: e.javaClass.simpleName
            }
        }
    }
    Page(stringResource(R.string.settings_ssh_key), onBack = onBack) { padding ->
        PageColumn(padding) {
            val k = key
            if (k == null) {
                Section {
                    TextRow(error ?: stringResource(R.string.key_unavailable))
                    ActionRow(null, stringResource(R.string.try_again), divider = false) { attempt++ }
                }
                return@PageColumn
            }
            val line = k.openSSHPublicKey + " aos-" + Platform.current.kind.name.lowercase()
            Section(header = stringResource(R.string.key_public), footer = stringResource(R.string.key_public_footer)) {
                SectionRow { KeyText(k.openSSHPublicKey, Modifier.weight(1f), lineLength = 36) }
                val canShare = Platform.current.kind == dev.marquart.aos.ui.platform.PlatformKind.ANDROID
                ActionRow(Icons.Rounded.ContentCopy, stringResource(if (copied) R.string.copied else R.string.key_copy), divider = canShare) {
                    Platform.current.copyToClipboard(line, "SSH key")
                    copied = true
                }
                if (canShare) {
                    ActionRow(Icons.Rounded.Share, stringResource(R.string.key_share), divider = false) { Platform.current.share(line) }
                }
            }
            Section(footer = stringResource(when (k.storage) {
                KeyStorage.STRONG_BOX, KeyStorage.TEE -> R.string.key_hardware_footer
                KeyStorage.TPM -> R.string.key_tpm_footer
                KeyStorage.WINDOWS_SOFTWARE -> R.string.key_windows_software_footer
                KeyStorage.FILE_ENCRYPTED -> R.string.key_file_encrypted_footer
                KeyStorage.FILE -> R.string.key_file_footer
                KeyStorage.KEYSTORE_SOFTWARE, KeyStorage.MEMORY -> R.string.key_software_footer
            })) {
                SectionRow {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(stringResource(R.string.key_fingerprint))
                        KeyText(k.fingerprint)
                    }
                }
                LabeledRow(stringResource(R.string.key_kept_in), stringResource(when (k.storage) {
                    KeyStorage.STRONG_BOX -> R.string.key_strongbox
                    KeyStorage.TEE -> R.string.key_tee
                    KeyStorage.KEYSTORE_SOFTWARE -> R.string.key_keystore
                    KeyStorage.MEMORY -> R.string.key_memory
                    KeyStorage.TPM -> R.string.key_tpm
                    KeyStorage.WINDOWS_SOFTWARE -> R.string.key_windows_software
                    KeyStorage.FILE_ENCRYPTED -> R.string.key_file_encrypted
                    KeyStorage.FILE -> R.string.key_file
                }), divider = false)
            }
        }
    }
}

// What is where

@Composable
private fun AboutPage(onBack: () -> Unit) {
    val colors = AosTheme.colors
    Page(stringResource(R.string.about_title), onBack = onBack) { padding ->
        PageColumn(padding) {
            Row(Modifier.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                AppIconImage(60.dp)
                Column {
                    Text(stringResource(R.string.app_name), style = MaterialTheme.typography.titleLarge)
                    Text(stringResource(R.string.tagline), color = colors.secondary)
                }
            }
            AboutSection(Icons.Rounded.Key, R.string.about_passwords, listOf(R.string.about_passwords_1, R.string.about_passwords_2,
                R.string.about_passwords_3, R.string.about_passwords_4))
            AboutSection(Icons.Rounded.AutoAwesome, R.string.about_agent, listOf(R.string.about_agent_1, R.string.about_agent_2))
            AboutSection(Icons.Rounded.Lock, R.string.about_connection, listOf(R.string.about_connection_1, R.string.about_connection_2))
            AboutSection(Icons.Rounded.DesktopWindows, R.string.screen, listOf(R.string.about_screen_1, R.string.about_screen_2))
        }
    }
}

@Composable
private fun AboutSection(icon: androidx.compose.ui.graphics.vector.ImageVector, title: Int, lines: List<Int>) {
    AosCard {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(icon, contentDescription = null, tint = AosTheme.colors.indigo)
            Text(stringResource(title), style = MaterialTheme.typography.titleMedium, color = AosTheme.colors.indigo)
        }
        for (line in lines) Text(stringResource(line), style = MaterialTheme.typography.bodyMedium)
    }
}

// Acknowledgements

@Composable
private fun AcknowledgementsPage(onBack: () -> Unit) {
    val ui = LocalAosUi.current
    val context = platformContext()
    Page(stringResource(R.string.acknowledgements), onBack = onBack) { padding ->
        PageColumn(padding) {
            Section(footer = stringResource(R.string.ack_app_footer)) {
                TextRow(stringResource(R.string.ack_app), divider = true)
                NavRow(null, stringResource(R.string.ack_gpl), divider = false) { ui.settingsPages.push(SettingsPage.License(LicenseKind.GPL3)) }
            }
            Section(header = "Open Screen Sharing", footer = stringResource(R.string.ack_oss_footer)) {
                TextRow(stringResource(R.string.ack_oss))
                ActionRow(null, stringResource(R.string.ack_oss_source)) {
                    Platform.current.openWeb("https://github.com/nekohasekai/open-screen-sharing")
                }
                NavRow(null, stringResource(R.string.ack_license_notice)) { ui.settingsPages.push(SettingsPage.License(LicenseKind.OPEN_SCREEN_SHARING)) }
                NavRow(null, stringResource(R.string.ack_gpl), divider = false) { ui.settingsPages.push(SettingsPage.License(LicenseKind.GPL3)) }
            }
            Section(header = "Tailscale") {
                TextRow(stringResource(R.string.ack_tailscale))
                NavRow(null, stringResource(R.string.ack_bsd3), divider = false) { ui.settingsPages.push(SettingsPage.License(LicenseKind.TAILSCALE_BSD3)) }
            }
            Section(header = stringResource(R.string.ack_apache_header)) {
                TextRow(stringResource(R.string.ack_apache_list))
                NavRow(null, stringResource(R.string.ack_apache), divider = false) { ui.settingsPages.push(SettingsPage.License(LicenseKind.APACHE2)) }
            }
        }
    }
}

@Composable
private fun LicensePage(kind: LicenseKind, onBack: () -> Unit) {
    val context = platformContext()
    var text by remember { mutableStateOf("") }
    LaunchedEffect(kind) {
        val id = when (kind) {
            LicenseKind.GPL3 -> R.raw.license_gpl3
            LicenseKind.OPEN_SCREEN_SHARING -> R.raw.license_open_screen_sharing
            LicenseKind.APACHE2 -> R.raw.license_apache2
            LicenseKind.TAILSCALE_BSD3 -> R.raw.license_tailscale
        }
        text = withContext(Dispatchers.IO) { context.rawText(id) }
    }
    val title = when (kind) {
        LicenseKind.GPL3 -> stringResource(R.string.ack_gpl)
        LicenseKind.OPEN_SCREEN_SHARING -> stringResource(R.string.ack_license_notice)
        LicenseKind.APACHE2 -> stringResource(R.string.ack_apache)
        LicenseKind.TAILSCALE_BSD3 -> stringResource(R.string.ack_bsd3)
    }
    Page(title, onBack = onBack) { padding ->
        PageColumn(padding) {
            SelectionContainer {
                Text(text, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall, modifier = Modifier.fillMaxWidth())
            }
        }
    }
}

