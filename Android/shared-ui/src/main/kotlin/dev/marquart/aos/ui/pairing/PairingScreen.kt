package dev.marquart.aos.ui.pairing

import dev.marquart.aos.ui.platform.Platform
import dev.marquart.aos.ui.platform.platformContext
import dev.marquart.aos.ui.platform.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CameraAlt
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.Hub
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.Lan
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.PriorityHigh
import androidx.compose.material.icons.rounded.QrCodeScanner
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import dev.marquart.aos.ui.platform.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.marquart.aos.R
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.core.PairingLink
import dev.marquart.aos.core.ReachWay
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.ui.ErrorText
import dev.marquart.aos.ui.LocalAosUi
import dev.marquart.aos.ui.components.AosCard
import dev.marquart.aos.ui.components.FactRow
import dev.marquart.aos.ui.components.HeroSymbol
import dev.marquart.aos.ui.components.KeyText
import dev.marquart.aos.ui.components.Page
import dev.marquart.aos.ui.components.PageColumn
import dev.marquart.aos.ui.components.Section
import dev.marquart.aos.ui.components.SectionRow
import dev.marquart.aos.ui.theme.AosTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** The steps of pairing (iOS PairingView). */
sealed interface PairingStep {
    data object Scan : PairingStep
    data class Confirm(val link: PairingLink) : PairingStep
    data class Working(val link: PairingLink, val progress: AppModel.PairingStepKind?) : PairingStep
    data class Done(val mac: PairedMac) : PairingStep
    data class Failed(val link: PairingLink, val message: String) : PairingStep
}

/** A scanned or pasted text: the next step, or why it isn't a pairing code. */
fun acceptPairingText(text: String): Pair<PairingStep?, Int?> = try {
    PairingStep.Confirm(PairingLink.parse(text)) to null
} catch (_: PairingLink.ParseError.NewerVersion) {
    null to R.string.pair_newer_code
} catch (_: Exception) {
    null to R.string.pair_not_a_code
}

/** Pairing with a Mac: scan (or paste) the code aOS on the Mac shows, check what it says, pair. */
@Composable
fun PairingScreen(initialLink: String?, onClose: () -> Unit) {
    val ui = LocalAosUi.current
    val context = platformContext()
    val scope = rememberCoroutineScope()
    var step by remember { mutableStateOf<PairingStep>(PairingStep.Scan) }
    var parseError by remember { mutableStateOf<Int?>(null) }

    fun accept(text: String) {
        val (next, error) = acceptPairingText(text)
        parseError = error
        if (next != null) step = next
    }

    LaunchedEffect(initialLink) {
        if (initialLink != null) accept(initialLink)
        else ui.demo?.pairingLink?.let { step = PairingStep.Confirm(it) }
    }

    fun pair(link: PairingLink) {
        step = PairingStep.Working(link, null)
        scope.launch {
            step = try {
                val mac = ui.model.pair(link) { progress ->
                    if (progress.kind != AppModel.PairingStepKind.DONE) step = PairingStep.Working(link, progress.kind)
                }
                PairingStep.Done(mac)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                PairingStep.Failed(link, ErrorText.of(e).resolve(context))
            }
        }
    }

    val working = step is PairingStep.Working
    BackHandler { if (!working) onClose() }
    Page(stringResource(R.string.pair_title), actions = {
        if (step !is PairingStep.Done) TextButton(onClick = onClose, enabled = !working) { Text(stringResource(R.string.cancel)) }
    }) { padding ->
        when (val s = step) {
            PairingStep.Scan -> ScanStep(padding, parseError, ::accept)
            is PairingStep.Confirm -> ConfirmStep(padding, s.link) { pair(s.link) }
            is PairingStep.Working -> WorkingStep(padding, s.progress)
            is PairingStep.Done -> DoneStep(padding, s.mac, onClose)
            is PairingStep.Failed -> FailedStep(padding, s.message, retry = { pair(s.link) }, scanAgain = { step = PairingStep.Scan })
        }
    }
}

