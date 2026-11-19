# aOS for Android

The Android version of the aOS companion app (the iPhone app is `iOS/`, its design `Docs/COMPANION.md`, what the Mac
side must match `iOS/NOTES.md`). This is the foundation: the protocol, pairing, keys, SSH, the companion client, the
connection to the Mac, stores and the state the UI binds to. The terminal, the UI and the screen build on it.

## Layout

```
Android/
  settings.gradle.kts, build.gradle.kts, gradle/libs.versions.toml, gradle.properties, gradlew
  core/                      :core, pure Kotlin (JVM, kotlinx-serialization), no Android
    src/main/kotlin/dev/marquart/aos/core/
      Bytes.kt               base64 / base64url / hex, SHA-256, HMAC, constant-time compare
      P256.kt                P-256 keys (X9.63), raw r||s <-> DER, P256Signer (+ SoftwareP256Signer)
      SSHKeyFormat.kt        OpenSSH key lines, blobs, SHA256 fingerprints, phone id
      PairingLink.kt         aos-pair:// parsing (v1; v2, v3, ... = "update the app"), ReachWay (w), t, tn
      Pairing.kt             PairingRequest (v2 proof; v1 proof for its vector), PairingResponse (answer HMAC)
      Json.kt                lenient JSON accessors, sorted-key writing like Swift's JSONEncoder
      CompanionProtocol.kt   requests, events, answers, CompanionAuth/CompanionSignature/CompanionSigner,
                             MacSideSignature (how the Mac rebuilds what was signed), LineSplitter (1 MiB lines)
      ScreenSeal.kt          ECDH + HKDF-SHA256 + AES-GCM, byte for byte AOSKit's (sealed workspace login)
      MacStatus.kt           MacAction, MacStatus, MacOffer, MacActionResult, MacRefusal, WorkspaceOperation
      Chats.kt               ChatList, ChatOffer
      ConnectionPlan.kt      PairedMac, SSHRoute, ConnectionPlan (route order), TailnetAddress, Iso8601
      TerminalAttach.kt      TermNote / TermNoteFilter (ESC ] 7730 ; JSON BEL), TermAttach commands, MacTermSession
    src/test/                the iOS unit tests with the same vectors (JUnit 5)
  app/                       :app, dev.marquart.aos (minSdk 29, targetSdk 36, compileSdk 37, Compose Material 3)
    src/main/kotlin/dev/marquart/aos/
      keys/                  DeviceKey, KeyProvider: AndroidKeystoreKeys (StrongBox, else TEE), MemoryKeys,
                             KeystoreOrMemoryKeys (the Keystore, memory where it fails), KeystoreSigner
      ssh/                   SshConnector + SshConnection (Apache MINA SSHD), SessionChannel (exec, PTY),
                             DirectTcpipChannel, LocalForwarder, PairingClient, DeviceKeyAgent (the key as an agent)
      companion/             CompanionClient (coroutines), CompanionTransport/ExecTransport, CompanionError,
                             MockCompanionServer (the Mac in memory: tests, a demo)
      connection/            MacConnection (reconnecting, StateFlows), interfaces TailnetDialer, NetworkMonitor,
                             ServiceDiscovery; Android: AndroidNetworkMonitor (ConnectivityManager),
                             NsdServiceDiscovery (NsdManager)
      store/                 MacStore, SettingsStore (DataStore), SecretStore (AES-GCM with a Keystore key)
      model/AppModel.kt      the state holder the UI binds to
      terminal/              the Terminal tab (see "The terminal" below): MacTerminal (the session state machine),
                             TerminalHost (Termux's TerminalView), TerminalKeyBar, TerminalTab, TerminalKeys (pure
                             input logic), TerminalController, TerminalKeepAliveService, TerminalSettings
      ui/                    the UI (Compose, Material 3, brand colors): AosRoot (tabs Overview, Terminal, Screen,
                             Settings; the question sheet; pairing; the lock), overview/ (Mac, requests, workspace,
                             aOS card; chats, apps, routines), signin/ (sign-ins and approvals in one sheet), pairing/
                             (QR scanner: ZXing), settings/ (paired Mac, connection with aOS's Tailscale, lock,
                             notifications, key, acknowledgements; SettingsSlots for the terminal's and the screen's),
                             lock/ (AppLock, Biometrics), notify/ (RequestNotifier), tabs/ (the Terminal and Screen
                             tabs' slots), demo/ (debug builds: sample data from intent extras, see Demo.kt),
                             texts as data (Txt, ErrorText, ConnectionText; strings_ui.xml, values-de)
      AosApp.kt, MainActivity.kt   AppGraph (the wiring), foreground/background, aos-pair:// links
    src/main/kotlin/com/termux/terminal/RemoteTerminalSessions.kt   the one file in Termux's package (see below)
    src/tailnet/             EmbeddedTailnet: tailnetkit (third_party/aosgo) as the TailnetDialer
    src/notailnet/           NoTailnet, when the Go library isn't there
    src/test/                JVM tests: in-process MINA SSH server as the Mac, fake pairing listener, live check
    src/androidTest/         on a phone or emulator: a Keystore key logging in over SSH
  third_party/               the Go library (aosgo.aar: libsharing + tailnetkit), its own README.md
Tools/android.sh             runs ./gradlew here with JAVA_HOME and ANDROID_HOME set
```

