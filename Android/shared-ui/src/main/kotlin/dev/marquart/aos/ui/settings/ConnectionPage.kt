package dev.marquart.aos.ui.settings

import dev.marquart.aos.ui.platform.Platform
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Login
import androidx.compose.material.icons.automirrored.rounded.Logout
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.GetApp
import androidx.compose.material.icons.rounded.Hub
import androidx.compose.material.icons.rounded.OpenInBrowser
import androidx.compose.material.icons.rounded.RemoveCircleOutline
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Warning
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
import androidx.compose.ui.Modifier
import dev.marquart.aos.ui.platform.stringResource
import androidx.compose.ui.unit.dp
import dev.marquart.aos.R
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.core.ConnectionPlan
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.core.ReachWay
import dev.marquart.aos.core.SSHRoute
import dev.marquart.aos.core.TailnetAddress
import dev.marquart.aos.ui.LocalAosUi
import dev.marquart.aos.ui.Txt
import dev.marquart.aos.ui.components.ActionRow
import dev.marquart.aos.ui.components.ConfirmDialog
import dev.marquart.aos.ui.components.LabeledRow
import dev.marquart.aos.ui.components.Page
import dev.marquart.aos.ui.components.PageColumn
import dev.marquart.aos.ui.components.Section
import dev.marquart.aos.ui.components.SectionRow
import dev.marquart.aos.ui.components.SmallSpinner
import dev.marquart.aos.ui.components.TextRow
import dev.marquart.aos.ui.tailnet.TailnetInfo
import dev.marquart.aos.ui.text
import dev.marquart.aos.ui.theme.AosTheme
import kotlinx.coroutines.delay

/** How the Mac is reached on the go, in words (iOS ConnectionView). */
object ConnectionWords {
    fun way(mac: PairedMac): Txt = when (mac.reachWay) {
        ReachWay.TAILSCALE_APP -> Txt.res(R.string.way_app)
        ReachWay.AOS_TAILSCALE -> Txt.res(R.string.way_aos)
        ReachWay.LOCAL_NETWORK -> Txt.res(R.string.way_lan)
        null -> if (ConnectionPlan.tailnetHosts(mac).isEmpty()) Txt.res(R.string.way_none) else Txt.res(R.string.way_tailscale)
    }

    fun route(route: SSHRoute?): Txt = when (route) {
        null -> Txt.res(R.string.route_not_connected)
        is SSHRoute.Tailnet -> Txt.res(R.string.route_aos, route.host)
        is SSHRoute.Host -> if (TailnetAddress.isTailnetHost(route.host)) Txt.res(R.string.route_app, route.host) else Txt.res(R.string.route_lan, route.host)
        is SSHRoute.Bonjour -> Txt.res(R.string.route_bonjour)
    }
}