@Composable
private fun ScanStep(padding: androidx.compose.foundation.layout.PaddingValues, parseError: Int?, accept: (String) -> Unit) {
    val colors = AosTheme.colors
    val ui = LocalAosUi.current
    var pasted by remember { mutableStateOf("") }
    val scanner = Platform.current.pairingScanner
    PageColumn(padding) {
        if (scanner != null) {
            scanner(Modifier.fillMaxWidth().height(320.dp).clip(RoundedCornerShape(24.dp)).background(Color.Black), ui.isDemo, accept)
        } else {
            // No camera (the desktop): the link is pasted. aOS on the Mac shows it next to the QR code.
            Section(footer = stringResource(R.string.pair_paste_footer)) {
                SectionRow(divider = false) {
                    HeroSymbol(Icons.Rounded.Link, size = 44.dp)
                    Text(stringResource(R.string.pair_paste_hint), style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                }
            }
        }
        Text(stringResource(R.string.pair_or_paste), style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 12.dp))
        OutlinedTextField(pasted, { pasted = it }, placeholder = { Text("aos-pair://v1?…", fontFamily = FontFamily.Monospace) },
            textStyle = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace), maxLines = 4,
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false), modifier = Modifier.fillMaxWidth())
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = {
                val text = Platform.current.clipboardText()
                if (!text.isNullOrBlank()) {
                    pasted = text
                    accept(text)
                }
            }) {
                Icon(Icons.Rounded.ContentPaste, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(6.dp))
                Text(stringResource(R.string.paste))
            }
            Spacer(Modifier.weight(1f))
            Button(onClick = { accept(pasted) }, enabled = pasted.isNotBlank()) { Text(stringResource(R.string.continue_)) }
        }
        if (parseError != null) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Rounded.Warning, contentDescription = null, tint = colors.red, modifier = Modifier.size(18.dp))
                Text(stringResource(parseError), color = colors.red, style = MaterialTheme.typography.bodyMedium)
            }
        }
        Column(Modifier.padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            FactRow(Icons.Rounded.Computer, stringResource(R.string.pair_fact_mac))
            FactRow(Icons.Rounded.Key, stringResource(R.string.pair_fact_key))
        }
    }
}

@Composable
private fun ConfirmStep(padding: androidx.compose.foundation.layout.PaddingValues, link: PairingLink, pair: () -> Unit) {
    val ui = LocalAosUi.current
    val colors = AosTheme.colors
    val scope = rememberCoroutineScope()
    val deviceName by ui.model.deviceName.collectAsState()
    var name by remember { mutableStateOf(deviceName) }
    PageColumn(padding) {
        Section(footer = stringResource(R.string.pair_only_own_mac)) {
            SectionRow(divider = false) {
                HeroSymbol(Icons.Rounded.Laptop, size = 52.dp)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(link.macName, style = MaterialTheme.typography.titleLarge)
                    Text(stringResource(R.string.pair_user, link.user), style = MaterialTheme.typography.bodyMedium, color = colors.secondary)
                }
            }
        }
        val wayFooter = when (link.way) {
            ReachWay.AOS_TAILSCALE -> stringResource(R.string.pair_way_aos)
            ReachWay.TAILSCALE_APP -> stringResource(R.string.pair_way_app)
            ReachWay.LOCAL_NETWORK -> stringResource(R.string.pair_way_lan)
            null -> null
        }
        Section(header = stringResource(R.string.pair_how_reached), footer = wayFooter) {
            link.hosts.forEachIndexed { i, host ->
                SectionRow(divider = i < link.hosts.lastIndex) {
                    Icon(if (host.endsWith(".ts.net") || host in link.tailnetHosts) Icons.Rounded.Hub else Icons.Rounded.Lan,
                        contentDescription = null, tint = colors.indigo, modifier = Modifier.size(20.dp))
                    Text(host, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                }
            }
        }
        Section(header = stringResource(R.string.mac_ssh_key), footer = stringResource(R.string.pair_key_footer)) {
            SectionRow(divider = false) { KeyText(link.hostKeyFingerprint, Modifier.weight(1f)) }
        }
        Section(header = stringResource(R.string.pair_device_name), footer = stringResource(R.string.pair_device_name_footer)) {
            SectionRow(divider = false) {
                OutlinedTextField(name, { name = it }, singleLine = true, modifier = Modifier.fillMaxWidth())
            }
        }
        Button(onClick = {
            scope.launch {
                ui.model.setDeviceName(name)
                pair()
            }
        }, modifier = Modifier.fillMaxWidth().padding(top = 12.dp).height(52.dp)) {
            Icon(Icons.Rounded.Link, contentDescription = null)
            Spacer(Modifier.size(8.dp))
            Text(stringResource(R.string.pair))
        }
    }
}

