package dev.marquart.aos.ui

import dev.marquart.aos.ui.platform.text
import dev.marquart.aos.ui.platform.Platform
import dev.marquart.aos.ui.platform.platformContext
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.DesktopWindows
import androidx.compose.material.icons.rounded.Fingerprint
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Terminal
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import dev.marquart.aos.ui.platform.stringResource
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.PermanentDrawerSheet
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import dev.marquart.aos.R
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.ui.components.StatusDot
import dev.marquart.aos.ui.layout.LocalWindowLayout
import dev.marquart.aos.ui.layout.Navigation
import dev.marquart.aos.ui.layout.WindowLayout
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.ui.components.AppIconImage
import dev.marquart.aos.ui.overview.OverviewTab
import dev.marquart.aos.ui.pairing.PairingScreen
import dev.marquart.aos.ui.settings.SettingsTab
import dev.marquart.aos.ui.signin.QuestionSheetHost
import dev.marquart.aos.ui.tabs.ScreenTabSlot
import dev.marquart.aos.ui.tabs.TerminalTabSlot
import dev.marquart.aos.ui.theme.AosTheme
import kotlinx.coroutines.launch

/**
 * The app's frame (iOS RootView): the tabs (Overview, Terminal, Screen, Settings), the sheet with the agent's questions,
 * pairing, and the lock above everything. No sheet and no pairing above the lock.
 *
 * Where the tabs are follows the window (ui/layout/WindowLayout.kt): a bar at the bottom of a compact window, a rail
 * at the side of a medium or expanded one, a drawer that stays open in a large one. `window`: the layout the app
 * worked out (Android: the window's size class and its fold); without it the root measures itself. `rail`: at least
 * the rail (the desktop).
 */
@Composable
fun AosRoot(ui: AosUi, rail: Boolean = false, window: WindowLayout? = null) {
    CompositionLocalProvider(LocalAosUi provides ui) {
        if (window != null) {
            CompositionLocalProvider(LocalWindowLayout provides window) { RootContent(ui) }
        } else {
            BoxWithConstraints(Modifier.fillMaxSize()) {
                val measured = WindowLayout(maxWidth.value, maxHeight.value,
                    minimumNavigation = if (rail) Navigation.RAIL else Navigation.BAR)
                CompositionLocalProvider(LocalWindowLayout provides measured) { RootContent(ui) }
            }
        }
    }
}

private class TabEntry(val tab: AppModel.Tab, val icon: ImageVector, val label: Int)

private val Tabs = listOf(
    TabEntry(AppModel.Tab.OVERVIEW, Icons.Rounded.GridView, R.string.overview),
    TabEntry(AppModel.Tab.TERMINAL, Icons.Rounded.Terminal, R.string.terminal),
    TabEntry(AppModel.Tab.SCREEN, Icons.Rounded.DesktopWindows, R.string.screen),
    TabEntry(AppModel.Tab.SETTINGS, Icons.Rounded.Settings, R.string.settings),
)

