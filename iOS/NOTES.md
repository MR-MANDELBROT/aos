# aOS for iPhone: notes

Design: `Docs/COMPANION.md`. This file holds what the Mac side has to match, the screen (Open Screen Sharing: origin,
license, changes), what was learned about the libraries, and what is open.

## Layout

```
iOS/
  project.yml, generate.sh      XcodeGen spec (target aOS, dev.marquart.aos.ios, iOS 27, Swift 6); generate.sh
                                also copies the Mac app's Icon Composer icon (platform iOS) and Package.resolved
  Package.resolved              exact package revisions (the generated project is gitignored)
  Sources/Core                  pure logic: pairing link and proof, OpenSSH key format, companion protocol (JSON
                                lines), the workspace's sealed screen login (ScreenSeal, the same scheme as
                                AOSKit's), the Mac's status for the Overview, keysym mapping
  Sources/Services              keychain, Face ID, device key (Secure Enclave), stores for Macs and the screen login
  Sources/SSH                   SSHConnection (Citadel over Network.framework), SessionChannel (exec, PTY),
                                LocalForwarder (127.0.0.1 listener -> direct-tcpip), PairingClient
  Sources/Companion             CompanionClient (actor), MockCompanionServer (tests and demo), command line
  Sources/App                   AOSApp, AppModel, MacConnection (reconnects), settings, lock, demo data (debug)
  Sources/{Overview,Pairing,Terminal,Screen,SignIn,Settings,Design}   the UI
  Sources/Tailnet               aOS's own Tailscale node (EmbeddedTailnet: Tailnetkit, its state, the sign-in
                                session) and Settings > Connection; the order of routes is Sources/Core/ConnectionPlan
  Frameworks                    Tailnetkit.xcframework (aOS's Tailscale node, Tailnet/ as a C library), built by
                                generate.sh with ../Tailnet/build.sh ios when missing or older than its Go sources;
                                not checked in (needs Go; the first build fetches the toolchain go.mod asks for)
  Shared                        compiled into the app and the widget extension: the Live Activity's attributes and
                                its End button (an App Intent that runs in the app)
  ThirdParty/OpenScreenSharing  the screen client: Open Screen Sharing's session engine and session UI (framework
                                target ScreenClient, GPL-3.0: LICENSE, COPYING); Libsharing.xcframework (its Go
                                library) is built there by Tools/libsharing.sh and not checked in
  Widgets                       the widget extension AOSWidgets (dev.marquart.aos.ios.widgets): the Live Activity
  Tests                         unit and integration tests (in-process SSH, RFB and pairing servers, the Mac's
                                terminal sessions played by the test SSH server)
  Tools                         test.sh, sim.sh, screenshots.sh, localize.sh (+ translations_de.py,
                                translations_screen_de.py), screen_strings.sh, libsharing.sh, render-icon.sh,
                                test-tailnet.sh (the end-to-end test of aOS's Tailscale against a test tailnet)
```

Run the tests: `iOS/Tools/test.sh`. Run the app with sample data: `iOS/Tools/sim.sh -AOSDemo YES` (debug builds
only; `-AOSDemoTab screen`, `-AOSDemoScreen mac|mac-login|mac-login-keyboard`,
`-AOSDemoSheet signin|signin-code|signin-locked|signin-off|help|pairing|settings|lock|...`, see `Sources/App/Demo.swift`).
Screenshots of every screen, light and dark: `iOS/Tools/screenshots.sh de` (or `en`), into `build/ios-screenshots`.
Strings: write English in code, German in `Tools/translations_de.py`, then `iOS/Tools/localize.sh`; it refuses
nothing but reports missing German, mismatched format specifiers and dashes used as punctuation. The screen client's
strings: see "The screen" below.

Only an iOS 26.4 simulator runtime was installed here. The project targets iOS 27; `test.sh` and `sim.sh` lower the
deployment target for that build only when the simulator is older. The app uses no iOS 27-only API so far.

## What the Mac side must match

Pairing (`Sources/Core/PairingLink.swift`, tests in `Tests/PairingTests.swift`):

- URL `aos-pair://v1?n=&h=&p=&s=&u=&k=&c=`. Percent-encode every value with only the unreserved characters left
  as they are (`A-Z a-z 0-9 - . _ ~`): `+`, `/` and `=` in the fingerprint must become `%2B`, `%2F`, `%3D`, spaces
  `%20` (not `+`; the iPhone does not turn `+` into a space). `h` may separate hosts with a literal `,` or `%2C`.
  `s` defaults to 22, `n` falls back to the first host. A host other than `v1` that looks like `v2`, `v3` makes the
  iPhone say "update the app".
