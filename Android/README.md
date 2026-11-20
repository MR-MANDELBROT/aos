# aOS for Android

The Android version of the aOS companion app (the iPhone app is `iOS/`, its design `Docs/COMPANION.md`, what the Mac
side must match `iOS/NOTES.md`). This is the foundation: the protocol, pairing, keys, SSH, the companion client, the
connection to the Mac, stores and the state the UI binds to. The terminal, the UI and the screen build on it.

## Layout

Since 2026-11-19 the app is split so the desktop app (`desktop/`, Windows and Linux) shares everything it can with
Android: `:core` (protocol), `:shared` (the app without UI, plain JVM), `shared-ui/` (the Compose UI, compiled into
both apps), and the two apps with their platform pieces.

```
Android/
  settings.gradle.kts, build.gradle.kts, gradle/libs.versions.toml, gradle.properties, gradlew
  core/                      :core, pure Kotlin (JVM, kotlinx-serialization), no Android
    src/main/kotlin/dev/marquart/aos/core/
      Bytes.kt, P256.kt, SSHKeyFormat.kt, PairingLink.kt, Pairing.kt, Json.kt, CompanionProtocol.kt, ScreenSeal.kt,
      MacStatus.kt, Chats.kt, ConnectionPlan.kt, TerminalAttach.kt     (see the files; unchanged by the split)
    src/test/                the iOS unit tests with the same vectors
  shared/                    :shared, the app without UI, plain Kotlin on the JVM (Android and the desktop use it)
    src/main/kotlin/dev/marquart/aos/
      ssh/                   SshConnector + SshConnection (Apache MINA SSHD), SessionChannel, LocalForwarder,
                             PairingClient, DeviceKeyAgent (the key as an in-process agent)
      companion/             CompanionClient, CompanionTransport/ExecTransport, CompanionError, MockCompanionServer
      connection/            MacConnection; the platform interfaces (Network.kt): TailnetDialer, NetworkMonitor,
                             ServiceDiscovery (+ NoTailnet, NoDiscovery, FixedNetworkMonitor)
      keys/Keys.kt           DeviceKey, KeyStorage (Android's, Windows' TPM/software, Linux' file), KeyProvider, MemoryKeys
      store/Stores.kt        MacStore, SettingsStore (AppSettings), SecretStore, the in-memory ones
      model/AppModel.kt      the state holder the UI binds to
      terminal/              MacTerminal (the session state machine) over TerminalScreen (the emulator interface:
                             Termux on Android, JediTerm on the desktop), TerminalKeys (pure input logic),
                             MacSessionList (`term list`), TerminalDemo
      screen/                RemoteSession (the screen engine's interface), Routing, Keyboard, Keys (keysyms, MacKey),
                             Gestures, VideoStream (parameter sets, Annex B), SampledPixels
    src/testFixtures/        the in-process Mac for tests (TestSshServer, FakeTermSessions, FakePairingListener,
                             waitUntil, testKey): used by :shared's, :app's and :desktop's tests
    src/test/                SSH, companion, connection, model, pairing, terminal keys, routing, gestures, video, live
  shared-ui/                 the Compose UI both apps compile in (a source folder, not a Gradle module)
    src/main/kotlin/dev/marquart/aos/
      ui/                    AosRoot (tabs: bar, rail or drawer by the window), AosUi, Txt, Errors, layout/ (WindowLayout:
                             the large-screen decisions; Panes: TwoPane, Columns, AdaptiveSheet, contextClick),
                             components/, theme/, overview/, signin/ (sheets), settings/ (SettingsSlots: terminal,
                             screen, device), pairing/PairingScreen (camera through Platform.pairingScanner), lock/AppLock,
                             tailnet/TailnetControl, demo/Demo (sample data; Android's intent and the desktop's
                             arguments set DemoOptions)
      ui/platform/Platform.kt   what the UI asks of the device (see "Shared UI" below)
      screen/                SessionModel (a screen session's state and input), ScreenController + ScreenHub,
                             ScreenStore (KeyValues), DemoScreenServer (RFB in the app), ScreenTexts
    src/main/res/            the UI's strings (values, values-de: strings_ui, strings_terminal, strings_screen,
                             app_name), the icon art, the license texts: Android's resources, the desktop's tables
    src/test/                UI text, routine schedule, app lock tests (run in both apps' tests)
  app/                       :app, Android (minSdk 29, targetSdk 36, compileSdk 37); adds shared-ui's sources and res
    src/main/kotlin/dev/marquart/aos/
      ui/platform/           AndroidPlatform (Custom Tabs, clipboard, biometrics, notification permission, back,
                             the QR camera), Resources.kt (Android's side of the shared declarations)
      ui/lock/Biometrics, ui/notify/RequestNotifier, ui/pairing/QrScanner + CameraBox, ui/tabs/TabSlots,
      ui/demo/DemoIntent, ui/layout/WindowLayouts (size class and fold), ui/keys/Shortcuts     Android only
      keys/AndroidKeys.kt    AndroidKeystoreKeys (StrongBox, else TEE), KeystoreSigner, KeystoreOrMemoryKeys
      store/AndroidStores.kt DataStore stores, KeystoreSecretStore
      connection/            AndroidNetworkMonitor, NsdServiceDiscovery
      terminal/              TermuxScreen (Termux's emulator as TerminalScreen), TerminalTab, TerminalHost,
                             TerminalKeyBar, TerminalController, TerminalKeepAliveService, TerminalSettings
      screen/                ScreenPlatform.kt (Android's side of the shared screen code: Bitmap, Handler, MediaCodec's
                             VideoDecoder in Video.kt), ScreenTab, SessionScreen, RemoteScreenView, ScreenRenderer
                             (GLES), AndroidKeys, MacLoginLock, ScreenSettingsSection
    src/tailnet|notailnet, src/libsharing|nolibsharing   with or without third_party/aosgo/aosgo.aar
  desktop/                   :desktop, Windows and Linux (Compose Multiplatform 1.12.2, JVM 17+; runs on macOS too)
    see "The desktop app" below
  third_party/               aosgo/ (Android's Go library), aosgo-desktop/ (the desktop's, JNA binding), READMEs
Tools/android.sh             runs ./gradlew here with JAVA_HOME and ANDROID_HOME set (repo root Tools/)
Tools/desktop.sh             the desktop packages (repo root Tools/)
```

