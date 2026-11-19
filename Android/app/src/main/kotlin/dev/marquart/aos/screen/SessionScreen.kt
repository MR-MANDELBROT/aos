// Based on Open Screen Sharing by nekohasekai (GPL-3.0); Android/app/src/main/assets/open-screen-sharing/LICENSE,
// COPYING. Ported for aOS's Android app on 2026-11-19 from iOS/ThirdParty/OpenScreenSharing (SessionUI/SessionView.swift,
// SessionToolbar.swift, SessionMenus.swift, SessionCommand.swift, SessionStatusOverlay.swift,
// KeyboardAccessoryBar.swift): the running session full screen, its floating control menu, the key row above the
// on-screen keyboard, and what it says while connecting or after a failure.

package dev.marquart.aos.screen

import android.content.pm.ActivityInfo
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Logout
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Fullscreen
import androidx.compose.material.icons.outlined.FullscreenExit
import androidx.compose.material.icons.outlined.Keyboard
import androidx.compose.material.icons.outlined.KeyboardHide
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import dev.marquart.aos.R
import dev.marquart.aos.core.HelpRequest
import kotlinx.coroutines.delay

/** The session full screen (immersive, over the tabs), with its floating menu. */
@Composable
internal fun SessionScreen(
    session: SessionModel,
    hub: ScreenHub,
    help: HelpRequest?,
    isWorkspace: Boolean,
    onShowWorkspace: () -> Unit,
    onHelpDone: (HelpRequest) -> Unit,
    onClose: () -> Unit,
) {
    Dialog(
        onDismissRequest = {},
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false, dismissOnBackPress = false,
            dismissOnClickOutside = false),
    ) {
        val view = LocalView.current
        val window = (view.parent as? DialogWindowProvider)?.window
        DisposableEffect(window) {
            window?.let {
                it.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
                it.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING)
                it.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                it.setBackgroundDrawableResource(android.R.color.black)
                if (android.os.Build.VERSION.SDK_INT >= 28) {
                    it.attributes = it.attributes.apply {
                        layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                    }
                }
                WindowCompat.setDecorFitsSystemWindows(it, false)
                WindowInsetsControllerCompat(it, it.decorView).apply {
                    hide(WindowInsetsCompat.Type.systemBars())
                    systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                }
            }
            onDispose { }
        }
        SessionContent(session, hub, help, isWorkspace, onShowWorkspace, onHelpDone, onClose)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SessionContent(
    session: SessionModel,
    hub: ScreenHub,
    help: HelpRequest?,
    isWorkspace: Boolean,
    onShowWorkspace: () -> Unit,
    onHelpDone: (HelpRequest) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val touchMode by hub.store.touchMode.collectAsState()
    var menuOpen by remember { mutableStateOf(false) }
    var keyboardUp by remember { mutableStateOf(false) }
    var screenView by remember { mutableStateOf<RemoteScreenView?>(null) }

    // Turning the phone: a picture in the window's shape follows it; a screen in its own size turns the phone to it.
    val activity = remember(context) { context.findActivity() }
    val follows = session.picturesFollowWindow
    val landscape = session.imageWidth >= session.imageHeight
    DisposableEffect(activity, follows, landscape, session.hasPicture) {
        activity?.requestedOrientation = when {
            follows || !session.hasPicture -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            landscape -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            else -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
        }
        onDispose { }
    }
    DisposableEffect(activity) {
        onDispose {
            if (activity?.isChangingConfigurations != true) activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }

    BackHandler { menuOpen = !menuOpen }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            factory = { RemoteScreenView(it).also { v -> screenView = v } },
            modifier = Modifier.fillMaxSize(),
            update = { v ->
                v.session = session
                v.touchMode = touchMode
                v.onKeyboardVisible = { keyboardUp = it }
                // Read so the view refits when the picture's size changes
                session.imageWidth + session.imageHeight
                v.imageSizeChanged()
            },
            onRelease = { v -> v.session = null },
        )

        // The help request points at a region of the workspace: zoom onto it once there is a picture.
        LaunchedEffect(help?.id, session.hasPicture) {
            val region = help?.region ?: return@LaunchedEffect
            if (!isWorkspace || !session.hasPicture || region.isEmpty) return@LaunchedEffect
            screenView?.focus(region.x.toFloat(), region.y.toFloat(), region.width.toFloat(), region.height.toFloat())
        }

        StatusOverlay(session, onClose)

        // The menu's handle at the top, as OSS's toolbar handle
        Box(Modifier.align(Alignment.TopCenter).safeDrawingPadding().padding(top = 4.dp)) {
            Surface(
                onClick = { menuOpen = !menuOpen },
                shape = RoundedCornerShape(50),
                color = Color.Black.copy(alpha = 0.45f),
                contentColor = Color.White,
            ) {
                Box(Modifier.padding(horizontal = 18.dp, vertical = 8.dp)) {
                    Box(Modifier.size(width = 36.dp, height = 5.dp).clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.8f)))
                }
            }
        }

        help?.let { HelpPill(it, if (isWorkspace) null else onShowWorkspace, menuOpen) { onHelpDone(it) } }

        if (keyboardUp) {
            KeyRow(session, Modifier.align(Alignment.BottomCenter).imePadding()) { screenView?.showKeyboard(false) }
        }

        AnimatedVisibility(menuOpen, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.align(Alignment.TopCenter)) {
            ControlMenu(
                session = session,
                hub = hub,
                touchMode = touchMode,
                keyboardUp = keyboardUp,
                pictureFitted = screenView?.viewport?.isActualSize != true,
                onKeyboard = {
                    menuOpen = false
                    screenView?.showKeyboard(!keyboardUp)
                },
                onFit = { fit ->
                    if (fit) screenView?.fit() else screenView?.actualSize()
                    menuOpen = false
                },
                onDismiss = { menuOpen = false },
                onDisconnect = {
                    menuOpen = false
                    screenView?.showKeyboard(false)
                    session.close()
                    onClose()
                },
            )
        }

        session.alert?.let { text ->
            AlertDialog(onDismissRequest = { session.alert = null }, text = { Text(text) },
                confirmButton = { TextButton(onClick = { session.alert = null }) { Text(stringResource(R.string.screen_ok)) } })
        }
        if (session.secureInputNotice) {
            LaunchedEffect(Unit) {
                delay(2500)
                session.secureInputNotice = false
            }
            Surface(Modifier.align(Alignment.Center), shape = RoundedCornerShape(16.dp), color = Color.Black.copy(alpha = 0.75f), contentColor = Color.White) {
                Text(stringResource(R.string.screen_secure_input), Modifier.padding(16.dp))
            }
        }
    }
}

