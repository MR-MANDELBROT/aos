# aOS for iPhone (companion)

The iPhone app of aOS. Same name and brand as the Mac app ("aOS", indigo and mint, Liquid Glass). It gives the
user, wherever they are:

- **Sign-ins for the agent** ("agentic passwords"): the agent in the workspace needs to sign in, the iPhone shows the
  request, the user approves with Face ID, aOS fills the sign-in into the workspace. The agent never sees the
  password.
- **Terminal**: SSH to the paired Mac (and other hosts the user adds).
- **Screen**: the paired Mac's screen and the aOS workspace, live, with touch, keyboard and trackpad gestures.
  Same screen sharing code as the Mac app (`AOSKit/Sources/AOSRFB`).
- **Help requests**: when the agent asks for help (a captcha, a sign-in it can't do), the request opens the
  workspace screen on the iPhone.
- **Settings**.

## Decisions (2026-11-06, made while Max slept; all reversible)

- **Not Bitwarden-branded.** Bitwarden's name and logo are trademarks, its iOS app is GPL and its SDK has its own
  license. aOS is our own app with our own UI.
- **Where the passwords live: aOS's own vault on the iPhone ("Tresor")**, in the iOS keychain, this device only,
  every read behind Face ID (or the device passcode). Import from a Bitwarden export (JSON or CSV, unencrypted) once,
  then the export should be deleted; the app says so. This is what makes the one-tap agentic flow possible: the app can
  pick the matching login by itself.
  Plus, for users who keep their passwords elsewhere: the approval sheet has username and password fields with iOS
  AutoFill, so Bitwarden's (or 1Password's, or Apple's) AutoFill extension fills them, with that app's own Face ID.
  Later, when Bitwarden ships Agent Access (open protocol, github.com/bitwarden/agent-access), aOS can use the
  user's Bitwarden vault directly without a fork.
- **Connection: SSH.** The Mac's Remote Login (OpenSSH) carries everything: the terminal, the companion API (an exec
  channel running `aos-companion serve`), and the screens (direct-tcpip channels to 127.0.0.1:5900 for the Mac and
  to the workspace VM). No new server, no listening port beyond OpenSSH, strong crypto, pinned host key. Outside the
  home network the user needs a way to reach the Mac (Tailscale or another VPN); the app shows this plainly.
- **Keys**: the iPhone's SSH key is a P-256 key in the Secure Enclave (software key in the keychain on the simulator).
  It never leaves the device.