@Composable
private fun RootContent(ui: AosUi) {
    val model = ui.model
    val layout = LocalWindowLayout.current
    val navigation = layout.navigation
    val tab by model.tab.collectAsState()
    val locked by ui.lock.isLocked.collectAsState()
    val questions by model.questions.collectAsState()
    val help by model.helpRequests.collectAsState()
    val waiting = questions.size + help.size
    AskForNotifications()

    // Tapping the tab on screen again goes back to its first page.
    val select: (AppModel.Tab) -> Unit = { item ->
        if (item == tab) {
            if (item == AppModel.Tab.OVERVIEW) ui.overview.set()
            if (item == AppModel.Tab.SETTINGS) ui.settingsPages.set()
        }
        model.selectTab(item)
    }

    Box(Modifier.fillMaxSize()) {
        // One place for the tab's content whatever the navigation is: turning the device or resizing the window moves
        // the tabs from the bottom to the side, and the page keeps its state.
        // (The Surface also gives the tabs' content its text color.)
        Surface(Modifier.fillMaxSize(), color = AosTheme.colors.background, contentColor = MaterialTheme.colorScheme.onBackground) {
        Row(Modifier.fillMaxSize()) {
            when (navigation) {
                Navigation.RAIL -> NavigationRail(containerColor = AosTheme.colors.card,
                    modifier = Modifier.width(WindowLayout.RAIL_WIDTH.dp).fillMaxHeight()) {
                    Spacer(Modifier.height(12.dp))
                    for (entry in Tabs) RailItem(entry, tab, if (entry.tab == AppModel.Tab.OVERVIEW) waiting else 0, select)
                }
                Navigation.DRAWER -> TabDrawer(tab, waiting, select)
                Navigation.BAR -> Unit
            }
            Column(Modifier.weight(1f).fillMaxHeight()) {
                val sides = if (navigation == Navigation.BAR) WindowInsetsSides.Horizontal else WindowInsetsSides.End
                Box(
                    Modifier.weight(1f).fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing.only(sides))
                        // Beside a rail nothing takes the system's bar at the bottom: the content stays above it.
                        .then(if (navigation == Navigation.BAR) Modifier else Modifier.windowInsetsPadding(WindowInsets.navigationBars.only(WindowInsetsSides.Bottom))),
                ) {
                    when (tab) {
                        AppModel.Tab.OVERVIEW -> OverviewTab()
                        AppModel.Tab.TERMINAL -> TerminalTabSlot(model, Modifier.fillMaxSize())
                        // Only while it is the tab on screen (iOS: behind the others it started its screen by itself).
                        AppModel.Tab.SCREEN -> ScreenTabSlot(model, Modifier.fillMaxSize())
                        AppModel.Tab.SETTINGS -> SettingsTab()
                    }
                }
                if (navigation == Navigation.BAR) {
                    NavigationBar(containerColor = AosTheme.colors.card) {
                        for (entry in Tabs) TabItem(entry, tab, if (entry.tab == AppModel.Tab.OVERVIEW) waiting else 0, select)
                    }
                }
            }
        }
        }
        val pairing = ui.pairing
        if (pairing != null && !locked) {
            Surface(Modifier.fillMaxSize(), color = AosTheme.colors.background) {
                PairingScreen(pairing.link, onClose = { ui.pairing = null })
            }
        }
        QuestionSheetHost(locked)
        AnimatedVisibility(locked, enter = fadeIn(), exit = fadeOut()) { LockScreen() }
    }
}

