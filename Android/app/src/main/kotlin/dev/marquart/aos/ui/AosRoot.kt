package dev.marquart.aos.ui

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.marquart.aos.R
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.ui.components.AppIconImage
import dev.marquart.aos.ui.lock.Biometrics
import dev.marquart.aos.ui.lock.fragmentActivity
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
 */
@Composable
fun AosRoot(ui: AosUi) {
    CompositionLocalProvider(LocalAosUi provides ui) {
        val model = ui.model
        val tab by model.tab.collectAsState()
        val locked by ui.lock.isLocked.collectAsState()
        val questions by model.questions.collectAsState()
        val help by model.helpRequests.collectAsState()
        val waiting = questions.size + help.size
        AskForNotifications()

        Box(Modifier.fillMaxSize()) {
            Scaffold(
                containerColor = AosTheme.colors.background,
                contentWindowInsets = WindowInsets(0, 0, 0, 0),
                bottomBar = {
                    NavigationBar(containerColor = AosTheme.colors.card) {
                        TabItem(AppModel.Tab.OVERVIEW, tab, Icons.Rounded.GridView, R.string.overview, badge = waiting)
                        TabItem(AppModel.Tab.TERMINAL, tab, Icons.Rounded.Terminal, R.string.terminal)
                        TabItem(AppModel.Tab.SCREEN, tab, Icons.Rounded.DesktopWindows, R.string.screen)
                        TabItem(AppModel.Tab.SETTINGS, tab, Icons.Rounded.Settings, R.string.settings)
                    }
                },
            ) { padding ->
                Box(Modifier.fillMaxSize().padding(bottom = padding.calculateBottomPadding())) {
                    when (tab) {
                        AppModel.Tab.OVERVIEW -> OverviewTab()
                        AppModel.Tab.TERMINAL -> TerminalTabSlot(model, Modifier.fillMaxSize())
                        // Only while it is the tab on screen (iOS: behind the others it started its screen by itself).
                        AppModel.Tab.SCREEN -> ScreenTabSlot(model, Modifier.fillMaxSize())
                        AppModel.Tab.SETTINGS -> SettingsTab()
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
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.TabItem(
    item: AppModel.Tab, selected: AppModel.Tab, icon: ImageVector, label: Int, badge: Int = 0,
) {
    val ui = LocalAosUi.current
    NavigationBarItem(
        selected = item == selected,
        onClick = {
            // Tapping the tab on screen again goes back to its first page.
            if (item == selected) {
                if (item == AppModel.Tab.OVERVIEW) ui.overview.set()
                if (item == AppModel.Tab.SETTINGS) ui.settingsPages.set()
            }
            ui.model.selectTab(item)
        },
        icon = {
            if (badge > 0) BadgedBox(badge = { Badge { Text(badge.toString()) } }) { Icon(icon, contentDescription = null) }
            else Icon(icon, contentDescription = null)
        },
        label = { Text(stringResource(label), maxLines = 1) },
        colors = NavigationBarItemDefaults.colors(indicatorColor = AosTheme.colors.indigo.copy(alpha = 0.16f),
            selectedIconColor = AosTheme.colors.indigo, selectedTextColor = AosTheme.colors.indigo),
    )
}

/** Android 13 asks before an app may post notifications: once, after pairing (requests that come while the app is in
 *  the background). Settings has the switch later. */
@Composable
private fun AskForNotifications() {
    val ui = LocalAosUi.current
    if (ui.isDemo || Build.VERSION.SDK_INT < 33) return
    val macs by ui.model.macs.collectAsState()
    val settings by ui.settings.settings.collectAsState(initial = null)
    val scope = rememberCoroutineScope()
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    LaunchedEffect(macs.isNotEmpty(), settings?.notificationsAsked) {
        val s = settings ?: return@LaunchedEffect
        if (macs.isEmpty() || s.notificationsAsked) return@LaunchedEffect
        scope.launch { ui.settings.update { it.copy(notificationsAsked = true) } }
        launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
}

/** "aOS is locked": unlock with the fingerprint, face or the phone's screen lock. */
@Composable
fun LockScreen() {
    val ui = LocalAosUi.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val failed by ui.lock.failed.collectAsState()
    val unlock: () -> Unit = {
        scope.launch {
            val activity = context.fragmentActivity() ?: return@launch
            ui.lock.unlocked(Biometrics.authenticate(activity, context.getString(R.string.lock_prompt)))
        }
    }
    LaunchedEffect(Unit) { if (!ui.isDemo) unlock() }
    Surface(Modifier.fillMaxSize(), color = AosTheme.colors.background) {
        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
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