/** Settings > Connection: how this phone reaches the Mac now, the Mac's way on the go, aOS's Tailscale on this phone. */
@Composable
fun ConnectionPage(onBack: () -> Unit) {
    val ui = LocalAosUi.current
    val colors = AosTheme.colors
    val connection by ui.model.connection.collectAsState()
    val state = connection?.state?.collectAsState()?.value
    val macs by ui.model.macs.collectAsState()
    val mac = macs.firstOrNull()
    val tailnet = ui.tailnet
    val info = tailnet?.info?.collectAsState()?.value
    var vpn by remember { mutableStateOf(ui.network.tailscaleVpnActive()) }
    var confirmSignOut by remember { mutableStateOf(false) }
    var signingIn by remember { mutableStateOf(false) }
    var setUp by remember { mutableStateOf(tailnet?.isSetUp == true) }

    LaunchedEffect(Unit) {
        while (true) {
            vpn = ui.network.tailscaleVpnActive()
            setUp = tailnet?.isSetUp == true
            delay(3_000)
        }
    }
    // Signing in: the page opens as soon as the node has its URL; done once it runs.
    LaunchedEffect(signingIn, info?.authUrl, info?.isRunning) {
        if (!signingIn) return@LaunchedEffect
        if (info?.isRunning == true) {
            signingIn = false
            connection?.retryNow()
            return@LaunchedEffect
        }
        TailnetInfo.signInPage(info?.authUrl)?.let { Platform.current.openWeb(it) }
    }

    Page(stringResource(R.string.connection), onBack = onBack) { padding ->
        PageColumn(padding) {
            val route = if (state is MacConnection.State.Connected) state.route else null
            Section(header = stringResource(R.string.conn_section), footer = stringResource(R.string.conn_footer)) {
                LabeledRow(stringResource(R.string.conn_now), ConnectionWords.route(route).text(), divider = mac != null)
                if (mac != null) LabeledRow(stringResource(R.string.conn_on_the_go, mac.name), ConnectionWords.way(mac).text(), divider = false)
            }
            if (mac != null && mac.reachWay != ReachWay.LOCAL_NETWORK) {
                if (mac.reachWay == ReachWay.TAILSCALE_APP || ConnectionPlan.tailnetHosts(mac).isNotEmpty()) {
                    Section(footer = stringResource(R.string.conn_app_footer)) {
                        SectionRow(divider = mac.reachWay == ReachWay.TAILSCALE_APP && !vpn && !setUp) {
                            Text(stringResource(R.string.conn_tailscale_app), modifier = Modifier.weight(1f))
                            Icon(if (vpn) Icons.Rounded.CheckCircle else Icons.Rounded.RemoveCircleOutline, contentDescription = null,
                                tint = if (vpn) colors.mint else colors.secondary, modifier = Modifier.size(20.dp))
                            Text(stringResource(if (vpn) R.string.conn_vpn_on else R.string.conn_vpn_off), color = colors.secondary)
                        }
                        if (mac.reachWay == ReachWay.TAILSCALE_APP && !vpn && !setUp) {
                            ActionRow(Icons.Rounded.GetApp, stringResource(R.string.conn_get_app), divider = false) {
                                Platform.current.openWeb(if (Platform.current.kind.isDesktop) "https://tailscale.com/download"
                                    else "https://play.google.com/store/apps/details?id=com.tailscale.ipn")
                            }
                        }
                    }
                }
                if (tailnet != null) {
                    Section(header = stringResource(R.string.conn_node_header), footer = stringResource(R.string.conn_node_footer)) {
                        when {
                            !setUp -> {
                                TextRow(stringResource(if (mac.reachWay == ReachWay.AOS_TAILSCALE) R.string.conn_node_mac_uses else R.string.conn_node_can))
                                mac.tailnetName?.let { LabeledRow(stringResource(R.string.conn_mac_tailnet), it) }
                                ActionRow(Icons.Rounded.Hub, stringResource(R.string.conn_set_up), divider = false) {
                                    tailnet.setUp()
                                    setUp = true
                                    signingIn = true
                                }
                            }
                            info?.isRunning == true -> {
                                LabeledRow(stringResource(R.string.name), info.dnsName)
                                LabeledRow(stringResource(R.string.address), info.addresses.firstOrNull() ?: "")
                                if (info.tailnet.isNotEmpty()) LabeledRow(stringResource(R.string.tailnet), info.tailnet)
                                LabeledRow(stringResource(R.string.conn_key), keyLine(info.keyExpiry).text(),
                                    divider = mac.tailnetName != null && mac.tailnetName != info.tailnet && info.tailnet.isNotEmpty())
                                val expected = mac.tailnetName
                                if (expected != null && info.tailnet.isNotEmpty() && expected != info.tailnet) {
                                    SectionRow(divider = false) {
                                        Icon(Icons.Rounded.Warning, contentDescription = null, tint = colors.orange)
                                        Text(stringResource(R.string.conn_other_tailnet, expected), color = colors.orange,
                                            style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                                    }
                                }
                            }
                            signingIn -> SectionRow(divider = false) {
                                SmallSpinner()
                                Text(stringResource(R.string.conn_signing_in), modifier = Modifier.weight(1f))
                            }
                            info?.needsApproval == true -> TextRow(stringResource(R.string.conn_needs_approval), divider = false)
                            else -> {
                                if (!info?.error.isNullOrEmpty()) TextRow(info.error, color = colors.orange)
                                ActionRow(Icons.AutoMirrored.Rounded.Login, stringResource(R.string.conn_sign_in), divider = false) {
                                    if (TailnetInfo.signInPage(info?.authUrl) == null) tailnet.signIn()
                                    signingIn = true
                                }
                            }
                        }
                    }
                    if (setUp) {
                        Section(footer = stringResource(R.string.conn_sign_out_footer)) {
                            ActionRow(Icons.Rounded.Refresh, stringResource(R.string.conn_reconnect)) {
                                tailnet.reconnect()
                                connection?.retryNow()
                            }
                            ActionRow(Icons.AutoMirrored.Rounded.Logout, stringResource(R.string.sign_out), destructive = true, divider = false) {
                                confirmSignOut = true
                            }
                        }
                    }
                }
            }
            Section(footer = stringResource(R.string.conn_admin_footer)) {
                ActionRow(Icons.Rounded.OpenInBrowser, stringResource(R.string.conn_admin), divider = false) {
                    Platform.current.openWeb("https://login.tailscale.com/admin/machines")
                }
            }
        }
    }
    if (confirmSignOut && tailnet != null) {
        ConfirmDialog(stringResource(R.string.conn_sign_out_question), stringResource(R.string.conn_sign_out_explain), stringResource(R.string.sign_out),
            onConfirm = {
                tailnet.signOut()
                setUp = false
                signingIn = false
                connection?.retryNow()
            }, onDismiss = { confirmSignOut = false })
    }
}

fun keyLine(expiry: String): Txt {
    if (expiry.isEmpty()) return Txt.res(R.string.key_no_expiry)
    val at = dev.marquart.aos.core.Iso8601.parse(expiry) ?: return Txt.raw(expiry)
    if (at.isBefore(java.time.Instant.now())) return Txt.res(R.string.key_expired)
    return Txt.res(R.string.key_expires, Txt.Time(at, Txt.TimeStyle.DATE))
}