- `k`: `SHA256:` + standard base64 of the SHA-256 of the host key blob, padding optional. Verified against this
  Mac's real sshd: the iPhone negotiates `ssh-ed25519` and its fingerprint equals `ssh-keygen -lf
  /etc/ssh/ssh_host_ed25519_key.pub`.
- `c`: exactly 16 bytes, base64url, no padding.
- Request line: `{"device":"…","key":"ecdsa-sha2-nistp256 AAAA…","proof":"…","v":1}` + `\n` (keys sorted, `/` not
  escaped; parse it as JSON, don't rely on the order).
- Proof: standard base64 **with padding** of `HMAC-SHA256(key: the 16 raw bytes of c, message: UTF-8 of key + "\n" +
  device)`, with `key` and `device` exactly as the JSON strings decode. Reference vector (also in the tests):
  `c` = bytes 00 01 … 0f (`AAECAwQFBgcICQoLDA0ODw`), device `Max’s iPhone` (U+2019),
  key `ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU=`
  (the P-256 generator point) gives `mrui6J5uTrdDd7yaEdlJQU6kWIO77PVkB04oYtW2SAQ=`. Compare in constant time.
- Before writing `authorized_keys`: accept only `ecdsa-sha2-nistp256` followed by one base64 blob whose decoded type
  string is the same (nothing else on the line, so no options can be smuggled in), and sanitize the device name
  (the iPhone already removes control characters and line breaks and cuts it to 64 characters, but the Mac must not
  trust that: a line break in the name would add a line to `authorized_keys`).
- Answer: one JSON line, then close. The iPhone uses `user` for SSH (falls back to `u`) and `companion` as the path
  (falls back to `/Applications/aOS.app/Contents/MacOS/aos-companion`). A close without an answer is shown as
  "the Mac ended the pairing, show a new code".
- The iPhone connects to the pairing port of each host in `h` in order; if none answers it browses Bonjour for
  `_aos-pair._tcp` (a service named like `n` wins, otherwise the only one found).
- On the go (optional, since the Mac's step "On the go"): `w` = `app`, `aos` or `lan` (anything else counts as
  none), `t` = the Mac's tailnet hosts (IPv4 in 100.64.0.0/10 first, then the MagicDNS name; plausible hosts only,
  each once), `tn` = the tailnet's name (no control characters, at most 128 characters). The tailnet hosts are in `h`
  as well, after the local ones. Kept with the paired Mac (`PairedMac.way`, `tailnetHosts`, `tailnetName`); a Mac
  paired earlier has none, and the tailnet addresses and names among its `h` count as its tailnet hosts.
- `authorized_keys` options: the terminal needs a PTY and the screens need port forwarding (direct-tcpip to
  127.0.0.1:5900 and to the VM). `no-agent-forwarding,no-X11-forwarding` as in the design is fine; `restrict` or
  `command=` would break the terminal and the screens.

Companion API (`Sources/Core/CompanionProtocol.swift`, `Sources/Companion/CompanionClient.swift`):

- Exec command: `'<companion path>' serve` (single-quoted for the login shell sshd runs it with), the path from the
  pairing answer.
- Order after connecting: `hello`, `subscribe`, `status` (subscribe first: the Mac then replays the open questions;
  the app shows each request id once). `status` is asked again after every `workspace` event (for `purpose` and
  `until`) and every 25 s as a heartbeat (the Mac counts a phone as connected while it asked within 45 s); a heartbeat
  that times out closes the exec channel and the companion starts again.
- `signin` carries the person's Bitwarden logins for the site (`logins`: id, name, user name, `totp`) and
  Bitwarden's state on the Mac (`bitwarden`: `unlocked`, `locked`, `off`, `unavailable`; missing or unknown counts
  as `off`). The sheet lists the logins (name and user name; the iPhone never talks to Bitwarden and never gets a
  password) and approves one after Face ID: `{"op":"signin.answer","request":"…","login":"<id>"}`. `locked` says
  "unlock it in aOS on the Mac"; the Mac then sends the same request again with its logins, and the app updates the
  request it has (same id) instead of showing it again. "From another password app" (fields with AutoFill) answers
  with `username`/`password` as before.
- `field` `code`: logins with `totp` get "Fill in the code from <login>" (Face ID, the answer names the login, the
  Mac gets the current code from Bitwarden); otherwise a code entry (text content type one-time code) and the
  answer carries `totp` only. A missing or unknown `field` counts as `password`.
- `approval` events get a sheet (who, why, for how long, countdown) with Allow / Don't Allow ->
  `{"op":"approval.answer","request":"…","allowed":true|false}`; `approval.closed` shows the result. Sign-ins and
  approvals share one queue and one sheet, in the order they came; "Later" keeps one waiting in the overview.
- `{"event":"mac","state":"unavailable","detail":"…"}` shows "aOS on the Mac isn't answering right now (…). It
  keeps trying." on the Mac card; any other `mac` state, or a successful heartbeat, clears it.
- Typing into the screens: since 2026-11-07 the screen client types text itself (Unicode keysyms, or Apple's paste
  over screen sharing where macOS composes), so the iPhone no longer sends `{"op":"type"}`; the op stays on the Mac.
- Lines that aren't JSON are skipped (a shell's login message, for example); lines up to 1 MiB; unknown fields and
  unknown events are ignored. Request timeout 20 s.
- `help.done` when the person taps Done.
- Dates: ISO 8601 with or without fractional seconds. `region`: workspace pixels; `w` or `h` 0 means no region.
- `screen` `mac`: if the companion isn't ready, the iPhone assumes 127.0.0.1:5900.
- `screen` `workspace` (since 2026-11-07): `CompanionClient.workspaceLogin()` (also behind `screen(.workspace)` and
  `MacConnection.screenEndpoint(.workspace)`) sends `reply`, a P-256 key-agreement key made for this one request
  (base64 X9.63, in memory only until the answer is open), signed as part of `data`. The answer must be `sealed`
  (`ScreenSeal`: ECDH, HKDF-SHA256 over op, phone id, nonce and both keys, AES-GCM); it returns host, port, user name
  and password. An answer with the login in plaintext is refused ("Update aOS on the Mac"), one that doesn't open is
  "an answer this app doesn't understand". Docs/COMPANION.md, "The workspace's screen login".
- Session `state` strings the iPhone shows in words: `running`, `starting`, `stopped`, `waiting`/`asking`,
  `failed`; others as they come.
- Matching logins to the site is the Mac's job (AOSKit `HostMatching`, ported from the iPhone's first version with
  its own vault, which is gone).
- Exit status 127 of the exec channel is shown as "aOS isn't installed where it was paired; pair again".
- The Overview's ops (`mac.status`, `mac.sleep`, `mac.display-off`, `mac.display-on`, `mac.stay-awake` with `text`,
  `workspace.start`, `workspace.stop`, `bitwarden.lock`, `session.restart`; Docs/COMPANION.md "The Mac from the
  iPhone") are signed like `type`: op `companion.<op>`, the value only in `text`. A refusal carries `code`
  (`sleep-disabled`, `other-service`, `sleep-held`, `not-set-up`, `no-session`), which the phone words itself
  (`MacRefusal`). `hello`'s `features` tells whether the Mac has them; without, the Mac card says to update aOS.
- The terminal on the paired Mac: a pty-req plus exec of
  `'<companion>' term attach [--id ID [--have N]] --client <phone id>`, notes `ESC ] 7730 ; <JSON> BEL` in the output
  (Docs/COMPANION.md, "Terminal sessions"; `replaced` for this iPhone's own older connection, `taken` only for another
  device); `term list --json` (with `client`) and `term end ID` in exec channels.

## The terminal (iOS/Sources/Terminal)

**Key bar** (`TerminalKeyBar`, layout in `KeyBarLayout`): one row that scrolls as a whole. At its start the arrows sit
exactly in the middle of the screen: the swipe pad (default) or four keys ← ↑ → ↓ (Settings > Terminal > Arrow keys).
Every key has the same width, at least 46 pt to touch with a 44 pt high plate; the keys left of the arrows fill that
half exactly (Esc, Control, Tab on an iPhone upright; more in landscape), so at rest no key is cut on the left and the
arrows are centered. Then Option, Shift-Tab, paste (the system's paste control, no question), Home, End, Page Up,
Page Down, forward delete, F1 to F12: only what the iPhone's keyboard lacks (Max, 2026-11-07: the symbols are on the
keyboard, so they left the bar; forward delete stays, the keyboard only deletes backwards). The row snaps to whole keys and fades slightly where more keys are. A drag that starts on the pad sends
arrows instead of scrolling the bar. Keys give way a little while pressed; modifiers stick (tap), lock (double tap)
or work while held, as before.

**Swiping on the terminal sends arrow keys** (Settings > Terminal > Swipe for arrow keys, on by default;
`TerminalSwipe`, `ArrowSwipeRecognizer`). The rule, decided once the finger has moved 12 pt, and only if it started
moving within 0.3 s:

- Sideways: ← or →, anywhere on the terminal (sideways drags did nothing there before).
- Up or down: ↑ or ↓ only as a quick flick (over 450 pt/s when it leaves the 12 pt) and only while the terminal
  shows its end (not scrolled back; full-screen programs have no scrollback, so there always). Slower drags scroll
  the scrollback as before; once scrolled back, flicks scroll too.
- Then like on the pad: keep the finger down and the arrow repeats (after 0.35 s, faster the farther the finger is
  from where it started); moving back across the start sends the other direction, and it can turn to ↑ ↓ while held.
  A glass circle above the finger shows the arrow being sent, with a light haptic tick per arrow.
- Never: with two fingers (pinch, two-finger scrolling in full-screen programs), on a selection handle, while text is
  selected or the edit menu is up, for touches that start within 24 pt of the left edge (the system's back swipe), and
  for a finger that rested first (a long press selects). A tap still shows the keyboard.
- The scroll view's pan and SwiftTerm's one-finger pan for programs with mouse reporting wait for the swipe to fail,
  which it does at the 12 pt mark for anything that isn't arrows; scrolling starts 2 pt later than before.

**The Mac's session survives the connection** (Docs/COMPANION.md, "Terminal sessions"; `TerminalSession`,
`TerminalAttach`). The Mac terminal runs `aos-companion term attach` in a pseudo terminal instead of a login shell.
The phone remembers the session's id (UserDefaults, per Mac) and counts the output bytes after the start note:

- Connection gone (app in the background, network change, Mac asleep): "Reconnecting … The session keeps running on
  the Mac." over the terminal, which keeps its contents. As soon as the app's Mac connection is up again (it reconnects
  by itself when the app comes back to the foreground and on network changes), the terminal attaches with `--have`
  and gets exactly the missed output. A connection that only looks alive (TCP notices a dead peer late) is checked
  when the app comes back and when the network path changes: a `status` with a 5 s timeout, and without an answer
  the connection is closed and built again.
- App killed and started again: the terminal attaches to the same session without `--have`: reset, the modes in
  effect, the last 256 KB of output (scrollback 2000 lines) and the program redraws itself.
- This iPhone is never "another device" for itself (Max saw his own session as open elsewhere): it names itself when
  attaching (`--client`, its phone id), so its own older connection is replaced without a word, and the terminal only
  listens to its newest channel (a round counter: output and notes of an older channel, one that lingers after a
  reconnect, are dropped). Only one attach runs at a time, so a quick tap can't start two new sessions. The list shows
  a session attached with this iPhone's id as "Open on this iPhone", also after the app was closed while the Mac
  still holds the old connection (with an older aOS that doesn't report `client`: the session this iPhone showed last).
- Taken over by another device, the shell exited, the session ended: said plainly, with "Open It Here" or "New
  Session". There is no Detach (Max, 2026-11-07): sessions simply continue on the Mac; "End Session" (asks first)
  ends a shell.
- The Terminal tab is the Mac's alone (Max: other computers and Mac accounts aren't needed; what an earlier version
  kept for them, hosts and their passwords, is deleted from the keychain at launch): "New Session" on top starts
  another shell on the Mac, the list below (`term list`, every 10 s while it is on screen: program and folder, open on
  this iPhone or elsewhere or nowhere since when, oldest first) opens one here or ends it (swipe or context menu).
  The terminal's menu has New Session, Switch Session (the others) and End Session; the session's name is the
  navigation subtitle. Switching lets go of the session shown (it keeps running) and attaches to the other, afresh;
  back to one shown before, the terminal continues where its view is.
- The Mac asleep (after Sleep from the Overview): "The Mac is sleeping. The session continues when it wakes." instead
  of "Reconnecting".
- aOS on the Mac without `term` (status 2) or not where it was paired (127): a plain shell, with a note. A Mac that
  refuses to start a session (status 1 before the start note, at most 16 sessions for example) is shown with what it
  said, without trying again and again.

## Terminals in the background: what keeps them alive

What iOS 27 allows (read in Apple's documentation and the iOS 27 release notes, 2026-11):

- **The shell on the Mac** keeps running in every case: app in the background, suspended or killed, network change,
  phone off. That is the part that always holds (aos-companion term; tested on this Mac with the real binary).
- **beginBackgroundTask**: about 30 s after the app leaves the foreground (Termius's documentation says the same for
  current iOS: "usually within 20 to 30 seconds"). aOS keeps the connection for 25 s, then lets it go.
- **BGContinuedProcessingTask** (iOS 26+): not used since 2026-11-07. Submitted from the foreground as a result of a
  person's action, it runs on in the background with iOS's own progress UI, and the person can stop it there; Apple
  meant it for work with an end (exports, uploads). On Max's iPhone its system UI ("Terminal in the background" with a
  progress) read as a task that runs, not as a terminal that is kept, and he asked for it to go, with its setting.
- **Live Activity** (setting "Live Activity", on): shows the open terminal (the Mac, connected or reconnecting, kept
  on the Mac; never its content, the Lock Screen is for anyone) with an End button and a link back
  into the terminal. It gives the app **no** time in the background: "Each Live Activity runs in its own sandbox,
  and, unlike a widget, a Live Activity can't access the network"; it is updated by the app while it runs or by
  ActivityKit push. `NSSupportsLiveActivitiesFrequentUpdates` raises the budget for push updates only; aOS has no push
  server, so it changes nothing here (set as asked). Without background time the content goes stale a minute later
  and says "Kept on the Mac. Open aOS to continue." Termius tells its users to switch Live Activities on and calls
  its method a "lightweight workaround" without details; no Apple API keeps an app running because of a Live
  Activity alone, so the Live Activity is the display and the End button, and location is what can keep aOS running.
- **Location** (setting "Keep alive with location", off by default): `UIBackgroundModes` location, "while using"
  permission, `allowsBackgroundLocationUpdates` and a `CLBackgroundActivitySession`, the coarsest accuracy (3 km, no
  GPS) and no distance updates worth mentioning. An app that receives location updates keeps running, so the
  connection stays as long as a terminal is open. It costs battery (the location service stays on) and iOS shows the
  location arrow. aOS starts it when the app leaves the foreground with a terminal open and stops it when the app
  comes back or the terminals close. App Review would want a location reason: personal builds.
- Nothing else in iOS 27 changes this (the background additions are about the GPU and the Neural Engine).

## The Overview (iOS/Sources/Overview)

`mac.status` every 15 s while the Overview is on screen and the app is active, after every workspace event and after
every action (each answer carries the new status). Mac card: battery and charging (time left or until full), power
adapter, lid, the display (on, off, or none with the lid closed and no monitor; monitors besides the built-in one),
temperature when it is high, staying awake with what holds it or why not, a menu to change it. Only the actions that
fit (`MacOffer`): Sleep (asks first: the phone loses the connection until the Mac wakes) while it is awake, Display
Off while the display is on, Display On (`caffeinate -u` on the Mac) while it is off. After Sleep the card says
"Sleeping since" with the time at once, and the connection is closed when the Mac falls asleep (it would die without a
word, and the app would still say "connected"); no new attempt for 20 s, then the usual ones, and the first that
works ends "sleeping". The aOS card isn't shown while the Mac sleeps or aOS doesn't answer (it would be old), and the
workspace card then says "No news from the Mac", without its purpose and buttons (a closed connection sets the
companion back to not started, so nothing reads as ready any more).
Workspace card: Start (closed),
Close (asks first while an agent has it), Show the screen. aOS card: Claude Code session (Restart, asks first), new
chats from the Claude app, kept conversations, Bitwarden (Lock). When Claude Code on the Mac needs a sign-in (the
session or new chats say `needsLogin`), the card says what to do: run `claude` once in a terminal on the Mac and sign
in; "Open Terminal" opens the Terminal tab in a new session on the Mac to do it from here. An older Mac without these
ops: the card says to update aOS. All rows share one 30 pt icon column (`OverviewRow`); `FactRow` centers its symbol in the same column on
the first line's baseline (the eye was wider than the others and pushed its text out of line).

Note for the screen tab: a workspace started from the phone reports `running` (no agent lease), not `open`.

**The tab bar** (Max, 2026-11-07: it was gone after a reload). The terminal hides it while it is shown and the Screen
tab while its screen is in full screen (`.toolbar(.hidden, for: .tabBar)`). The Screen tab, kept alive behind the
others by the TabView, started its screen by itself when the Mac came back or the workspace opened (its `onChange`
handlers), and its full screen then hid the tab bar of the tab on screen, with no way back. Reproduced in the
simulator (`TabBarTests`: the screen starting while the Overview is shown took the Overview's tab bar). RootView now
builds the Screen tab only while it is selected, so nothing of it runs from behind. An explicit
`.toolbar(.visible, for: .tabBar)` on a tab's root does not help: on the Terminal list it even kept the pushed terminal
from hiding the bar (also seen in the test), so there is none.

## The screen: Open Screen Sharing (iOS/Sources/Screen, iOS/ThirdParty/OpenScreenSharing)

Max's decision (2026-11-07): the Screen tab uses "the complete code and settings of Open Screen Sharing, exactly
like OSS, only adapted a bit", with the workspace and the Mac as its two screens. aOS's own viewer (Metal renderer,
geometry, pointer math, controls, built on AOSRFB) is gone.

**Origin and license.** Open Screen Sharing by nekohasekai, https://github.com/nekohasekai/open-screen-sharing,
GPL-3.0 with an extra term: "no derivative work may use the name or imply association with this application without
prior consent". Taken on 2026-11-07 from Max's fork (`~/Developer/open-screen-sharing`, branch `autofill-passwort`,
commit 8b19fc9) into `ThirdParty/OpenScreenSharing/Sources`. Every file carries "Based on Open Screen Sharing by
nekohasekai, GPL-3.0" with the date, aOS's changes are marked `aOS:`; `LICENSE` is OSS's notice, `COPYING` the
GPL-3.0 text; Settings > Acknowledgements shows both and says aOS isn't associated with the author. Max uses it for
himself first and asks the author. Before giving the app to anyone else: the author's consent, and the GPL then
covers the app as a whole (its source offered, libsharing's included).

**What was taken**: Session/ (LibsharingSession, SessionController, DisplayPipeline, decoders, cursors, keys,
clipboard), SessionUI/ (SessionView, RemoteScreenView with Metal, ScreenInput: touch, trackpad, mouse, pointer lock,
gestures; floating toolbar, menus, customizing it, keyboard accessory bar, debug panel, tips, drag and drop of files),
Model/ (its settings, key mappings and shortcuts, toolbar layout, the GRDB store), Settings/ (keyboard, cursor style,
its settings page), App/ helpers and its menu commands. Packages as in OSS: GRDB 7.11.1, swift-perception 2.0.12,
swift-atomics. The framework target `ScreenClient` keeps OSS's Swift settings (main actor by default, approachable
concurrency, member import visibility). libsharing (Go) is `Libsharing.xcframework`, built from OSS's source by
`Tools/libsharing.sh` (gomobile bind like OSS's `make lib`, iPhone and simulator only; `--copy` takes the checkout's
own build); `generate.sh` runs it when the framework is missing.

**Left out**: the computer list and editor, discovery and availability, links, pairing with other devices, RDP (its
Swift branches stay, aOS never opens one; the Go library still has it) and with it sending audio (no microphone code,
no permission), the macOS app (its code stays compiled out),
the server mode, updates, OSS's demo, the language picker (iOS has one per app), the fork's password fill panel, and
"New Connection". High performance (video and audio over UDP) is off: only TCP goes through SSH.

**aOS's changes in the module** (`aOS:`): `SessionRoute.init(computerID:name:host:port:credentials:followsWindowShape:)`
with `managesLogin = false` (never OSS's sign-in sheet, no saved user name or password, a refused login goes to
`onLoginRefused`); no thumbnails (aOS keeps no pictures of the screens); `onDisplayArea` (the area OSS fits the picture
into); `followsWindowShape` (the iPhone isn't turned to the picture); `RemoteScreenUIView.focus(on:)` for help
requests; caches in `Caches/Screen`; an in-memory store for the demo; the settings page; "Controls" for OSS's
"Control" menu (one string table: "Control" is the terminal's key). `Bridge/ScreenClient.swift` is aOS's interface
(`ScreenClientSession`, `ScreenClientView`, `ScreenClientSettings`, `ScreenCommands`, orientation, license texts).

**A session** (`ScreenSession`, `ScreenRoute`): one per screen, one at a time.
- Workspace: `CompanionClient.workspaceLogin()` (sealed, `ScreenSeal`) gives the VM's address, port and account;
  `LocalForwarder` listens on 127.0.0.1 (random port) and opens a direct-tcpip channel per connection to that address
  through the SSH connection (the current one: a session survives the Mac's connection being rebuilt, OSS reconnects
  by itself); OSS's session connects to 127.0.0.1 and that port with Apple's account login.
- Mac: the Mac account from the keychain behind Face ID (as before), the tunnel to 127.0.0.1:5900 on the Mac. A
  refused login ends the session and shows the login form with the reason.
- The workspace takes the iPhone's shape with aOS's `display` op (OSS's own virtual display needs high performance):
  before connecting, from the window, then from OSS's measured area (the window without the top safe area upright,
  without the sides on its side), grown to at least 600x900 points, Retina; renewed every 20 s, `reset` when it
  stops. So the picture fills the screen; the iPhone turns freely and the workspace follows. The Mac's screen keeps
  its size and OSS turns the iPhone to it (landscape), with its toolbar in the letterbox.
- Stored (OSS's GRDB database, Application Support/Screen Sharing.sqlite): OSS's settings and, per screen (ids derived
  from the paired Mac's id, deleted when unpairing), quality, observe mode, clipboard sync, pointer lock and the
  screen sharing key it trusts (first use). Never a user name, password or picture.
- "Sync Clipboard" starts off for the workspace (OSS's default is on): what the iPhone copies, a password or a code,
  doesn't go to the agent's Mac unless the person turns it on in the session's clipboard menu (remembered). The Mac
  starts with it on, as in OSS.
- The orientation lock needs an app delegate (`AOSAppDelegate`); OSS's menu commands are on the scene.

**Strings**: the module looks them up in the main bundle, so they are manual entries of the app's catalog.
`Tools/screen_strings.sh` adds new ones (export with the module's strings, `screen_strings.py`, then `localize.sh`);
German in `Tools/translations_screen_de.py` (OSS's own German, reviewed); `translations_de.py` wins for a shared key.

**Demo and debugging**: in the demo the Screen tab shows OSS's real session with a picture from `DemoScreenServer`
(plain RFB on 127.0.0.1 in the app, debug builds). `-AOSScreenDirect HOST:PORT` with `AOS_SCREEN_USER` and
`AOS_SCREEN_PASSWORD` connects the workspace screen straight to a screensharingd (the simulator reaches a workspace
VM's address). libsharing logs to the app's subsystem, category `libsharing`.

## AOSRFB on the iPhone

Only `DisplayRequest` (shared with the Mac) and the forwarder's integration test still use it. The loopback listener
stays (libsharing dials TCP itself): while a screen is open, other apps on the phone could connect to that port (they
would still need the screen sharing login).

## aOS's own Tailscale (iOS/Sources/Tailnet)

- `EmbeddedTailnet` runs Tailnetkit (Tailnet/tailnetkit, the same Go code as the Mac's node: tsnet with aOS's build
  tags, no peer API or other services; Docs/DESIGN.md, "Reaching the Mac on the go"). State in Application
  Support/Tailnet, file protection until the first unlock, excluded from backups; named `aos-<iPhone's name>`;
  "set up" is remembered in UserDefaults (`tailnetSetUp`, `tailnetHostname`), not secret. It starts when the app
  becomes active and with the Mac connection, polls its status every 3 s (every second while the sign-in page is
  open) and posts `.aosTailnetReady` when it runs (the Mac connection tries again at once).