/** Connecting, reconnecting, waiting; failures as alerts with what libsharing said (OSS's SessionStatusOverlay). */
@Composable
private fun StatusOverlay(session: SessionModel, onClose: () -> Unit) {
    val name = session.route.name
    val progress: Int? = when (session.phase) {
        SessionPhase.Connecting, SessionPhase.Authenticating -> R.string.screen_status_connecting
        is SessionPhase.Reconnecting -> R.string.screen_status_reconnecting
        SessionPhase.WaitingForPermission -> R.string.screen_status_waiting_permission
        SessionPhase.Connected -> if (!session.hasPicture) {
            if (session.usesHighPerformance) R.string.screen_status_starting_high_performance else R.string.screen_status_connecting
        } else null
        else -> null
    }
    if (progress != null) {
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f)), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator(color = Color.White)
                Text(stringResource(progress), color = Color.White, modifier = Modifier.padding(top = 16.dp))
                if (session.phase == SessionPhase.WaitingForPermission) {
                    TextButton(onClick = { session.close(); onClose() }) { Text(stringResource(R.string.screen_cancel), color = Color.White) }
                }
            }
        }
    }
    when (val phase = session.phase) {
        is SessionPhase.Failed -> {
            val failure = phase.failure
            val canConnectAnyway = failure.kind == FailureKind.CERTIFICATE_CHANGED || failure.kind == FailureKind.UNVERIFIED_SERVER
            AlertDialog(
                onDismissRequest = {},
                title = { Text(failureTitle(failure, name)) },
                text = {
                    Text(
                        when (failure.kind) {
                            FailureKind.CERTIFICATE_CHANGED -> stringResource(R.string.screen_failure_key_changed_message)
                            FailureKind.UNVERIFIED_SERVER -> stringResource(R.string.screen_failure_unverified_message)
                            else -> failure.message
                        },
                    )
                },
                confirmButton = { TextButton(onClick = { session.close(); onClose() }) { Text(stringResource(R.string.screen_close)) } },
                dismissButton = if (canConnectAnyway) {
                    {
                        TextButton(onClick = {
                            if (failure.kind == FailureKind.CERTIFICATE_CHANGED) session.trustKey(failure.fingerprint) else session.allowUnverifiedLogin()
                        }) { Text(stringResource(R.string.screen_connect_anyway)) }
                    }
                } else null,
            )
        }
        SessionPhase.Disconnected -> if (!session.isClosed) {
            AlertDialog(
                onDismissRequest = {},
                title = { Text(stringResource(R.string.screen_disconnected)) },
                confirmButton = { TextButton(onClick = { session.close(); onClose() }) { Text(stringResource(R.string.screen_close)) } },
                dismissButton = { TextButton(onClick = { session.retry() }) { Text(stringResource(R.string.screen_reconnect)) } },
            )
        }
        is SessionPhase.ChoosingSession -> {
            val prompt = phase.prompt
            AlertDialog(
                onDismissRequest = {},
                title = { Text(stringResource(R.string.screen_in_use, name)) },
                text = { if (prompt.consoleUser.isNotEmpty()) Text(stringResource(R.string.screen_in_use_by, prompt.consoleUser)) },
                confirmButton = {
                    Column(horizontalAlignment = Alignment.End) {
                        if (prompt.allowsOwnSession) TextButton(onClick = { session.answerPrompt(SessionChoice.OWN_SESSION) }) {
                            Text(stringResource(R.string.screen_own_session))
                        }
                        if (prompt.allowsShareConsole) TextButton(onClick = { session.answerPrompt(SessionChoice.SHARE_CONSOLE) }) {
                            Text(stringResource(R.string.screen_ask_to_share))
                        }
                        TextButton(onClick = { session.answerPrompt(SessionChoice.CANCEL); onClose() }) { Text(stringResource(R.string.screen_cancel)) }
                    }
                },
            )
        }
        else -> Unit
    }
}

