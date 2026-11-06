# aOS for iPhone: notes

Design: `Docs/COMPANION.md`. This file holds what the Mac side has to match, requests for AOSRFB (not changed from
here), what was learned about the libraries, and what is open.

## Layout

```
iOS/
  project.yml, generate.sh      XcodeGen spec (target aOS, dev.marquart.aos.ios, iOS 27, Swift 6); generate.sh
                                also copies the Mac app's Icon Composer icon (platform iOS) and Package.resolved
  Package.resolved              exact package revisions (the generated project is gitignored)
  Sources/Core                  pure logic: pairing link and proof, OpenSSH key format, companion protocol (JSON
                                lines), keysym mapping
  Sources/Services              keychain, Face ID, device key (Secure Enclave), stores for Macs, hosts, secrets
  Sources/SSH                   SSHConnection (Citadel over Network.framework), SessionChannel (exec, PTY),
                                LocalForwarder (127.0.0.1 listener -> direct-tcpip), PairingClient
  Sources/Companion             CompanionClient (actor), MockCompanionServer (tests and demo), command line
  Sources/App                   AOSApp, AppModel, MacConnection (reconnects), settings, lock, demo data (debug)
  Sources/{Overview,Pairing,Terminal,Screen,SignIn,Settings,Design}   the UI
  Tests                         unit and integration tests (in-process SSH, RFB and pairing servers)
  Tools                         test.sh, sim.sh, screenshots.sh, localize.sh (+ translations_de.py), render-icon.sh
```

Run the tests: `iOS/Tools/test.sh`. Run the app with sample data: `iOS/Tools/sim.sh -AOSDemo YES` (debug builds
only; `-AOSDemoTab screen`, `-AOSDemoSheet signin|signin-code|signin-locked|signin-off|help|pairing|settings|lock|...`,
see `Sources/App/Demo.swift`).
Screenshots of every screen, light and dark: `iOS/Tools/screenshots.sh de` (or `en`), into `build/ios-screenshots`.
Strings: write English in code, German in `Tools/translations_de.py`, then `iOS/Tools/localize.sh`; it refuses
nothing but reports missing German, mismatched format specifiers and dashes used as punctuation.

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
- Typing into the workspace screen: text with characters beyond ASCII goes as `{"op":"type","text":"…"}` (all of
  the inserted text), through the same queue as the keys so the order holds; ASCII stays key events over RFB.
- Lines that aren't JSON are skipped (a shell's login message, for example); lines up to 1 MiB; unknown fields and
  unknown events are ignored. Request timeout 20 s.
- `help.done` when the person taps Done.
- Dates: ISO 8601 with or without fractional seconds. `region`: workspace pixels; `w` or `h` 0 means no region.
- `screen` `mac`: if the companion isn't ready, the iPhone assumes 127.0.0.1:5900.
- Session `state` strings the iPhone shows in words: `running`, `starting`, `stopped`, `waiting`/`asking`,
  `failed`; others as they come.
- Matching logins to the site is the Mac's job (AOSKit `HostMatching`, ported from the iPhone's first version with
  its own vault, which is gone).
- Exit status 127 of the exec channel is shown as "aOS isn't installed where it was paired; pair again".

## The screen (iOS/Sources/Screen)

- `ScreenSession` runs `RFBClient.events` and hands frames to the view through `onFrame` (not through SwiftUI);
  `ScreenRenderer` uploads only the changed rectangles into a Metal texture (mipmaps while the picture is shown
  smaller than its pixels). `ScreenGeometry` (fit, fill, actual pixels, zoom, pan) and `PointerMotion` (trackpad
  acceleration, wheel steps, momentum) are plain math with tests.
- The workspace asks for its display in the phone's shape (`display`, renewed every 20 s, `reset` when it stops; the
  Mac's lease of 45 s covers a phone that vanished). The size is the safe area grown to at least 600x900 points.
- Settings: quality (automatic: best on Wi-Fi, saver on cellular), picture rate, the Mac's scaling, the workspace's
  shape and Retina, pointer drawn on the phone or by the Mac, speed, natural scrolling, haptics, toolbar, key bar,
  statistics.
- Debug builds: `-AOSScreenDirect HOST:PORT` with `AOS_SCREEN_USER` and `AOS_SCREEN_PASSWORD` in the environment
  connects the workspace screen straight to a screensharingd (the simulator reaches a workspace VM's address).

## Requests for AOSRFB (not changed from here)

1. A transport hook: `RFBClient` only connects with NWConnection to host:port, so the iPhone runs a loopback
   listener (`LocalForwarder`) and bridges each connection to a direct-tcpip channel. An initializer that takes a
   byte stream (or a connect closure) would remove the listener, a local port that other apps on the phone could
   connect to while a screen is open (they would still need the screen sharing password).
2. Input readiness: input waits `inputGrace` (5 s) after connecting; the iPhone shows "input works in a moment".
   Exposing the connect time (or an `isInputReady`) would let it show this exactly.
3. Typing beyond ASCII into the workspace: done on the Mac side as the companion op `type` and used (on the Mac's
   own screen the iPhone uses `pbcopy` over SSH, then cmd+v).

## What was learned about the libraries

- **Citadel is pinned to 0.12.0**: 0.12.1 replaced its swift-nio-ssh dependency (the Citadel author's fork,
  Joannis/swift-nio-ssh) with a new third-party fork (Wellz26/swift-nio-ssh, created 2026-04-02 for Mac Catalyst).
  0.12.0 has everything needed. Moving up later: check that fork first.
- `SSHClient.connect(on:settings:)` (used so the app owns the channel and can open exec channels on Citadel's
  NIOSSHHandler) builds the pipeline with synchronous operations off the event loop (assertion in debug). The app
  runs it with the channel's event loop as task executor (`EventLoopTaskExecutor`) and holds bytes that arrive
  before NIOSSH is in the pipeline (`HoldUntilSSHStarts`): the server's version line comes right after TCP connects.
- Citadel asks a custom `NIOSSHClientUserAuthenticationDelegate` only once, so one login method per connection:
  the key for the paired Mac, key or password for an added host.
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
  In the background the connection is kept for 25 s, then dropped and rebuilt on return.
- Unpairing on the iPhone doesn't remove the key on the Mac (the design leaves that to aOS on the Mac).
- iPhone only (no iPad layout). Landscape works but wasn't tuned.
- Local network denial is detected for pairing (NWConnection path); for SSH (NIO on Network.framework) it shows as
  "not reachable" with the hint about Tailscale and the local network setting.