- A C library, not gomobile: Open Screen Sharing's libsharing is a gomobile framework in the same app, and two
  gomobile frameworks define the same Objective-C classes (GoSeqRef, RefCounter, RefTracker, Universeerror,
  goSeqDictionary: "implemented in both", undefined which one is used). Tailnetkit is `go build
  -buildmode=c-archive` in a static framework (header `tailnetkit.h`, module map), so the app holds two Go runtimes,
  one in the app's image and one in ScreenClient.framework. Go doesn't promise that two runtimes in one process
  work; they do in the end-to-end test (both loaded, Tailnetkit signing in, dialing, carrying SSH). If it ever
  shows problems: build libsharing and tailnetkit into one Go library.
- The sign-in: Tailscale's sign-in URL from the node's status (only https pages of tailscale.com) in an
  `ASWebAuthenticationSession` with Safari's cookies (callback scheme `aos-tailnet`, never called: Tailscale's page
  doesn't lead back), closed by the app once the node runs.
- Dialing: `tailnetkit_dial` returns one end of a socket pair (close on exec, no SIGPIPE) whose other end is spliced
  to the tailnet connection; `SSHConnection` puts it into a NIOPosix channel (`ClientBootstrap.withConnectedSocket`)
  with the same `HoldUntilSSHStarts` and Citadel setup as the Network.framework path (`SSHRoute.tailnet`). Bonjour
  is `SSHRoute.bonjour` (an NWEndpoint service `_ssh._tcp`).