/** The floating control menu (OSS's toolbar and its "More" menu, in one panel). */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ControlMenu(
    session: SessionModel,
    hub: ScreenHub,
    touchMode: TouchMode,
    keyboardUp: Boolean,
    pictureFitted: Boolean,
    onKeyboard: () -> Unit,
    onFit: (Boolean) -> Unit,
    onDismiss: () -> Unit,
    onDisconnect: () -> Unit,
) {
    val controlling = session.isControlling
    Box(Modifier.fillMaxSize().clickable(interactionSource = null, indication = null, onClick = onDismiss)) {
        Surface(
            Modifier.align(Alignment.TopCenter).safeDrawingPadding().padding(top = 44.dp, start = 12.dp, end = 12.dp)
                .widthIn(max = 460.dp).heightIn(max = 560.dp).clickable(interactionSource = null, indication = null) {},
            shape = RoundedCornerShape(24.dp),
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.96f),
            tonalElevation = 6.dp,
            shadowElevation = 12.dp,
        ) {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.horizontalScroll(rememberScrollState())) {
                    MenuButton(if (keyboardUp) Icons.Outlined.KeyboardHide else Icons.Outlined.Keyboard,
                        stringResource(if (keyboardUp) R.string.screen_hide_keyboard else R.string.screen_show_keyboard), controlling, onKeyboard)
                    if (!session.picturesFollowWindow) {
                        if (pictureFitted) MenuButton(Icons.Outlined.Fullscreen, stringResource(R.string.screen_actual_size), true) { onFit(false) }
                        else MenuButton(Icons.Outlined.FullscreenExit, stringResource(R.string.screen_zoom_to_fit), true) { onFit(true) }
                    }
                    MenuButton(Icons.AutoMirrored.Outlined.Logout, stringResource(R.string.screen_disconnect), true, onDisconnect)
                    MenuButton(Icons.Outlined.Close, stringResource(R.string.screen_done), true, onDismiss)
                }
                HorizontalDivider()
                SectionTitle(stringResource(R.string.screen_controls))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Chip(stringResource(R.string.screen_mission_control), controlling) { session.perform(SystemCommand.MISSION_CONTROL); onDismiss() }
                    Chip(stringResource(R.string.screen_app_windows), controlling) { session.perform(SystemCommand.APP_WINDOWS); onDismiss() }
                    Chip(stringResource(R.string.screen_desktop), controlling) { session.perform(SystemCommand.SHOW_DESKTOP); onDismiss() }
                    if (session.canPerform(SystemCommand.LAUNCHPAD)) {
                        Chip(stringResource(R.string.screen_apps), controlling) { session.perform(SystemCommand.LAUNCHPAD); onDismiss() }
                    }
                    Chip(stringResource(R.string.screen_app_switcher), controlling) { session.keyboard.sendChord(KeyChord.APP_SWITCHER); onDismiss() }
                    Chip(stringResource(R.string.screen_spotlight), controlling) { session.keyboard.sendChord(KeyChord.SPOTLIGHT); onDismiss() }
                    Chip(stringResource(R.string.screen_force_quit), controlling) { session.keyboard.sendChord(KeyChord.FORCE_QUIT); onDismiss() }
                    Chip(stringResource(R.string.screen_screenshot), controlling) { session.keyboard.sendChord(KeyChord.SCREENSHOT); onDismiss() }
                }
                SectionTitle(stringResource(R.string.screen_function_keys))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Chip("esc", controlling) { session.keyboard.typeKey(MacKey.ESCAPE) }
                    for (n in 1..12) Chip("F$n", controlling) { session.keyboard.typeKey(MacKey.function(n)) }
                    Chip("⌦", controlling) { session.keyboard.typeKey(MacKey.FORWARD_DELETE) }
                    Chip("⇞", controlling) { session.keyboard.typeKey(MacKey.PAGE_UP) }
                    Chip("⇟", controlling) { session.keyboard.typeKey(MacKey.PAGE_DOWN) }
                    Chip("↖", controlling) { session.keyboard.typeKey(MacKey.HOME) }
                    Chip("↘", controlling) { session.keyboard.typeKey(MacKey.END) }
                }
                SectionTitle(stringResource(R.string.screen_touch))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(touchMode == TouchMode.TRACKPAD, { hub.store.setTouchMode(TouchMode.TRACKPAD) }, { Text(stringResource(R.string.screen_touch_trackpad)) })
                    FilterChip(touchMode == TouchMode.DIRECT, { hub.store.setTouchMode(TouchMode.DIRECT) }, { Text(stringResource(R.string.screen_touch_direct)) })
                }
                if (session.offersResolution) {
                    SectionTitle(stringResource(R.string.screen_resolution))
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        for (scale in DisplayMode.resolutionScales) {
                            FilterChip(session.resolutionScale == scale, { session.changeResolutionScale(scale) },
                                { Text(DisplayMode.resolutionTitle(scale, stringResource(R.string.screen_native))) }, enabled = controlling)
                        }
                    }
                    Text(stringResource(R.string.screen_resolution_footer), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (!session.usesHighPerformance && session.server?.quality != false) {
                    SectionTitle(stringResource(R.string.screen_quality))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(!session.fullQuality, { session.changeFullQuality(false) }, { Text(stringResource(R.string.screen_quality_adaptive)) })
                        FilterChip(session.fullQuality, { session.changeFullQuality(true) }, { Text(stringResource(R.string.screen_quality_full)) })
                    }
                }
                if (session.server?.clipboard != false) {
                    SectionTitle(stringResource(R.string.screen_clipboard))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.screen_sync_clipboard), Modifier.weight(1f))
                        Switch(session.clipboardSharing, { session.changeClipboardSharing(it) })
                    }
                    if (!session.clipboardSharing) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Chip(stringResource(R.string.screen_receive_clipboard), session.server?.clipboardRequest == true) {
                                session.receiveClipboardFromMac(); onDismiss()
                            }
                            Chip(stringResource(R.string.screen_send_clipboard), controlling) { session.sendClipboardToMac(); onDismiss() }
                        }
                    }
                }
                Text(
                    stringResource(if (session.usesHighPerformance) R.string.screen_mode_high_performance else R.string.screen_mode_standard),
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.SemiBold)
}

