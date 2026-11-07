# aOS for iPhone (companion)

The iPhone app of aOS. Same name and brand as the Mac app ("aOS", indigo and mint, Liquid Glass). It gives the
user, wherever they are:

- **Sign-ins for the agent** ("agentic passwords"): the agent in the workspace needs to sign in, the iPhone shows the
  request with the user's Bitwarden logins that fit the site, the user approves one with Face ID, and aOS on the Mac
  gets exactly that login from Bitwarden and fills it into the workspace. The agent never sees the password.
- **Terminal**: SSH to the paired Mac (and other hosts the user adds). On the Mac the shell outlives the connection
  ("Terminal sessions", below); a Live Activity shows open terminals.
- **The Mac from the iPhone** (Overview): battery, lid, staying awake, the workspace, aOS's Claude Code session and
  Bitwarden, with sleep and the other actions as signed requests.
- **Screen**: the paired Mac's screen and the aOS workspace, live, with touch, keyboard and trackpad gestures, in
  Open Screen Sharing's session (GPL-3.0, iOS/ThirdParty/OpenScreenSharing; iOS/NOTES.md, "The screen").
- **Help requests**: when the agent asks for help (a captcha, a sign-in it can't do), the request opens the
  workspace screen on the iPhone.
- **Settings**.

## Decisions (2026-11-06; the first version had a vault of its own on the iPhone, replaced the same day)

- **Where the passwords live: in the user's own Bitwarden account.** Max's decision: "We build the front end
  (password, one-time code, help, captchas), and in the back end the app talks to the user's Bitwarden account. You
  sign in only to Bitwarden, and the requests come in our app." The user signs in to Bitwarden once, in aOS on the
  Mac; for every sign-in aOS asks Bitwarden for exactly the login the user approved. aOS keeps no passwords, the iPhone
  has no vault.
- **How the Mac talks to Bitwarden: Bitwarden's official command line tool `bw`, as a program of its own.**
  Bitwarden's SDK license forbids offering an app built with it to others, and its GPL iOS code can't go to the App
  Store. So aOS links nothing of Bitwarden and ships nothing of it: it downloads Bitwarden's own signed macOS build
  from Bitwarden when the user signs in (or uses the user's `bw` if it is that build) and runs it (Docs/DESIGN.md,
  "Bitwarden").
- **The iPhone never talks to Bitwarden.** It shows the request (agent, website, purpose) and which Bitwarden logins
  match, by name and user name, never a password; the user approves one with Face ID and the answer names the login.
  The Mac gets password and one-time code from Bitwarden and fills them.
- **Without Bitwarden:** the approval sheet keeps user name and password fields with iOS AutoFill, so another password
  app (1Password, Apple's Passwords, Bitwarden's own app) fills them with its own Face ID.
- **Not Bitwarden-branded.** Bitwarden is named as what it is, the user's password manager; aOS uses none of its
  logos and is not made by or affiliated with Bitwarden.
- **Connection: SSH.** The Mac's Remote Login (OpenSSH) carries everything: the terminal, the companion API (an exec
  channel running `aos-companion serve`), and the screens (direct-tcpip channels to 127.0.0.1:5900 for the Mac and
  to the workspace VM). No new server, no listening port beyond OpenSSH, strong crypto, pinned host key. Outside the
  home network it goes through Tailscale (2026-11-07, "Connecting" below): the person's own Tailscale app, or aOS's
  own Tailscale node on the Mac and in the iPhone app; or only the same network.
- **Keys**: the iPhone's SSH key is a P-256 key in the Secure Enclave (software key in the keychain on the simulator).
  It never leaves the device. A second key of the same kind signs every companion request; the Mac got its public
  half at pairing and acts only on requests signed with it ("Signed requests", 2026-11-06, after a security review:
  any program of the Mac's user could otherwise answer sign-ins in the iPhone's name).