@Composable
private fun TabIcon(entry: TabEntry, badge: Int) {
    if (badge > 0) BadgedBox(badge = { Badge { Text(badge.toString()) } }) { Icon(entry.icon, contentDescription = null) }
    else Icon(entry.icon, contentDescription = null)
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.TabItem(entry: TabEntry, selected: AppModel.Tab, badge: Int, select: (AppModel.Tab) -> Unit) {
    NavigationBarItem(
        selected = entry.tab == selected,
        onClick = { select(entry.tab) },
        icon = { TabIcon(entry, badge) },
        label = { Text(stringResource(entry.label), maxLines = 1) },
        colors = NavigationBarItemDefaults.colors(indicatorColor = AosTheme.colors.indigo.copy(alpha = 0.16f),
            selectedIconColor = AosTheme.colors.indigo, selectedTextColor = AosTheme.colors.indigo),
    )
}

/** The same tab in the navigation rail (medium and expanded windows). */
@Composable
private fun RailItem(entry: TabEntry, selected: AppModel.Tab, badge: Int, select: (AppModel.Tab) -> Unit) {
    NavigationRailItem(
        selected = entry.tab == selected,
        onClick = { select(entry.tab) },
        icon = { TabIcon(entry, badge) },
        label = { Text(stringResource(entry.label), maxLines = 1) },
        colors = NavigationRailItemDefaults.colors(indicatorColor = AosTheme.colors.indigo.copy(alpha = 0.16f),
            selectedIconColor = AosTheme.colors.indigo, selectedTextColor = AosTheme.colors.indigo),
    )
}

/** The tabs in a drawer that stays open (large windows): the app's name, the tabs, and the Mac with its state. */
@Composable
private fun TabDrawer(selected: AppModel.Tab, waiting: Int, select: (AppModel.Tab) -> Unit) {
    val colors = AosTheme.colors
    val ui = LocalAosUi.current
    PermanentDrawerSheet(Modifier.width(WindowLayout.DRAWER_WIDTH.dp).fillMaxHeight(), drawerContainerColor = colors.card) {
        Row(Modifier.padding(start = 20.dp, end = 16.dp, top = 20.dp, bottom = 16.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            AppIconImage(36.dp)
            Text(stringResource(R.string.app_name), style = MaterialTheme.typography.titleLarge)
        }
        for (entry in Tabs) {
            val badge = if (entry.tab == AppModel.Tab.OVERVIEW) waiting else 0
            NavigationDrawerItem(
                selected = entry.tab == selected,
                onClick = { select(entry.tab) },
                icon = { Icon(entry.icon, contentDescription = null) },
                label = { Text(stringResource(entry.label), maxLines = 1) },
                badge = if (badge > 0) ({ Badge { Text(badge.toString()) } }) else null,
                colors = NavigationDrawerItemDefaults.colors(selectedContainerColor = colors.indigo.copy(alpha = 0.16f),
                    selectedIconColor = colors.indigo, selectedTextColor = colors.indigo, unselectedContainerColor = Color.Transparent),
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 2.dp),
            )
        }
        Spacer(Modifier.weight(1f))
        val connection by ui.model.connection.collectAsState()
        connection?.let { c ->
            val mac by c.mac.collectAsState()
            val state by c.state.collectAsState()
            val sleeping by c.sleepingSince.collectAsState()
            val tint = when {
                sleeping != null -> colors.indigo
                state is MacConnection.State.Connected -> colors.green
                state is MacConnection.State.Unreachable -> colors.orange
                state is MacConnection.State.NeedsAttention -> colors.red
                else -> colors.gray
            }
            Row(Modifier.padding(horizontal = 24.dp, vertical = 20.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                StatusDot(tint)
                Text(mac.name, style = MaterialTheme.typography.bodyMedium, color = colors.secondary, maxLines = 1,
                    overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/** Android 13 asks before an app may post notifications: once, after pairing (requests that come while the app is in
 *  the background). Settings has the switch later. */
@Composable
private fun AskForNotifications() {
    val ui = LocalAosUi.current
    if (ui.isDemo) return
    val ask = Platform.current.rememberNotificationPermissionRequest() ?: return
    val macs by ui.model.macs.collectAsState()
    val settings by ui.settings.settings.collectAsState(initial = null)
    val scope = rememberCoroutineScope()
    LaunchedEffect(macs.isNotEmpty(), settings?.notificationsAsked) {
        val s = settings ?: return@LaunchedEffect
        if (macs.isEmpty() || s.notificationsAsked) return@LaunchedEffect
        scope.launch { ui.settings.update { it.copy(notificationsAsked = true) } }
        ask()
    }
}

/** "aOS is locked": unlock with the fingerprint, face or the phone's screen lock. */
@Composable
fun LockScreen() {
    val ui = LocalAosUi.current
    val context = platformContext()
    val scope = rememberCoroutineScope()
    val failed by ui.lock.failed.collectAsState()
    val unlock: () -> Unit = {
        scope.launch { ui.lock.unlocked(Platform.current.confirmPresence(context.text(R.string.lock_prompt))) }
    }
    LaunchedEffect(Unit) { if (!ui.isDemo) unlock() }
    Surface(Modifier.fillMaxSize(), color = AosTheme.colors.background) {
        // (In a wide window the button keeps a button's width.)
        Column(Modifier.fillMaxSize().safeDrawingPadding().wrapContentWidth().widthIn(max = 480.dp).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.weight(1f))
            AppIconImage(84.dp)
            Spacer(Modifier.height(20.dp))
            Text(stringResource(R.string.lock_title), style = MaterialTheme.typography.headlineSmall)
            if (failed) {
                Spacer(Modifier.height(8.dp))
                Text(stringResource(R.string.lock_failed), color = AosTheme.colors.secondary, textAlign = TextAlign.Center)
            }
            Spacer(Modifier.weight(1f))
            Button(onClick = unlock, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).height(52.dp)) {
                Icon(Icons.Rounded.Fingerprint, contentDescription = null)
                Spacer(Modifier.size(8.dp))
                Text(stringResource(R.string.lock_unlock))
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