- **Pairing without typing a password** (below): the Mac shows a QR code, the iPhone scans it, done.
- **Notifications** (sign-in and help requests while the app is closed): phase 2, through CloudKit (free, no server of
  ours, end-to-end with the user's iCloud). Until then the app shows requests while it is open and connected.

## Pairing

1. aOS on the Mac ("Pair" next to iPhone in the menu, or Settings > iPhone) checks that Remote Login is on (port 22 answers) and otherwise opens
   System Settings > General > Sharing. It starts a pairing listener: TCP on a random port, advertised over Bonjour
   as `_aos-pair._tcp`, open for 3 minutes and for one pairing.
2. It shows a QR code with the URL
   `aos-pair://v1?n=<Mac name>&h=<host1>,<host2>&p=<pairing port>&s=22&u=<user>&k=<host key fingerprint>&c=<code>`
   (all values percent-encoded).
   - `h`: names and addresses to try in order: `<name>.local`, IPv4 addresses of active interfaces, Tailscale name.
   - `k`: the SHA-256 fingerprint of the Mac's ed25519 SSH host key in OpenSSH form without padding
     (`SHA256:...`, as `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` prints it).
   - `c`: 16 random bytes, base64url without padding. Only in the QR code, never sent.
3. The iPhone creates its key, connects to one of `h` on port `p` and sends one JSON line:
   `{"v":1,"device":"<device name>","key":"ecdsa-sha2-nistp256 AAAA...","proof":"<base64 HMAC-SHA256(c, key + "\n" + device)>"}`
   (`c` as the raw 16 bytes; `key` exactly as sent).
4. The Mac checks the proof (constant-time), appends
   `no-agent-forwarding,no-X11-forwarding ecdsa-sha2-nistp256 AAAA... aos-companion:<id> <device name>`
   to `~/.ssh/authorized_keys` (folder 0700, file 0600, `<id>` = first 12 hex characters of the key's SHA-256) and
   answers one line: `{"ok":true,"user":"<user>","companion":"/Applications/aOS.app/Contents/MacOS/aos-companion","mac":"<base64>"}`
   or `{"ok":false,"error":"..."}`. The listener closes. `mac` is HMAC-SHA256(`c`, `"aos-pair-answer\n" + user +
   "\n" + companion`): the iPhone accepts the answer only with it (so nobody on the network can change the program
   the iPhone will run), and only a plain user name and an absolute path ending in `/aos-companion`. Connections
   from the workspace's own network are ignored (they can't use up the attempts).
5. The iPhone connects over SSH (user `u`, port `s`) and accepts the Mac only if its host key matches `k`. From then
   on the host key is pinned.

Unpairing: the iPhone forgets the host; aOS on the Mac lists paired devices and removes their line from
`authorized_keys`.

## Companion API (over SSH)

The iPhone runs `"<companion>" serve` in an exec channel. Both directions speak JSON lines (UTF-8, one object per
line). Requests carry an `id`; answers repeat it with `ok` and either a result or `error`. The Mac sends events without
`id` at any time after `subscribe`.

Requests:
- `{"id":1,"op":"hello","app":"<version>","device":"<name>"}` -> `{"id":1,"ok":true,"mac":"<name>","aos":"<version>"}`
- `{"id":2,"op":"status"}` -> `{"id":2,"ok":true,"workspace":{"state":"stopped|starting|open|closing","purpose":"...","until":"<ISO date>"},"sessions":[{"title":"...","state":"..."}]}`
- `{"id":3,"op":"subscribe"}` -> `{"id":3,"ok":true}`, then events.
- `{"id":4,"op":"screen","target":"mac"|"workspace"}` -> `{"id":4,"ok":true,"host":"127.0.0.1","port":5900,"username":"...","password":"..."}`
  (for `workspace`: the VM's address and its screen sharing account; the iPhone opens a direct-tcpip channel to
  host:port through the same SSH connection. For `mac` there are no credentials: the user types their Mac account
  name and password once, the app keeps them in its keychain.)
- `{"id":5,"op":"signin.answer","request":"<request id>","username":"...","password":"...","totp":"123456"}` or
  `{"id":5,"op":"signin.answer","request":"<id>","decline":true}` -> `{"id":5,"ok":true}`
- `{"id":6,"op":"help.done","request":"<id>"}` -> `{"id":6,"ok":true}`
- `{"id":8,"op":"type","text":"Grüße 😀"}` -> `{"id":8,"ok":true}` (types into the workspace; text beyond ASCII goes
  through the guest's clipboard, as for the agent)
- `{"id":7,"op":"approval.answer","request":"<id>","allowed":true}` -> `{"id":7,"ok":true}` (an agent that can't ask
  itself wants to open the workspace)

Events:
- `{"event":"signin","request":"<id>","agent":"Claude Code","host":"www.example.com","field":"username|password|code","purpose":"...","expires":"<ISO>"}`
  (`field`: where the agent clicked. For `code` the answer carries `totp` only; for `password` the user name is filled
  too if the page has an empty user name field before it.)
- `{"event":"signin.closed","request":"<id>","result":"filled|declined|expired|failed"}`
- `{"event":"help","request":"<id>","agent":"...","purpose":"...","region":{"x":0,"y":0,"w":0,"h":0}}`
- `{"event":"help.closed","request":"<id>"}`
- `{"event":"approval","request":"<id>","agent":"...","purpose":"...","minutes":15,"expires":"<ISO>"}`
- `{"event":"approval.closed","request":"<id>","result":"allowed|declined"}`
- `{"event":"mac","state":"unavailable","detail":"..."}` (aos-companion can't reach the app; it retries)
- `{"event":"workspace","state":"..."}`

A phone that subscribes first gets the questions still open, then everything new. `aos-companion` runs as long as
the exec channel is open; the Mac counts a phone as connected while it polled within the last 45 s.

## Matching logins

A vault login matches a request for host H when the host of one of its URIs equals H or is a parent domain of H that
still has at least two labels (`amazon.de` matches `www.amazon.de`; `login.tum.de` does not match `campus.tum.de`;
`de` matches nothing). The Mac checks the same rule against the page it fills.

## Filling in the workspace (Mac side)

The agent clicks into the sign-in field and calls `sign_in(purpose)`. aOS asks the helper in the workspace (aOS
Helper, an app with the Accessibility permission, installed and checked by code signature) which field has the focus
and on which website; only a user name, password or one-time code field counts. aOS blocks all other workspace
tools while the request runs, shows the request on the Mac and sends it to the iPhone; whoever answers first wins.
With the answer the helper types into the workspace only if the focus is still on that website, and submits. The
agent gets only the result. DevTools are off in the workspace's Chrome, so a filled password can't be read back.

## iPhone app structure

- XcodeGen spec `iOS/project.yml`, target `aOS` (bundle `dev.marquart.aos.ios`, iOS 27), packages: `AOSKit`
  (local, product `AOSRFB`), Citadel (SSH, on SwiftNIO SSH), SwiftTerm.
- Tabs: Overview (Mac, workspace, requests), Terminal, Screen, Vault; settings from the Overview.
- German and English (string catalogs), German first for Max.
- Trust in the design: what is where, said plainly ("Your passwords stay on this iPhone, locked with Face ID"),
  lock and shield symbols only where they are true, no dark patterns, every approval shows who asks for what.