### Shared UI: how one source compiles for both

`shared-ui/src/main/kotlin` is added as a source folder to `:app` and `:desktop` (saldo's proven setup). What differs:

1. `ui.platform.Platform` (interface, set at start: `AndroidPlatform` in AosApp, `DesktopPlatform` in desktop Main):
   web pages, clipboard, share, the person's confirmation (`confirmPresence`: biometrics, Windows Hello, polkit, PAM),
   notifications, back, "is the app active", the pairing camera.
2. Files with the same declarations in both apps, in the same package (`expect`/`actual` without the keywords; a
   signature that differs breaks the other app's build): `ui/platform/Resources.kt` (`PlatformContext`,
   `platformContext()`, `stringResource`, `pluralStringResource`, `painterResource`, `text/quantityText/rawText/locale/
   relativeTime`), `ui/tabs/TabSlots.kt` (the Terminal and Screen tabs, settings slots), `screen/ScreenPlatform.kt`
   (`PlatformBitmap`, `VideoSurface`, `VideoDecoder`/`DecoderSupport`, `postToMain`, `ScreenLog`, `ScreenImages`,
   `DemoPicture`).
3. `R`: Android's generated one; on the desktop `desktop/build.gradle.kts` (`generateAosResources`) reads the same XML
   (shared-ui/src/main/res, then desktop/src/main/res, which wins: strings_desktop.xml and strings_wording.xml with
   "this computer" where Android says "this phone") and writes `dev.marquart.aos.R` and string tables.

Strings stay in Android's XML (English `values`, German `values-de`); the desktop picks German when the system's
language is German (`AOS_LANG=en|de` or `--lang=` to choose).

## Large screens: tablets, foldables, desktop windows

The same app (`dev.marquart.aos`) adapts to its window; there is no tablet app. The decisions are in one place,
`shared-ui/.../ui/layout/WindowLayout.kt` (pure Kotlin, `WindowLayoutTests`), and the views only ask
`LocalWindowLayout.current`:

| Window (dp) | Tabs | Pages |
|---|---|---|
| compact width (< 600): a phone, a third of a tablet in split screen | bar at the bottom | one pane, sheets from the bottom |
| medium (600 to 839): a tablet upright, half a tablet | rail at the side | one pane, Overview in two columns, questions as a dialog |
| expanded (840 to 1199): an unfolded foldable, a small tablet on its side | rail | list and detail side by side |
| large (1200 and more): a tablet on its side, a desktop window | drawer that stays open (with the Mac and its state) | list and detail, Overview in two or three columns |
| compact height (< 480): a phone on its side | rail, never the drawer | one pane, sheets from the bottom |

- **Where the size comes from.** Android: `app/.../ui/layout/WindowLayouts.kt` (`rememberWindowLayout`): material3-adaptive's
  `currentWindowAdaptiveInfo()` (Jetpack's WindowSizeClass of the window, so split screen, freeform and desktop windows
  count as what they are) and `WindowInfoTracker`'s FoldingFeature; MainActivity passes it to `AosRoot(ui, window = ...)`.
  The desktop: `AosRoot(ui, rail = true)` measures its window and never goes below the rail.
- **List and detail** (`TwoPane` in `ui/layout/Panes.kt`): Chats (the list, the chosen chat or the first), Routines (the
  list, the routine being changed), Apps (the phone's connection, the installs), Settings (the list, the chosen page or
  the paired Mac's; a page it pushes, a license, replaces it there with a way back) and, on Android, the Terminal (the
  Mac's sessions beside the terminal). The row shown beside the list is marked. Back leaves the pair, not the detail.
- **Overview**: `Columns` puts the cards side by side (the Mac and what is where; the workspace and aOS; requests across
  the top). Forms keep a readable width in the middle (`PageColumn`, 720 dp).
- **Sheets** (`AdaptiveSheet`): the sign-in and approval questions and the terminal's and the screen's settings come from
  the bottom edge on a phone and are a dialog in the middle of a large window (560 dp wide).
- **Foldables.** A fold nothing should straddle (half opened, or a hinge that hides pixels) splits the layout: upright
  like a book, `TwoPane` and the Overview's two columns go to its sides; standing on its lower half (tabletop), the
  terminal is above the fold and the key bar below it, the screen session shows the picture above and the key row and
  controls below, and a dialog stays above the fold. A flat fold changes nothing.
- **State.** MainActivity handles the configuration changes of size, shape, orientation, keyboard and light/dark itself
  (`configChanges`), so turning, resizing, folding and plugging a keyboard in don't restart it: the terminal's view and a
  running screen session stay. One place holds the tab's content whatever the navigation is, the terminal and the
  routine editor are movable content (they keep their state when they move beside the list), scroll positions belong
  to the page (`AosUi.scroll`, kept in the activity's ViewModel), and what was chosen or typed in a question lives
  outside the sheet or dialog that shows it. Language, font scale and density still restart the activity.
- **Keyboard** (`app/.../ui/keys/Shortcuts.kt`, listed in the system's shortcuts helper through
  `onProvideKeyboardShortcuts`): Ctrl+1 to 4 the tabs, Ctrl+Shift+T a new terminal session, Ctrl+Shift+V paste into
  the terminal, Ctrl+Shift+C copy its screen, Ctrl+Shift+plus and minus its text size. Ctrl+letter stays the shell's.
  A hardware keyboard types into the terminal (and onto the Mac in a screen session) whatever was clicked last on that
  screen: Tab, Esc and the arrows don't move the focus around. For that the terminal's and the picture's views keep
  the focus while they are on screen (they take it back after a click on a key of the bar, the title bar or the list;
  without it Android uses the next Tab or arrow to place the focus and swallows it), a key that still finds them
  unfocused is handed to them (`MainActivity.dispatchKeyEvent`, the session window's callback), and Android's default
  focus highlight (a gray tint over the focused view once a keyboard is used) is off for both. A screen session is a
  window of its own and gets every key for the Mac; while its menu is open the keys are the menu's.
- **Mouse and trackpad**: hover states are Material's; a secondary click opens the menus a long press opens
  (`Modifier.contextClick`: chats, routines, terminal sessions, the Mac's screen card); the wheel scrolls lists, the
  terminal's scrollback and the Mac. Text dragged from another window onto the terminal is pasted (with the usual
  question before several lines run).
- **Wording.** With a smallest width of 600 dp and more the texts say "this device" instead of "this phone"
  (`app/src/main/res/values-sw600dp`, `values-de-sw600dp`; `LargeScreenTextTests` keeps them in step with the shared texts).
- **Manifest**: resizable, no fixed orientation or aspect ratio, touchscreen and camera not required (Chromebooks). On
  a phone a screen session still turns to a Mac screen that keeps its own shape; on anything larger it never asks for
  an orientation.

Screenshots (German, light and dark, both orientations): `build/android-tablet-screenshots` (the debug demo, e.g.
`--es aos.demo.sheet terminal-session`, `screen-session`; the demo's terminal shows what is typed in caret notation,
`^I` for Tab, `^[` for Esc, so a check sees which keys arrived), with `live/` (keys, rotation, resizing, split screen,
freeform, the shortcuts helper) and `foldable/` (book, tabletop, closed and open again).

Checked on the emulator on 2026-11-20 (API 36, google_apis): a Pixel Tablet AVD (`avdmanager create avd -n aos_tablet
-k "system-images;android-36;google_apis;arm64-v8a" -d pixel_tablet`, `hw.keyboard=yes`) and a Pixel Fold AVD (`-d
pixel_fold`; postures with `adb shell cmd device_state state 0|1|2` for closed, half opened, opened, and
`settings put system user_rotation 1` to stand it on its lower half; `screencap -d <display id>` there). Turning,
`wm size` through every size class, split screen (`dumpsys activity service SystemUIService WMShell splitscreen
moveToSideStage <task> 1`), a freeform window (`am start --windowingMode 5`, `am task resize`), folding onto the outer
screen and back: one `onCreate` each time, the demo's terminal and screen session kept what was typed.

## Build and test

```sh
Tools/android.sh :core:test                    # 73 tests
Tools/android.sh :shared:test                  # 116 tests (+ LiveMacTests, skipped without a link)
Tools/android.sh :app:testDebugUnitTest        # 92 tests (MacTerminalTests with Termux, screen, UI texts, the large-screen
                                               #   layout, shortcuts and wording; + LiveTerminalTests)
Tools/android.sh :app:assembleDebug            # app/build/outputs/apk/debug/app-debug.apk
Tools/android.sh :desktop:test                 # 52 tests (desktop pieces, JediTerm terminal, the Go library's screen
                                               #   session on this Mac, the shared UI tests again; + LiveDesktopTests)
Tools/android.sh :desktop:runDesktop -Paos.args="--demo"        # the desktop app on this Mac with sample data
Tools/android.sh :desktop:runDesktop -Paos.args="--shots=$PWD/../build/desktop-screenshots"   # the screenshots
Tools/desktop.sh                               # the desktop packages (see "The desktop app")
Tools/android.sh --stop                        # the daemon, when done (the Mac is short of memory)
```

`gradle.properties` keeps Gradle small (`-Xmx2g`, no parallel work, the Kotlin compiler in-process). After moving
files, Android's built-in Kotlin compile sometimes keeps old test classes: `--rerun` on the compile task fixes it.

The Go library: `app/build.gradle.kts` takes `third_party/aosgo/aosgo.aar` when it is there (built by
`Tools/go-android.sh`, see `third_party/README.md`) and then compiles `src/tailnet`; without it `src/notailnet`, and
everything else builds the same. `-Paos.withoutGo=true` builds as if it were missing. ABIs: arm64-v8a and x86_64 (what
the aar has). The aar is GPL-3.0 (libsharing), and so is an app that ships it: see `third_party/README.md`. The
desktop does the same with `third_party/aosgo-desktop/kotlin/AosGo.kt` (src/aosgo or src/noaosgo).

### Live check against the real Mac side

`LiveMacTests` (:shared), `LiveTerminalTests` (:app) and `LiveDesktopTests` (:desktop: key files, file stores, JmDNS,
the polling network monitor, a held session in JediTerm) pair with aOS's real pairing listener and use a throwaway
OpenSSH on 127.0.0.1:2222 with its own `authorized_keys` (nothing of `~/.ssh` is touched), the real `aos-companion`
and aOS:

```sh
L=<an empty folder, 0700>
ssh-keygen -q -t ed25519 -N "" -f $L/host_ed25519 && touch $L/authorized_keys && chmod 600 $L/authorized_keys
# sshd_config: Port 2222, ListenAddress 127.0.0.1, HostKey $L/host_ed25519, AuthorizedKeysFile $L/authorized_keys,
# PasswordAuthentication no, KbdInteractiveAuthentication no, UsePAM no, StrictModes no, PidFile $L/sshd.pid
/usr/sbin/sshd -f $L/sshd_config
aosctl pair-test $L/authorized_keys 2222 "$(ssh-keygen -lf $L/host_ed25519.pub | awk '{print $2}')" 127.0.0.1 \
  /Applications/aOS.app/Contents/MacOS/aos-companion          # prints LINK aos-pair://... (one link per test run)
Tools/android.sh :shared:test --tests '*LiveMacTests*' -Paos.live.link='aos-pair://...'
Tools/android.sh :app:testDebugUnitTest --tests '*LiveTerminalTests*' -Paos.live.link='aos-pair://...'
Tools/android.sh :desktop:test --tests '*LiveDesktopTests*' -Paos.live.link='aos-pair://...'
kill $(cat $L/sshd.pid)
security delete-generic-password -s dev.marquart.aos.phonekeys -a <the phone id the test printed>
```

(`aosctl` isn't in the installed app; `AOSKit/.build/out/Products/Debug/aosctl` is a built one.) `pair-test` keeps
the test phone's signing key in the login keychain; the last line removes it.

## The interfaces later agents plug into

All of these are in `shared/src/main/kotlin/dev/marquart/aos/` (the UI in `shared-ui/`). `AosApp.graph` (`AppGraph`) holds one of each on Android, `DesktopGraph` on the desktop.

### The UI: `model.AppModel`

```kotlin
class AppModel {
    val macs: StateFlow<List<PairedMac>>                 // first = the active Mac
    val connection: StateFlow<MacConnection?>            // its own flows: see below
    val connectionState: StateFlow<MacConnection.State>  // Idle, Connecting, Connected(host, route),
                                                         // Unreachable(message, nextAttempt), NeedsAttention(message)
    val companionState: StateFlow<MacConnection.CompanionState>  // NotStarted, Starting, Ready, Unavailable(msg), NeedsPairing
    val keyError: StateFlow<String?>; val deviceName: StateFlow<String>; val loaded: StateFlow<Boolean>
    val questions: StateFlow<List<Question>>             // Question.SignIn(request) | Question.Approval(request), in order
    val presentedQuestion: StateFlow<Question?>          // the sheet
    val signInResults / approvalResults: StateFlow<Map<String, ...Result>>   // for the sheet still open
    val helpRequests: StateFlow<List<HelpRequest>>; val activeHelp: StateFlow<HelpRequest?>   // open the Screen tab
    val signIns, approvals, presentedSignIn, waitingCount, activeMac, isPaired

    suspend fun load()
    suspend fun pair(link: PairingLink, progress: (PairingStep) -> Unit = {}): PairedMac
    suspend fun unpair(mac: PairedMac); suspend fun makeActive(mac: PairedMac); suspend fun setDeviceName(name: String)
    fun present(question: Question); fun closeQuestionSheet()   // "Later": stays in the overview, doesn't pop up again
    fun showHelp(request: HelpRequest); suspend fun finishHelp(request: HelpRequest)
    fun isExpired(question: Question): Boolean
    fun onForeground(); fun onBackground()               // AosApp calls these (25 s grace, then the connection goes)
}
```

Answers go through the connection (`model.connection.value`), after the UI's own biometric prompt:
`answerSignIn(request, host, login)` (a Bitwarden login), `answerSignIn(request, host, username, password, totp)`
(another password app), `answerSignInCode`, `declineSignIn`, `answerApproval(request, allowed)`, `helpDone`.
English texts in the code (`MacRefusal.text`, `MacConnection.message`, error messages) are fallbacks; the UI words the
codes itself (`MacRefusal.code`, `CompanionError`, `SshConnectException`, `PairingClient.Failure`) in German and English.

### `connection.MacConnection` (Overview, terminal, screen)

```kotlin
val mac, state, companionState, hello, workspace, macStatus, chats, macAppProblem, ssh, companion,
    workspaceOperation, workspaceTimeout, sleepingSince: StateFlow<...>
val workspaceState: String?        // "starting"/"closing" while an operation from here is under way
val macStatusUnsupported, chatsSupported, isConnected, connectedRoute, phoneId
fun start(); fun stop(); fun retryNow(); fun probe(); fun close()
suspend fun perform(action: MacAction, value: String? = null): MacActionResult   // throws MacRefusal / CompanionError
suspend fun refreshMacStatus(); refreshChats(); refreshStatus()
suspend fun screenEndpoint(target: ScreenTarget): ScreenEndpoint   // workspace: sealed login (ScreenSeal)
suspend fun display(size: String): Pair<Int, Int>                  // "WIDTHxHEIGHT@SCALE" or "reset", every 20 s
suspend fun termSessions(): List<MacTermSession>?; suspend fun endTermSession(id: String): Boolean
suspend fun awaitReady(timeoutMillis: Long): Boolean
```

Polling (`mac.status` every 15 s on the Overview, chats every 15 s on their page) is the UI's, as on the iPhone; the
connection does the 25 s heartbeat, the 3 s polls while the workspace starts or closes, the 2 s and 7 s chat refresh
after a chat action, and the "Mac sleeping" rule (closed 0.5 s after the Mac's `after`, no attempt for 20 s more).

### The terminal: `ssh.SshConnection` and `ssh.SessionChannel`

```kotlin
val ssh = connection.ssh.value ?: ...                        // the live connection; it changes on reconnects
val command = TermAttach.attach(mac.companionPath, id, have, client = connection.phoneId)
val channel = ssh.terminal(command, term = "xterm-256color", columns, rows)   // PTY + exec
channel.output: Flow<ByteArray>      // one collector; ends normally, or with SessionChannel.Failure.Exited(status, text)
channel.write(bytes); channel.resize(columns, rows); channel.closeInput(); channel.close()
TermNoteFilter().feed(chunk)         // Piece.Bytes for the terminal, Piece.Note(TermNote.Start | End)
ssh.shell(term, columns, rows)       // a plain login shell (aOS without `term`: exit status 2)
ssh.run(command)                     // term list / term end (or connection.termSessions / endTermSession)
```

Count the output bytes after the start note and attach again with `--have` (Docs/COMPANION.md, "Terminal sessions");
only listen to the newest channel.

### The screen: `ssh.LocalForwarder`

```kotlin
val endpoint = connection.screenEndpoint(ScreenTarget.WORKSPACE)     // host, port, username, password (sealed)
val forwarder = LocalForwarder(endpoint.host, endpoint.port) { connection.ssh.value ?: throw CompanionError.Closed }
val port = forwarder.start()          // 127.0.0.1:port for libsharing's SessionOptions.host/port
forwarder.stop()
```

Each new local connection asks for the current SSH connection (so it survives a reconnect). `forwarder.lastError` says
why the last one couldn't open. For the direct path (high performance, UDP): `connection.connectedRoute` and
`ssh.address` tell how the Mac was reached (`SSHRoute.Host` on the same network or the Tailscale app's VPN).

### aOS's own Tailscale: `connection.TailnetDialer`

```kotlin
interface TailnetDialer {
    val isSetUp: Boolean; val isRunning: Boolean; val ready: Flow<Unit>
    fun startIfSetUp()
    suspend fun dial(host: String, port: Int, timeoutMillis: Long): TailnetConnection   // input/output streams
}
```

`SshConnector` uses it for `SSHRoute.Tailnet` (ConnectionPlan puts those after the same network when `isRunning`):
the stream is spliced to a one-shot 127.0.0.1 listener MINA connects to; the Mac's host key is checked as on any route.
`src/tailnet/.../Tailnets.kt` has `EmbeddedTailnet` on tailnetkit (`Node.dial` with the client port bound first);
signing in (`state.authURL()` in a Custom Tab while `needsLogin()`), Settings > Connection and signing out are the UI's
(`setUp()`, `state`, `signOut()`).

### Platform interfaces

`NetworkMonitor` (path changes, `tailscaleVpnActive()`), `ServiceDiscovery` (NSD: `_aos-pair._tcp`, `_ssh._tcp`),
`KeyProvider` (the two keys), `MacStore`, `SettingsStore`, `SecretStore` (e.g. the Mac's screen login, encrypted with
a Keystore AES key; biometric gating is the UI's). Each has an in-memory version for tests.

## The terminal (dev.marquart.aos.terminal)

The iPhone's terminal (iOS/NOTES.md, "The terminal"; Docs/COMPANION.md, "Terminal sessions") on Android, with the same
behavior and wording. Entry points for the UI:

```kotlin
@Composable fun TerminalTab(model: AppModel, modifier: Modifier = Modifier)   // the tab: session list and terminal
@Composable fun TerminalSettingsSection(modifier: Modifier = Modifier)        // Settings > Terminal (no arguments)
@Composable fun terminalIsShown(model: AppModel): Boolean                     // a terminal is on screen (hide the tab bar)
```

`TerminalTab` also handles `model.terminalRequest` ("Open Terminal" from the Overview: a new session, shown) and the
notification's tap (`model.selectTab(TERMINAL)` and the terminal shown). It works with the demo's own model as well
(`model.demo`: sample sessions and output, no service, no permission prompt).

**Emulator and view.** Termux's terminal-emulator and terminal-view 0.118.3 (Apache-2.0, JitPack, only that group from
there: settings.gradle.kts). Termux's `TerminalSession` is final and runs a local process through JNI, so
`com.termux.terminal.RemoteTerminalSessions` (the only file in Termux's package, it needs package access) makes a
session that runs nothing: its emulator is the one `MacTerminal` feeds from the SSH channel, it is there before the view
asks (so no process is ever started), the pty descriptor is -1 (the view's window size ioctl does nothing), and what the
view types goes through the session's input queue to `MacTerminal.send`. Size changes reach the Mac through
`TerminalViewClient.onEmulatorSet` (`channel.resize`). Scrollback 2000 lines; colors follow light and dark; pinch
changes the font size by a point per step (8 to 28, "13 pt · 80 × 24"); a long press on a web address offers Open Link
and Copy Link, anywhere else Termux selects (Copy, Paste, More: Copy Screen, Copy Last Output); pasting asks first
when lines would run (no bracketed paste) and strips control characters (`PasteEncoder`).

**Sessions.** `MacTerminal` is TerminalSession.swift's state machine: `term attach --id --have --client <phone id>`,
bytes counted after the start note, Reconnecting while the connection is gone (it attaches again by itself, polling the
app's connection every 0.4 s), "Mac sleeping" when `sleepingSince` is set, taken/replaced/exited/ended/lost, Open It
Here / New Session, one attach at a time, a round counter that drops the output of older channels, the session id per
Mac in `TerminalSettings` (SharedPreferences "terminal"), status 2 and 127 a plain shell with a note, status 1 the Mac's
own text without retrying. It runs on the main thread (the emulator is read while drawing); one `MacTerminal` per Mac
lives in `TerminalController` for the process, so the screen survives leaving the tab.

**Keys.** `TerminalKeyBar` (Compose): the iPhone's row (KeyBarLayout: arrows in the middle, equal keys of at least
46 dp, snapping), swipe pad or four arrow keys (setting), Esc, Ctrl, Tab, Alt, Shift-Tab, paste, Home, End, PgUp, PgDn,
forward delete, F1 to F12, sticky / locked / held modifiers (`StickyModifiers`, also for the keyboard's letters,
Backspace and Return), repeat while held, haptics. Swiping on the terminal sends arrows with the iOS rule
(`TerminalSwipe`: sideways always, up and down only as a quick flick at the end, repeat while held, never for two
fingers, while selecting, or within 24 dp of either screen edge, where Android's back gesture lives). The key bar shows
whenever the terminal does (not only with the on-screen keyboard: the pad and Esc help with a hardware keyboard too).

### The terminal in the background

This replaces the iPhone's Live Activity and its location trick. While a terminal is open (connecting, connected or
reconnecting) and "Keep connected in the background" is on (default), `TerminalController` runs
`TerminalKeepAliveService`, a foreground service of type `specialUse` (no daily limit, unlike `dataSync` on Android 15+;
the manifest gives the reason in `PROPERTY_SPECIAL_USE_FGS_SUBTYPE`) with a quiet notification: "Terminal on <Mac>",
"Connected, kept on the Mac" or "Reconnecting, kept on the Mac", a chronometer, End Session (ends the session on the
Mac, as the Live Activity's button does) and a tap that opens the terminal. It never shows the terminal's content. It
is started from the foreground (Android forbids it from the background) and stopped when the terminals close or the
setting goes off. The notification needs POST_NOTIFICATIONS (Android 13+), asked once when a terminal opens; without
it the service still runs, and the settings say so.

The hook in the app model: `AppModel.holdsConnectionInBackground: () -> Boolean`. `onBackground()` waits the usual 25 s,
then keeps the connection while that says true (checked every 5 s), as iOS waits on `keepAlive.holdsInBackground`.
`TerminalController` sets it to "the service is running". Tested in `TerminalBackgroundTests`.

Not done: no wake lock (in deep Doze the CPU may sleep and the keepalives wait; on wake the connection is checked and
the terminal attaches again with `--have`, so nothing is lost but time).

### Tests

`TerminalKeyTests.kt` (33: key encoding, sticky modifiers, paste, arrow pad, swipe rule, key bar layout, links and
last output), `MacTerminalTests` (13, against the in-process SSH server with `FakeTermSessions`, a port of iOS's: attach,
drop and come back with `--have`, relaunch, this phone again, another device takes it, new session and switching,
one attach at a time, status 2, 127 and 1, resize, modifiers, paste, the Mac asleep), `TerminalBackgroundTests` (1).
`TestSshServer.start(..., terms = FakeTermSessions())` turns the held sessions on; without it the fixed answers stay.
`LiveTerminalTests` runs with the live link like `LiveMacTests` (README "Live check"): a real `aos-companion term
attach` session through the test sshd, resize, a dropped connection and the missed output, the list naming this phone,
End Session. Checked on 2026-11-19 against this Mac.

## The desktop app (Windows, Linux)

`desktop/` (:desktop): the same app for Windows and Linux, Compose Multiplatform 1.12.2 on the JVM (17+; the packages
bring Temurin 21), the model and connection from :shared, the UI from shared-ui (the tabs in a navigation rail). It
runs on macOS too, for development, the demo and the screenshots.

```
desktop/
  build.gradle.kts           shared-ui as a source folder, generateAosResources (R and string tables from the XML),
                             jar-<target> per system (Skia's native part for that system only), runDesktop
  src/main/kotlin/dev/marquart/aos/
    desktop/Main.kt          window, tray, single instance, arguments (aos-pair:// link, --background, --demo, --shots)
    desktop/DesktopGraph.kt  the wiring (Android: AppGraph)
    desktop/Os.kt            the app's folder: Windows %APPDATA%\aOS, Linux $XDG_CONFIG_HOME/aos, macOS ~/Library/
                             Application Support/aOS (AOS_HOME or -Daos.home elsewhere); 0700 folders, 0600 files
    desktop/DesktopStrings.kt  the string tables (German when the system is German; AOS_LANG / --lang)
    desktop/keys/            CngKeys (Windows), FileKeys + SecretServiceSealer (Linux, macOS)
    desktop/native/          JNA: Cng (ncrypt.dll), Dpapi, WinHello (UserConsentVerifier through WinRT), LibSecret,
                             Pam, Polkit (pkcheck)
    desktop/store/           FileMacStore, FileSettingsStore, DesktopSecretStore (DPAPI / Secret Service / plain), Prefs
    desktop/connection/      PollingNetworkMonitor (interfaces every 3 s), JmdnsDiscovery (_aos-pair._tcp, _ssh._tcp)
    desktop/system/          Presence (the confirmation), DesktopSettings + Settings section, Tray, Notifier,
                             Autostart, UrlScheme, SingleInstance, PasswordPrompt
    desktop/terminal/        JediTermScreen (JediTerm as TerminalScreen), DesktopTerminals, DesktopTerminalTab
    desktop/screen/          DesktopScreenTab, RemoteScreen (Skia from the framebuffer), DesktopKeys (AWT to Mac keys)
    screen/ScreenPlatform.kt, ui/platform/{Resources,DesktopPlatform}.kt, ui/tabs/TabSlots.kt   the shared declarations
  src/aosgo/ | src/noaosgo/  GoLibrary: the screen engine and aOS's Tailscale through third_party/aosgo-desktop's
                             binding (AosGo.kt), or none (built without it, -Paos.withoutGo=true)
  src/main/res/              strings_desktop.xml (the desktop's own), strings_wording.xml ("this computer")
  packaging/                 linux/ (start script with libjsig, polkit action, PAM service), windows/setup.nsi
  src/test/                  DesktopPiecesTests, DesktopTerminalTests, GoScreenTests, LiveDesktopTests
```

What it does, per system:

| | Windows | Linux | macOS (development) |
|---|---|---|---|
| Keys (SSH, companion) | CNG, non-exportable P-256: TPM (Microsoft Platform Crypto Provider), else the Software Key Storage Provider; signs through MINA's in-process agent like Android | key files `keys/*.key` (0600), the scalar AES-GCM sealed with a key in the Secret Service (libsecret) when there is one, else plain (Settings says so) | plain key files |
| Secrets (the Mac's screen login) | DPAPI (CryptProtectData, current user) | Secret Service key (as above), else plain 0600 | plain 0600 |
| Confirming approvals and the lock (a setting) | Windows Hello (UserConsentVerifier, `RequestVerificationForWindowAsync`), or off | polkit dialog (`pkcheck`, action `dev.marquart.aos.confirm` with auth_self from the .deb, else `org.freedesktop.policykit.exec`), the account's password in aOS (PAM, service `aos` from the .deb, else `login`), or off | off |
| Pairing | paste the aos-pair:// link (no camera); aos-pair:// opens aOS: the installer and the app itself register it (HKCU\Software\Classes) | .desktop file with `MimeType=x-scheme-handler/aos-pair` (the .deb's in /usr/share/applications, else the app writes ~/.local/share/applications and runs xdg-mime) | paste |
| In the background | tray icon (state, Open, Quit), stays connected while in the tray, toasts for sign-ins, approvals and help (a click opens the request), start at login (HKCU Run) | tray where the desktop has one (KDE; GNOME needs an extension), notify-send notifications with an Open action, XDG autostart | tray in the menu bar |
| Terminal | JediTerm (JetBrains, LGPL-3.0/Apache-2.0, used under Apache-2.0) in a SwingPanel, fed by the shared MacTerminal: attach, reconnect with `--have`, notes, sessions list, new/switch/end, copy screen and last output, text size; JediTerm's own keyboard, selection, copy/paste (Ctrl+Shift+C/V, right-click) | same | same |
| Screen | libsharing through the Go library (JNA), standard mode: framebuffer updates (dirty rows) into a Skia bitmap, the Mac's cursor image, mouse, wheel, keyboard by position (AWT key codes to Mac key codes and keysyms; Windows key = ⌘, plus a ⌘ button), clipboard sync, Mission Control; the workspace's display follows the window | same | same (with out/darwin-arm64) |
| Network | interfaces polled every 3 s (a changed set is a new network), Tailscale app = an interface with a tailnet address; JmDNS for Bonjour; aOS's own Tailscale through tailnetkit when the Go library is there | same | same |

High performance video is not played on the desktop: no HEVC/H.264 decoder in the JVM without native code
(`DecoderSupport` offers none, so sessions stay in standard mode). Possible later: FFmpeg through JNA or a Go decoder.

**Packages** (`Tools/desktop.sh`, results in the repository's build/): `aOS-windows-x64.zip`, `aOS-windows-arm64.zip`
(folder with aOS.bat), `aOS-Setup-x64.exe`, `aOS-Setup-arm64.exe` (NSIS, per user, no admin), `aOS-linux-x64.tar.gz`,
`aOS-linux-arm64.tar.gz`, `aos_0.1.0_amd64.deb`, `aos_0.1.0_arm64.deb`. Each brings Temurin 21's JRE for its system
(pinned URL and SHA-256 in the script, cached in build/desktop-jre) and the Go library from
`third_party/aosgo-desktop/out/<target>`. Sizes 107 to 147 MB: the jar alone is about 85 MB (Compose, Skia, the
material icons); shrinking it (ProGuard, or only the icons used) is open. Nothing is signed (SmartScreen warns).

The Go library in a JVM (Linux): Go's runtime installs signal handlers; the Linux start script preloads the bundled
runtime's libjsig.so so the JVM's and Go's handlers chain (the JDK's documented way). Not yet seen on a real Linux.

**The demo and the screenshots**: `--demo` with `--demo.<option>=<value>` (Demo.kt's options) opens a window with
sample data; `--shots=<folder>` renders the main pages off screen (ImageComposeScene; the terminal by painting the
JediTerm widget) into PNGs: build/desktop-screenshots.

**Tests on this Mac** (`:desktop:test`, 38): key files (0600, sealed and plain, a broken or foreign file refused),
stores, every string in both languages and the desktop's wording, no dashes in the German desktop texts, relative
times, WinRT's parameterized IID rule (checked against IAsyncOperation<bool>), CNG's key blob, the keyboard mapping,
the network path, the single instance's hand-over (and a wrong token refused), the shared MacTerminal with JediTerm
against the in-process SSH server (attach, echo, drop and come back with nothing twice), a libsharing session through
the Go library against the demo's RFB server (picture, click, key), the shared UI tests. Live (2026-11-19, this Mac,
README "Live check"): pairing with aOS's pairing listener, SSH, a real `aos-companion term attach` session in JediTerm
with resize, a dropped connection and the missed output, End Session; the companion said NeedsPairing as for Android
(aosctl's keychain partition, see Open points).

Not run on Windows or Linux yet: CNG/TPM keys, DPAPI, Windows Hello, the registry, toasts, libsecret, polkit, PAM,
notify-send, the tray there, JmDNS on those networks, the Go library's .dll/.so loading (`~/VMs/Windows` is the
place for the first Windows run).

## Decisions and what was learned

- **SSH library: Apache MINA SSHD 2.19.0** (Apache-2.0, released 2026-06-30). The phone's key is offered as an SSH agent
  in the process (`DeviceKeyAgent`): MINA gets the public key and signatures, never a private key, so a non-exportable
  Keystore key logs in. Checked: in the JVM tests with a signer that only has a sign function, and on the emulator with
  a real AndroidKeyStore key (`KeystoreSshTest`). sshj was the other candidate; its signatures go through
  BouncyCastle's provider, which can't use Keystore keys.
- MINA's defaults read `~/.ssh` (config, `id_*`, known_hosts) and accept any host key. `SshConnector` turns all of
  that off (`HostConfigEntryResolver.EMPTY`, `KeyIdentityProvider.EMPTY_KEYS_PROVIDER`, its own verifier, publickey
  only). On Android MINA throws without a home folder: `SshConnector.useHomeFolder` gives it an empty one.
- Per-connection settings (the login, the host key check) travel in the connection context
  (`session.connectionContext`, not `session.getAttribute`).
- Host key algorithms are offered ed25519 first: the fingerprint in the pairing code is the Mac's ed25519 key's.
- Keepalive: `keepalive@openssh.com` every 15 s, three unanswered close the connection; on top, the companion
  heartbeat (25 s) and the 5 s probe on foreground and network changes, as on the iPhone.
- The ed25519 host key needs net.i2p's `eddsa` (MINA's EdDSA provider); SLF4J goes to its no-op binding.
- JSON is written with sorted keys and unescaped `/` (kotlinx.serialization does both), so request lines match the
  iPhone's byte for byte; numbers that are whole are written without a fraction.
- targetSdk 36: Android 17's local network permission (for apps targeting 37) needs its own flow first.
- Nothing goes into backups (`data_extraction_rules.xml`, `allowBackup=false`).

## Open points

- Not on a real phone yet: StrongBox (the emulator's Keystore is software), NSD against the real Mac, network changes,
  the local network rules of Android 16/17, EmbeddedTailnet (sign-in, dialing the Mac through tailnetkit).
- The live check's signed companion requests were refused with `pair-again`: a phone key that `aosctl pair-test`
  writes to the keychain carries aosctl's partition, which aOS ignores (Docs/COMPANION.md, "Signed requests"). So the
  signed requests ran against the in-process Mac (which checks like `CompanionGate`) and AOSKit's reference vectors,
  not against the running aOS. A real pairing with the app ("Pair" in aOS) would show it.
- Background: the app keeps the connection 25 s after leaving the foreground, as the iPhone does, and as long as a
  terminal is open (the terminal's foreground service, "The terminal in the background").
- `MockCompanionServer`'s chats keeper and routines are simpler than the iPhone's.
- The desktop app on real Windows and Linux (see "The desktop app": everything system-specific is built and unit
  tested only as far as this Mac allows).
- aOS on the Mac shows the pairing link only as a QR code: the desktop needs it as text (a "Copy Link" button next to
  the QR code in App/Sources/Views/PhoneSettings.swift, PairingView; and its wording "on your iPhone" for computers).
  The desktop's pairing page already says the link is next to the QR code.