## Build and test

```sh
Tools/android.sh :core:test                    # 73 tests
Tools/android.sh :app:testDebugUnitTest        # 50 tests (+ the live check, skipped without a link)
Tools/android.sh :app:assembleDebug            # app/build/outputs/apk/debug/app-debug.apk
Tools/android.sh :app:connectedDebugAndroidTest   # on a running emulator or phone (KeystoreSshTest)
Tools/android.sh --stop                        # the daemon, when done (the Mac is short of memory)
```

`gradle.properties` keeps Gradle small (`-Xmx2g`, no parallel work, the Kotlin compiler in-process).

The Go library: `app/build.gradle.kts` takes `third_party/aosgo/aosgo.aar` when it is there (built by
`Tools/go-android.sh`, see `third_party/README.md`) and then compiles `src/tailnet`; without it `src/notailnet`, and
everything else builds the same. `-Paos.withoutGo=true` builds as if it were missing. ABIs: arm64-v8a and x86_64 (what
the aar has). The aar is GPL-3.0 (libsharing), and so is an app that ships it: see `third_party/README.md`.

### Live check against the real Mac side

`LiveMacTests` pairs with aOS's real pairing listener and uses a throwaway OpenSSH on 127.0.0.1:2222 with its own
`authorized_keys` (nothing of `~/.ssh` is touched), the real `aos-companion` and aOS:

```sh
L=<an empty folder, 0700>
ssh-keygen -q -t ed25519 -N "" -f $L/host_ed25519 && touch $L/authorized_keys && chmod 600 $L/authorized_keys
# sshd_config: Port 2222, ListenAddress 127.0.0.1, HostKey $L/host_ed25519, AuthorizedKeysFile $L/authorized_keys,
# PasswordAuthentication no, KbdInteractiveAuthentication no, UsePAM no, StrictModes no, PidFile $L/sshd.pid
/usr/sbin/sshd -f $L/sshd_config
aosctl pair-test $L/authorized_keys 2222 "$(ssh-keygen -lf $L/host_ed25519.pub | awk '{print $2}')" 127.0.0.1 \
  /Applications/aOS.app/Contents/MacOS/aos-companion          # prints LINK aos-pair://...
Tools/android.sh :app:testDebugUnitTest --tests '*LiveMacTests*' -Paos.live.link='aos-pair://...'
kill $(cat $L/sshd.pid)
security delete-generic-password -s dev.marquart.aos.phonekeys -a <the phone id the test printed>
```

(`aosctl` isn't in the installed app; `AOSKit/.build/out/Products/Debug/aosctl` is a built one.) `pair-test` keeps
the test phone's signing key in the login keychain; the last line removes it.

## The interfaces later agents plug into

All of these are in `app/src/main/kotlin/dev/marquart/aos/`. `AosApp.graph` (`AppGraph`) holds one of each.

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