@Composable
private fun MenuButton(icon: ImageVector, label: String, enabled: Boolean, onClick: () -> Unit) {
    Surface(onClick = onClick, enabled = enabled, shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.secondaryContainer) {
        Column(Modifier.padding(horizontal = 12.dp, vertical = 8.dp).widthIn(min = 64.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(icon, null)
            Text(label, style = MaterialTheme.typography.labelSmall, textAlign = TextAlign.Center)
        }
    }
}

@Composable
private fun Chip(label: String, enabled: Boolean, onClick: () -> Unit) {
    FilterChip(selected = false, onClick = onClick, label = { Text(label) }, enabled = enabled)
}

/**
 * The key row above the on-screen keyboard (OSS's KeyboardAccessoryBar): Escape, Tab, the modifiers (a tap: for the
 * next key; a long press: held until tapped again), the arrows, and hiding the keyboard.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun KeyRow(session: SessionModel, modifier: Modifier, hide: () -> Unit) {
    @Suppress("UNUSED_EXPRESSION") session.modifiersVersion
    val keyboard = session.keyboard
    Surface(modifier.fillMaxWidth(), color = MaterialTheme.colorScheme.surfaceContainerHigh, tonalElevation = 3.dp) {
        Row(
            Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 6.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            KeyCap("esc") { keyboard.typeKey(MacKey.ESCAPE) }
            KeyCap("⇥") { keyboard.typeKey(MacKey.TAB) }
            for (modifierKey in listOf(ModifierKey.CONTROL, ModifierKey.OPTION, ModifierKey.COMMAND, ModifierKey.SHIFT)) {
                val locked = modifierKey in keyboard.locked
                val sticky = modifierKey in keyboard.sticky
                KeyCap(
                    modifierKey.symbol,
                    highlighted = sticky || locked,
                    underlined = locked,
                    onLongClick = { keyboard.setLocked(modifierKey, !locked) },
                ) { keyboard.toggleSticky(modifierKey) }
            }
            KeyCap("←") { keyboard.typeKey(MacKey.LEFT) }
            KeyCap("↑") { keyboard.typeKey(MacKey.UP) }
            KeyCap("↓") { keyboard.typeKey(MacKey.DOWN) }
            KeyCap("→") { keyboard.typeKey(MacKey.RIGHT) }
            Surface(onClick = hide, shape = RoundedCornerShape(8.dp), color = Color.Transparent) {
                Icon(Icons.Outlined.KeyboardHide, stringResource(R.string.screen_hide_keyboard), Modifier.padding(8.dp))
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun KeyCap(label: String, highlighted: Boolean = false, underlined: Boolean = false, onLongClick: (() -> Unit)? = null, onClick: () -> Unit) {
    val background = if (highlighted) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surface
    val foreground = if (highlighted) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface
    Box(
        Modifier.clip(RoundedCornerShape(8.dp)).background(background)
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(horizontal = 12.dp, vertical = 8.dp).wrapContentSize(),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(label, color = foreground, fontSize = 17.sp)
            if (underlined) Box(Modifier.size(width = 14.dp, height = 2.dp).background(foreground))
        }
    }
}

/** The help request over a running screen: in full for 3 seconds and while the menu is open, then only "Done". */
@Composable
private fun HelpPill(request: HelpRequest, show: (() -> Unit)?, menuOpen: Boolean, done: () -> Unit) {
    var fresh by remember(request.id) { mutableStateOf(true) }
    LaunchedEffect(request.id) {
        delay(3000)
        fresh = false
    }
    val full = fresh || menuOpen
    Box(Modifier.fillMaxSize().safeDrawingPadding().padding(top = if (full && !menuOpen) 48.dp else 4.dp, start = 12.dp, end = 12.dp)) {
        Surface(
            Modifier.align(if (full) Alignment.TopCenter else Alignment.TopEnd).widthIn(max = 460.dp),
            shape = RoundedCornerShape(18.dp),
            color = MaterialTheme.colorScheme.tertiaryContainer.copy(alpha = 0.95f),
        ) {
            Row(Modifier.padding(horizontal = if (full) 12.dp else 4.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (full) {
                    Icon(Icons.Outlined.PanTool, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.tertiary)
                    Text(request.purpose.ifEmpty { stringResource(R.string.screen_agent_asks_for_help) },
                        style = MaterialTheme.typography.bodySmall, maxLines = 3, modifier = Modifier.weight(1f, fill = false))
                    show?.let { TextButton(onClick = it) { Text(stringResource(R.string.screen_show)) } }
                }
                TextButton(onClick = done) { Text(stringResource(R.string.screen_done), fontWeight = FontWeight.SemiBold) }
            }
        }
    }
}