@Composable
private fun WorkingStep(padding: androidx.compose.foundation.layout.PaddingValues, progress: AppModel.PairingStepKind?) {
    Column(Modifier.fillMaxSize().padding(padding).wrapContentWidth().widthIn(max = 560.dp).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(22.dp, Alignment.CenterVertically)) {
        CircularProgressIndicator(Modifier.size(48.dp))
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            ProgressLine(stringResource(R.string.pair_asking_mac),
                if (progress == null || progress == AppModel.PairingStepKind.CONTACTING_MAC) LineState.RUNNING else LineState.DONE)
            ProgressLine(stringResource(R.string.pair_checking_key),
                if (progress == AppModel.PairingStepKind.CHECKING_KEY) LineState.RUNNING else LineState.WAITING)
        }
    }
}

private enum class LineState { WAITING, RUNNING, DONE }

@Composable
private fun ProgressLine(text: String, state: LineState) {
    val colors = AosTheme.colors
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        when (state) {
            LineState.DONE -> Icon(Icons.Rounded.CheckCircle, contentDescription = null, tint = colors.mint)
            LineState.RUNNING -> CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            LineState.WAITING -> Icon(Icons.Rounded.RadioButtonUnchecked, contentDescription = null, tint = colors.secondary)
        }
        Text(text, color = if (state == LineState.WAITING) colors.secondary else MaterialTheme.colorScheme.onSurface)
    }
}

@Composable
private fun DoneStep(padding: androidx.compose.foundation.layout.PaddingValues, mac: PairedMac, onClose: () -> Unit) {
    val ui = LocalAosUi.current
    val colors = AosTheme.colors
    val tailnet = ui.tailnet
    Column(Modifier.fillMaxSize().padding(padding).wrapContentWidth().widthIn(max = 560.dp).padding(24.dp).verticalScroll(rememberScrollState()),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Spacer(Modifier.height(40.dp))
        HeroSymbol(Icons.Rounded.Check, tint = colors.mint, size = 84.dp)
        Text(stringResource(R.string.pair_done, mac.name), style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
        Text(stringResource(R.string.pair_done_text), color = colors.secondary, textAlign = TextAlign.Center)
        if (mac.reachWay == ReachWay.AOS_TAILSCALE && tailnet != null && !tailnet.isSetUp) {
            FilledTonalButton(onClick = {
                tailnet.setUp()
                onClose()
                ui.model.selectTab(AppModel.Tab.SETTINGS)
                ui.settingsPages.set(dev.marquart.aos.ui.SettingsPage.Connection)
            }, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Rounded.Hub, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(8.dp))
                Text(stringResource(R.string.pair_set_up_tailscale))
            }
        }
        Spacer(Modifier.height(24.dp))
        Button(onClick = onClose, modifier = Modifier.fillMaxWidth().height(52.dp)) { Text(stringResource(R.string.done)) }
    }
}

@Composable
private fun FailedStep(padding: androidx.compose.foundation.layout.PaddingValues, message: String, retry: () -> Unit, scanAgain: () -> Unit) {
    val colors = AosTheme.colors
    Column(Modifier.fillMaxSize().padding(padding).wrapContentWidth().widthIn(max = 560.dp).padding(24.dp).verticalScroll(rememberScrollState()),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Spacer(Modifier.height(40.dp))
        HeroSymbol(Icons.Rounded.PriorityHigh, tint = colors.orange, size = 84.dp)
        Text(stringResource(R.string.pair_failed), style = MaterialTheme.typography.headlineSmall)
        Text(message, color = colors.secondary, textAlign = TextAlign.Center)
        Spacer(Modifier.height(24.dp))
        Button(onClick = retry, modifier = Modifier.fillMaxWidth().height(52.dp)) { Text(stringResource(R.string.try_again)) }
        FilledTonalButton(onClick = scanAgain) { Text(stringResource(R.string.pair_scan_another)) }
    }
}