- **Pairing without typing a password** (below): the Mac shows a QR code, the iPhone scans it, done.
- **Notifications** (sign-in and help requests while the app is closed): phase 2, through CloudKit (free, no server of
  ours, end-to-end with the user's iCloud). Until then the app shows requests while it is open and connected.

## Pairing

1. aOS on the Mac ("Pair" next to iPhone in the menu, or Settings > iPhone) checks that Remote Login is on (port 22 answers) and otherwise opens
   System Settings > General > Sharing. It starts a pairing listener: TCP on a random port, advertised over Bonjour
   as `_aos-pair._tcp`, open for 3 minutes and for one pairing.
2. It shows a QR code with the URL
   `aos-pair://v1?n=<Mac name>&h=<host1>,<host2>&p=<pairing port>&s=22&u=<user>&k=<host key fingerprint>&c=<code>&w=<way>&t=<tailnet hosts>&tn=<tailnet>`
   (all values percent-encoded; `w`, `t` and `tn` since the setup step "On the go", only once a way was chosen).
   - `h`: names and addresses to try in order: `<name>.local`, IPv4 addresses of active interfaces (VPNs among them
     last), then the tailnet hosts of `t` (so an iPhone that doesn't know `t` still tries them).
   - `w`: how the iPhone reaches the Mac on the go: `app` (the person's Tailscale app), `aos` (aOS's own Tailscale
     node), `lan` (only on the same network). Unknown values count as none.
   - `t`: the Mac's tailnet hosts, comma separated: its IPv4 address (100.64.0.0/10) first, then its MagicDNS name
     (`aos-maxs-macbook-pro.tail1234.ts.net`). Empty for `lan`.
   - `tn`: the tailnet's name (often the account's email address), so the iPhone can say which account to sign in
     with.
   - `k`: the SHA-256 fingerprint of the Mac's ed25519 SSH host key in OpenSSH form without padding
     (`SHA256:...`, as `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` prints it).
   - `c`: 16 random bytes, base64url without padding. Only in the QR code, never sent.
3. The iPhone creates its keys (or reuses them): the SSH key, and a second P-256 key it signs its companion requests
   with (Secure Enclave on a device, keychain on the simulator). It connects to one of `h` on port `p` and sends one
   JSON line:
   `{"v":2,"device":"<device name>","key":"ecdsa-sha2-nistp256 AAAA...","sign":"<base64 X9.63 P-256 signing key>","proof":"<base64>"}`
   with proof = HMAC-SHA256(c, `"aos-pair-request\n" + key + "\n" + device + "\n" + sign`) (`c` as the raw 16 bytes;
   `key` and `sign` exactly as sent). The proof covers both keys: whoever sits between phone and Mac without the
   code can swap neither. Version 1 (no `sign`) is refused: "update aOS on the iPhone, then pair again".
4. The Mac checks the proof (constant-time) and the signing key (a point on P-256), keeps the signing key in its
   keychain (below, "Signed requests"), appends
   `no-agent-forwarding,no-X11-forwarding ecdsa-sha2-nistp256 AAAA... aos-companion:<id> <device name>`
   to `~/.ssh/authorized_keys` (folder 0700, file 0600, `<id>` = first 12 hex characters of the key's SHA-256) and
   answers one line: `{"ok":true,"user":"<user>","companion":"/Applications/aOS.app/Contents/MacOS/aos-companion","mac":"<base64>"}`
   or `{"ok":false,"error":"..."}`. The listener closes. `mac` is HMAC-SHA256(`c`, `"aos-pair-answer\n" + user +
   "\n" + companion`): the iPhone accepts the answer only with it (so nobody on the network can change the program
   the iPhone will run), and only a plain user name and an absolute path ending in `/aos-companion`. Connections
   from the workspace's own network are ignored (they can't use up the attempts).
5. The iPhone connects over SSH (user `u`, port `s`) and accepts the Mac only if its host key matches `k`. From then
   on the host key is pinned.

After a change of the way on the Mac, the person pairs the iPhone again (the Mac's Settings > Connection says so).

Unpairing: the iPhone forgets the host; aOS on the Mac lists paired devices and removes their line from
`authorized_keys` and their signing key from the keychain. A phone listed in `authorized_keys` without a signing key
(paired before version 2) shows "Pair it again to approve from it".

## Connecting (the iPhone's order, 2026-11-07)

The iPhone tries the Mac in this order (`ConnectionPlan`), each attempt a moment after the one before, and keeps the
first complete SSH login (the host key always the one pinned at pairing):

1. The same network: the hosts of `h` that aren't tailnet hosts, the one that worked last first.
2. The tailnet: the hosts of `t` (for a Mac paired before `t` existed, the tailnet addresses and names among `h`),
   first through aOS's own Tailscale node in the app (when it is set up and runs), then through the Tailscale app's
   VPN (when a utun interface has an address in 100.64.0.0/10 or fd7a:115c:a1e0::/48).
3. Bonjour: the Mac's SSH server as `_ssh._tcp` by the Mac's name.

aOS's own node on the iPhone (Tailnetkit, `Tailnet/tailnetkit`): set up from the pairing (when `w` is `aos`) or from
Settings > Connection, named `aos-<iPhone's name>`, signed in with the person's Tailscale account (the one of the
Mac's tailnet) in a web authentication session; the session closes when the node runs. It listens on nothing; the
app dials the Mac's tailnet address through it and gets a connected socket for SwiftNIO. It also reaches a Mac that
uses the Tailscale app, in the same tailnet.

Settings > Connection on the iPhone: how it is connected now (same network, aOS's Tailscale, the Tailscale app,
found by name), the Mac's way, whether the Tailscale app's VPN is on, aOS's Tailscale on this iPhone (name, address,
tailnet, key expiry; a warning when the Mac is in another tailnet), aOS's devices in the tailnet (online or last
seen, key expiry), Reconnect, Sign Out (this iPhone leaves the tailnet, its state is deleted) and the Tailscale admin
console. On the Mac, Settings > Connection shows the same for the Mac (see Docs/DESIGN.md, "Reaching the Mac on the
go").

## Signed requests

Any program of the same macOS user can connect to the app's agent socket and run `aos-companion`, and
`~/.ssh/authorized_keys` is the user's to edit: neither proves that a request comes from the paired iPhone. So every
request of the iPhone carries a signature with its signing key, and the app checks it before it does anything. The
agent's own (MCP) operations stay unsigned.

- **Where the Mac keeps the keys**: one generic password item per phone in the login keychain (service
  `dev.marquart.aos.phonekeys`, account = phone id, data = id, name, signing key, pairing date; not synchronizable;
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which only the data protection keychain honors, and that needs
  an entitlement aOS doesn't have). An item another program writes there, even with aOS on its access list or for
  "any application", carries that program's partition, so macOS would ask the person before aOS reads it. aOS reads
  these items with the keychain's dialogs switched off (`SecKeychainSetUserInteractionAllowed(false)`, the only
  switch that works for this dialog; LAContext's `interactionNotAllowed` doesn't): such an item doesn't count. Tested
  on macOS 27 with `security add-generic-password -A` and `-T`.
- **The signature**: `"auth":{"key":"<phone id>","ts":<Unix seconds>,"nonce":"<16 random bytes, base64url>","sig":"<base64 r||s>"}`
  in the request line, ECDSA P-256 with SHA-256 over these lines (UTF-8, joined with `\n`, no newline at the end):

      aos-companion-v1
      op=<the app's op: companion.hello|companion.status|companion.subscribe|companion.screen|companion.type|companion.display|companion.mac.status|companion.mac.sleep|...|signin.answer|help.done|approval.answer>
      key=<phone id>
      ts=<seconds>
      nonce=<nonce>
      request=<request id or empty>
      decision=<login|fill|code|decline for signin.answer, allow|deny for approval.answer, done for help.done, else empty>
      login=<Bitwarden item id or empty>
      host=<signin.answer: the request's website, or empty>
      target=<companion.screen: mac|workspace, or empty>
      data=<lowercase hex SHA-256 over "<name>:<UTF-8 byte count>:<value>\n" for each of username, password, totp, text, reply that is present>

  The Overview's ops ("The Mac from the iPhone", below) are signed the same way: `op` is "companion." and the
  phone's op (`companion.mac.sleep`), a parameter travels only in `text` and so is covered by `data`.

  No value may contain a line break (refused). The app derives `decision` and `data` from the request's fields the
  way it acts on them, so a changed field breaks the signature. `reply` (since 2026-11-07) is the one-time key a
  workspace `screen` request carries ("The workspace's screen login" below); requests without it sign exactly what
  they signed before.
- **The checks** (`CompanionGate` in AOSKit): a known phone id, a valid signature with that phone's key, `ts` within
  120 s of the Mac's clock, a nonce not seen before (kept in memory while its time is in the window, at most 4096).
  For `signin.answer` the signed `host` must be the website of the open request. Refusals are logged by reason (no
  values) and answered with `ok: false`, the message and a `code`: `pair-again` (not signed, or no key for this phone
  id), `clock`, `invalid`. The iPhone shows `pair-again` as "Pair again to keep approving from this iPhone." with a
  Pair Again button.
- **Events**: `aos-companion` polls them by itself, so the iPhone signs `subscribe` and the app answers it with a
  random subscription (32 bytes) that only that `aos-companion` keeps, in memory. It polls `companion.events` with it.
  A subscription ends when unused for 5 minutes, after 24 hours, when the phone is removed, or when the app restarts;
  `aos-companion` then sends `{"event":"subscription","state":"ended"}` and the iPhone subscribes again, signed.
- Reference vectors for both sides: AOSKit `CompanionSignatureTests` and iOS `SignedRequestTests` (the text above for
  a `login` answer, a signature over it with the private key 01..20, the `data` digests).

## Companion API (over SSH)

The iPhone runs `"<companion>" serve` in an exec channel. Both directions speak JSON lines (UTF-8, one object per
line). Requests carry an `id`; answers repeat it with `ok` and either a result or `error` (and `code` when the Mac
refused a signature, see above). Every request carries `auth` (left out below). The Mac sends events without `id` at
any time after `subscribe`.

Requests:
- `{"id":1,"op":"hello","app":"<version>","device":"<name>"}` -> `{"id":1,"ok":true,"mac":"<name>","aos":"<version>","features":["mac.status",...,"term"]}`
  (the Mac shows the name it has from pairing, not this one; `features` lists the Overview's ops and `term`, the
  terminal sessions; an older Mac sends none)
- `{"id":2,"op":"status"}` -> `{"id":2,"ok":true,"workspace":{"state":"stopped|starting|open|closing","purpose":"...","until":"<ISO date>"},"sessions":[{"title":"...","state":"..."}]}`
- `{"id":3,"op":"subscribe"}` -> `{"id":3,"ok":true}`, then events.
- `{"id":4,"op":"screen","target":"mac"}` -> `{"id":4,"ok":true,"host":"127.0.0.1","port":5900}` (no credentials:
  the user types their Mac account name and password once, the app keeps them in its keychain).
- `{"id":4,"op":"screen","target":"workspace","reply":"<base64 X9.63 P-256 key>"}` ->
  `{"id":4,"ok":true,"sealed":{"v":1,"key":"<base64 X9.63>","box":"<base64>"}}`: the workspace's screen login, only
  as ciphertext for this request ("The workspace's screen login" below). Opened, the box is
  `{"host":"<VM address>","password":"...","port":5900,"username":"aos"}`; the iPhone opens a direct-tcpip channel to
  host:port through the same SSH connection. A request without `reply` (an older iPhone app) gets `ok: false` with
  `code: "update"`; an answer without `sealed` (an older Mac) is refused by the iPhone. Neither side falls back to
  plaintext.
- `{"id":5,"op":"signin.answer","request":"<request id>","host":"<the request's host>","login":"<Bitwarden item id>"}`
  (the user approved one of the request's `logins`; the Mac gets it from Bitwarden), or
  `{"id":5,"op":"signin.answer","request":"<id>","host":"...","username":"...","password":"...","totp":"123456"}`
  (another password app's AutoFill), or `{"id":5,"op":"signin.answer","request":"<id>","host":"...","totp":"123456"}`
  (a code typed by hand), or `{"id":5,"op":"signin.answer","request":"<id>","host":"...","decline":true}` ->
  `{"id":5,"ok":true}`. A `login` that wasn't offered with the request, one without `totp` for a `code` request, or
  a `host` other than the request's is refused (`ok: false`).
- `{"id":6,"op":"help.done","request":"<id>"}` -> `{"id":6,"ok":true}`
- `{"id":8,"op":"type","text":"Grüße 😀"}` -> `{"id":8,"ok":true}` (types into the workspace; text beyond ASCII goes
  through the guest's clipboard, as for the agent)
- `{"id":9,"op":"display","target":"workspace","text":"1200x2322@2"}` -> `{"id":9,"ok":true,"width":1200,"height":2322,"scale":2,"lease":45}`
  (signed like `type`: `target`, and `text` in `data`). While the iPhone shows the workspace, its display takes the
  phone's shape: `text` is `WIDTHxHEIGHT@SCALE` in pixels (scale 2: macOS draws 2 pixels per point; the Mac uses 160
  pixels per inch for it, at which macOS picks exactly that, and 110 for scale 1), or `reset` for the workspace's own
  size (1280x800). The Mac keeps a size for `lease` seconds; the iPhone sends it again every 20 s while it shows the
  workspace and `reset` when it stops. Without a renewal (the phone went away, crashed or lost the network), when the
  workspace is suspended or after it was restored from a saved state, the Mac goes back to the workspace's own size.
  The agent's tools take the screen as it is; pictures bigger than 1280 pixels on the long side are scaled down for
  the agent, and its coordinates scaled back up.
- `{"id":7,"op":"approval.answer","request":"<id>","allowed":true}` -> `{"id":7,"ok":true}` (an agent that can't ask
  itself wants to open the workspace)

Events:
- `{"event":"signin","request":"<id>","agent":"Claude Code","host":"www.example.com","field":"username|password|code","purpose":"...","expires":"<ISO>","bitwarden":"unlocked|locked|off|unavailable","logins":[{"id":"<Bitwarden item id>","name":"Example","username":"max@example.com","totp":true}]}`
  (`field`: where the agent clicked. For `code` the answer carries `totp` only, or a `login` with `totp: true`, whose
  current code the Mac gets from Bitwarden; for `password` the user name is filled too if the page has an empty user
  name field before it.
  `bitwarden`: `unlocked`: `logins` are the user's Bitwarden logins for the site (maybe none); `locked`: the user is
  signed in to Bitwarden in aOS but has to unlock it on the Mac first; `off`: no Bitwarden in aOS (AutoFill only);
  `unavailable`: Bitwarden didn't answer. Missing (an older Mac) counts as `off`. `logins` never carry a password
  or an authenticator key; `totp` says the login has a key.
  A `signin` event with a request id the phone already has replaces that request: the Mac sends the request again
  when its logins change, for example after Bitwarden was unlocked on the Mac or synced.)
- `{"event":"signin.closed","request":"<id>","result":"filled|declined|expired|failed"}`
- `{"event":"help","request":"<id>","agent":"...","purpose":"...","region":{"x":0,"y":0,"w":0,"h":0}}`
- `{"event":"help.closed","request":"<id>"}`
- `{"event":"approval","request":"<id>","agent":"...","purpose":"...","minutes":15,"expires":"<ISO>"}`
- `{"event":"approval.closed","request":"<id>","result":"allowed|declined"}`
- `{"event":"mac","state":"unavailable","detail":"..."}` (aos-companion can't reach the app; it retries)
- `{"event":"workspace","state":"..."}`
- `{"event":"subscription","state":"ended"}` (the app ended the subscription; the iPhone sends a new signed
  `subscribe`)

A phone that subscribes first gets the questions still open, then everything new. `aos-companion` runs as long as
the exec channel is open; the Mac counts a phone as connected while it polled within the last 45 s. The Mac sends a
`workspace` event when the workspace starts, opens or closes (`stopped|starting|running|open|closing|failed`).

## The Mac from the iPhone (Overview)

One signed op reads, one signed op per action changes (AOSKit `CompanionControl`; checked by `CompanionGate` like
every phone request: signature, 2 minutes, nonce). Every answer carries the new `status`. A refusal is `ok: false`
with `error` (English) and `code`, which the phone says in its own words.

- `{"id":10,"op":"mac.status"}` -> `{"id":10,"ok":true,"status":{...}}` with
  - `power`: `{"source":"ac|battery|ups|unknown","battery":76,"charging":false,"minutes":312,"lid":"open|closed|none","thermal":"nominal|fair|serious|critical"}`
    (`minutes`: until empty on battery, until full while charging, when macOS knows; no `battery` on a Mac without one)
  - `awake`: `{"setting":"off|lidOpen|lidClosed","holding":true,"lidClosedMode":false,"blocker":"cloupi|nothingToKeep|helperNotReady|lowBattery|thermal","helper":"enabled|requiresApproval|notRegistered|notFound","otherService":false}`
    (Settings > General > Staying awake; `holding`: aOS's helper holds the Mac for a closed lid now)
  - `workspace`: `{"state":"stopped|starting|running|open|closing|failed","setupComplete":true,"purpose":"...","until":"<ISO>","error":"..."}`
    (`open`: an agent has it; `running`: started without an agent, from the phone or the setup)
  - `session`: `{"enabled":true,"state":"running|starting|restarting|waitingForNetwork|needsLogin|needsAttention|missingClaude|stopped|failed","detail":"...","since":"<ISO>"}`
    (aOS's own Claude Code session)
  - `newChats`: `{"enabled":true,"state":"off|waitingForNetwork|starting|running|needsLogin|needsTrust|missingClaude|restarting"}`
  - `kept`: `{"enabled":true,"running":2}` (kept conversations)
  - `bitwarden`: `{"state":"unlocked|locked|signedOut|needsHelper|unknown","until":"<ISO, if it locks by itself>"}`
- `mac.sleep` -> `{"ok":true,"sleeping":true,"after":1.5,"status":...}`: the Mac sleeps 1.5 s later (the answer goes
  out first). With aOS's lid-closed hold the helper first sets `pmset disablesleep` back, and aOS holds nothing until
  a screen comes on again (a dark wake doesn't keep the Mac up). Refused when sleep stays off: `sleep-disabled`
  (another program set `disablesleep`), `other-service` (Cloupi's wake daemon owns sleep and has it off),
  `sleep-held` (aOS's helper didn't answer in time).
- `mac.display-off` (`pmset displaysleepnow`; macOS locks the screen if it asks for the password after the display
  sleeps).
- `{"op":"mac.stay-awake","text":"off|lidOpen|lidClosed"}`: the setting; `other-service` while Cloupi owns sleep.
  "Also with the lid closed" registers the helper; macOS may still want the person's yes in Login Items
  (`awake.helper` says so).
- `workspace.start` (`not-set-up` before the setup is done; started without an agent lease: the agent's tools still
  need its own `workspace_open`), `workspace.stop` (closes it like the agent's `workspace_close`, also when an agent
  has it: the phone asks first).
- `bitwarden.lock`, `session.restart` (`no-session` when aOS's background process isn't running).

## Terminal sessions

The Terminal tab's shell on the paired Mac outlives the connection. The phone opens a session channel with a pseudo
terminal (pty-req) and runs, through the login shell, `'<companion>' term attach [--id <id> [--have <offset>]]`.
`aos-companion term attach` connects to the session's holder (`term hold`, a process of its own, started by the first
attach: setsid, so the SSH connection closing doesn't reach it) over `run/terms/<id>.sock` (folder 0700, peer uid
checked), puts its terminal into raw mode and relays bytes; terminal size changes reach the shell (SIGWINCH of the
client's terminal). One client at a time: a new one takes over (the old one hears `taken`).

The client tells the phone where the output starts with a note on the terminal, `ESC ] 7730 ; <JSON> BEL` (the phone
takes notes out; other terminals ignore an OSC they don't know):

    {"t":"start","id":"3fa9c1d2","from":12345,"reset":false,"prefix":"<base64>","created":"<ISO>","new":false}
    {"t":"end","why":"exited|ended|taken|lost","status":0}

- `from`: the offset of the next output byte. The phone counts every byte after the start note (notes don't count)
  and attaches again with `--have <that count>`: it gets exactly what it missed (the holder keeps the last MB).
- `reset: true` (no `--have`, or it missed more than the holder keeps): the phone resets its terminal, applies
  `prefix` (escape sequences for the modes in effect where the replay begins: alternate screen, cursor keys, keypad,
  mouse, bracketed paste, keyboard protocol, cursor), then gets the last 256 KB from a point between two sequences,
  after a line break where there is one; the program in the foreground gets SIGWINCH and draws itself again.
- `new: true` with `gone`: the session asked for had ended (the Mac restarted, someone ended it); this one is new.
- `end`: `exited` (the shell ended; exit status), `ended` (someone ended it), `taken` (another device attached),
  `lost` (the holder went away). Without an end note the connection dropped: the phone attaches again.

`'<companion>' term list --json` -> `{"sessions":[{"id":"3fa9c1d2","pid":123,"shell":124,"created":"<ISO>","attached":true,"since":"<ISO>","lastOutput":"<ISO>","from":"ssh 192.168.178.31","command":"zsh","cwd":"/Users/max","title":"...","cols":80,"rows":24}]}`
and `'<companion>' term end <id>` -> `{"ok":true}` (`{"ok":false,"gone":true}`) run in exec channels. Ending sends
SIGHUP to the program in the foreground and to the shell, as closing a terminal window does, SIGKILL 3 s later. A Mac
holds at most 16 sessions. These commands aren't companion requests and aren't signed: the phone's SSH login can run
any command as the user anyway, and a signature can't protect a shell from the user's own processes. An older
aos-companion without `term` exits with its usage (status 2): the phone then opens a plain shell.

## The workspace's screen login (2026-11-07)

The answer to `screen` for the workspace carries the guest account's password. It passes `aos-companion` and the
app's agent socket, and any program of the Mac's user can stand in for either. So it travels sealed to the phone
(`ScreenSeal`: AOSKit/Sources/AOSKit/Companion/ScreenSeal.swift on the Mac, iOS/Sources/Core/ScreenSeal.swift on the
iPhone):

1. The iPhone makes a fresh P-256 key-agreement key for this one request (CryptoKit, in memory only) and sends its
   public half as `reply`. The signature covers it (`data`), so a relay can't swap in its own key, and can't strip it
   either (the Mac answers a request without one only with "update the app").
2. The Mac (after the usual checks: signature, 120 s window, nonce once) makes its own one-time key, does ECDH with
   the phone's, derives a 256-bit key with HKDF-SHA256 (salt `aos-screen-v1`, info below) and seals the login JSON
   with AES-GCM (random 12-byte nonce, the info as additional data). The answer holds only its public key and the box.
3. The iPhone opens it with its one-time key and the context of the request it signed; the key is gone afterwards.

The info binds the box to one request, these lines joined with `\n`:

    aos-screen-v1
    op=companion.screen
    key=<phone id>
    nonce=<the request's nonce>
    phone=<base64 of the phone's one-time key>
    mac=<base64 of the Mac's one-time key>

An answer kept from an earlier request doesn't open (other nonce, other phone key); a changed box fails the GCM tag.
Reference vector for both sides (AOSKit `ScreenSealTests`, iOS `SealedScreenLoginTests`, also computed with Python's
`cryptography`): phone key 01..20, Mac key 21..40, GCM nonce 00..0b, phone `4853150ceae1`, nonce
`AAECAwQFBgcICQoLDA0ODw`, plaintext `{"password":"geheim"}`.

What it doesn't do: the Mac's one-time key isn't vouched for by anything the phone trusts. A program in
aos-companion's place can't read the login, but it could answer with a box of its own (sealed to the phone's key it
saw), pointing the phone at a screen it serves; what the person then types there would go to it. Closing that needs a
key of the Mac app the phone learns at pairing, signing these answers (Docs/DESIGN.md, "What this does and doesn't
promise").

## Matching logins

A Bitwarden login matches a request for host H when the host of one of its URIs equals H or is a parent domain of H
that still has at least two labels (`amazon.de` matches `www.amazon.de`; `login.tum.de` does not match
`campus.tum.de`; `de` matches nothing; IP addresses only match exactly). The Mac (`HostMatching` in AOSKit) applies
it to what `bw list items --url https://H` returns (Bitwarden's own matching, which is broader), leaves out logins with
Bitwarden's "master password re-prompt" (aOS can't ask for the master password on the phone), and checks the rule
again right before it fills a login.

## Filling in the workspace (Mac side)

The agent clicks into the sign-in field and calls `sign_in(purpose)`. aOS asks the helper in the workspace (aOS
Helper, an app with the Accessibility permission, installed and checked by code signature) which field has the focus
and on which website; only a user name, password or one-time code field counts. aOS asks Bitwarden for the logins
that match the site, blocks all other workspace tools while the request runs, shows the request on the Mac and sends
it to the iPhone; whoever answers first wins. For an approved Bitwarden login the Mac gets user name and password
(`bw get item`) or the current one-time code (`bw get totp`) right then. The helper types into the workspace only if
the focus is still on that website, and submits. The agent gets only the result. DevTools are off in the workspace's
Chrome, so a filled password can't be read back.

## iPhone app structure

- XcodeGen spec `iOS/project.yml`, target `aOS` (bundle `dev.marquart.aos.ios`, iOS 27), packages: `AOSKit`
  (local, products `AOSRFB` and `AOSTailnet`), Citadel (SSH, on SwiftNIO SSH), SwiftTerm; `Tailnetkit.xcframework`
  (aOS's Tailscale node, a C library built from `Tailnet/` by iOS/generate.sh); the framework target `ScreenClient` (Open
  Screen Sharing's session code with its Go library libsharing, GRDB, swift-perception, swift-atomics). Widget
  extension `AOSWidgets` (`dev.marquart.aos.ios.widgets`): the Live Activity of the open terminals.
- Tabs: Overview (Mac with battery, lid and staying awake, requests, workspace, aOS's Claude Code session and
  Bitwarden, with their actions), Terminal (the Mac's sessions survive the connection), Screen; settings from the
  Overview.
- German and English (string catalogs), German first for Max.
- Trust in the design: what is where, said plainly ("Your passwords stay in Bitwarden. You approve every sign-in with
  Face ID."), lock and shield symbols only where they are true, no dark patterns, every approval shows who asks for
  what and which login it gives.