- The Tailscale app's VPN counts as active when a utun interface has an address in 100.64.0.0/10 or
  fd7a:115c:a1e0::/48 (`TailnetVPN`, AOSTailnet).
- Tests: `TailnetTests` (link fields, the order of routes, sign-in page check, names, the node's status, SSH and the
  companion through a socket pair, a tailnet node that can't pose as the Mac, the same network winning, no node);
  `TailnetEndToEndTests` with `Tools/test-tailnet.sh <simulator>`: a whole tailnet on this Mac (Tailscale's test
  coordination server, DERP, a "Mac" node with aOS's code; `../Tailnet/build.sh testnet`), the real Tailnetkit node in
  the simulator signs in, reaches the test SSH server on port 22 of the Mac node by address and name with the pinned
  host key, runs the companion, and finds the other ports closed. Skipped without the test tailnet.

## What was learned about the libraries

- **Citadel is pinned to 0.12.0**: 0.12.1 replaced its swift-nio-ssh dependency (the Citadel author's fork,
  Joannis/swift-nio-ssh) with a new third-party fork (Wellz26/swift-nio-ssh, created 2026-04-02 for Mac Catalyst).
  0.12.0 has everything needed. Moving up later: check that fork first.
- `SSHClient.connect(on:settings:)` (used so the app owns the channel and can open exec channels on Citadel's
  NIOSSHHandler) builds the pipeline with synchronous operations off the event loop (assertion in debug). The app
  runs it with the channel's event loop as task executor (`EventLoopTaskExecutor`) and holds bytes that arrive
  before NIOSSH is in the pipeline (`HoldUntilSSHStarts`): the server's version line comes right after TCP connects.
- Citadel asks a custom `NIOSSHClientUserAuthenticationDelegate` only once, so one login method per connection:
  the key for the paired Mac (password logins were for added hosts, which are gone).
- Citadel's server-side exec doesn't deliver stdin for exec channels (its SubsystemHandler only releases reads for
  shell and sftp); the tests' SSH server is written on NIOSSH directly.
- `NWParameters.acceptLocalOnly` rejects loopback connections; the forwarder binds to 127.0.0.1 instead.
- SwiftTerm 1.99 doesn't expose its `Terminal`; the size comes from `sizeChanged`.
- An Icon Composer icon can't be loaded with `UIImage(named:)` (it crashes with "Need an imageRef"); the in-app icon
  is an `ictool` rendering (`Tools/render-icon.sh`).
- The global accent color didn't reach every control on iOS; the root view sets the brand indigo as tint, last, so
  sheets and overlays get it too.
- In the simulator, keychain items behind user presence are readable without Face ID (the simulator doesn't enforce
  the ACL), and unsigned builds can't use the keychain at all (-34018); the scripts sign ad hoc.

## Open points

- Not run on a real iPhone: Secure Enclave key, Face ID prompts and the keychain ACL, camera scanning, the local
  network permission prompt, cellular and VPN behavior. All of that needs a device and Max's signing.
- Not run against the real Mac side (pairing listener and `aos-companion` were built in parallel): tested
  against the in-process mock, an NIOSSH server and a fake pairing listener. First real run: pair, then watch
  `log stream --predicate 'subsystem == "dev.marquart.aos.ios"'` on the Mac for the phone's console.
- Notifications while the app is closed (phase 2, CloudKit) are not built; requests show while the app is open.
  In the background the connection is kept for 25 s, then dropped and rebuilt on return, unless the location option
  keeps the app running (then as long as that lasts).
- Not run on a device: the Live Activity (Lock Screen, Dynamic Island, the End button starting the app in the
  background), the location keep-alive and its battery cost, the swipe thresholds (12 pt, 450 pt/s) on real fingers,
  the display state and Display On against a real Mac, the 20 s pause after Sleep.
- Unpairing on the iPhone doesn't remove the key on the Mac (the design leaves that to aOS on the Mac).
- iPhone only (no iPad layout). Landscape works but wasn't tuned.
- The screen client was tested against in-process servers (Apple's account login over the SSH tunnel, a refused
  login) and in the simulator's demo; not yet against the real workspace or Mac, nor on a device (rotation, the
  keyboard bar, pointer lock with a mouse, background and return).
- Local network denial is detected for pairing (NWConnection path); for SSH (NIO on Network.framework) it shows as
  "not reachable" with the hint about Tailscale and the local network setting.
- aOS's Tailscale: not run against Tailscale's real coordination server (no account here) nor on a device: the
  sign-in in the web authentication session with a real identity provider, closing it when the node runs, the node
  after the app was suspended (it reconnects on return), cellular, and the Tailscale app's VPN and aOS's node at the
  same time.
