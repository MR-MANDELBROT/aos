# aOS design

aOS productizes a setup that ran by hand on one Mac (a Tart VM, a Python MCP server, shell installers and a launchd
supervisor around Claude Code). It is an extension for the user's own coding agent: aOS brings the workspace and an
MCP server; the agent (Claude Code, Codex CLI, Gemini CLI, VS Code, Cursor, Windsurf, opencode, anything with MCP)
brings the model and the account. Goals for version 1: one download, a setup that a non-developer finishes in about an
hour (most of it waiting for the macOS download), no Terminal, no sudo, no server of our own.

## Agents and approval

`AgentIntegration` knows how each agent adds an MCP server: Claude Code (`claude mcp add --scope user` plus rules in
`~/.claude/settings.json`: allow `mcp__aos__*`, ask `mcp__aos__workspace_open`), Codex (`codex mcp add`, then
`tool_timeout_sec = 900` in `config.toml`, Codex waits only 60 s by default), Gemini CLI (`gemini mcp add --scope
user --timeout`), VS Code (`code --add-mcp`), Cursor, Windsurf and opencode (their JSON files, merged, with a backup;
files with comments are left alone and the user gets a snippet), anything else (snippet to copy). The server's
environment carries `AOS_AGENT` and `AOS_APPROVAL`.

Opening the workspace needs the user's yes, one of three ways (`AOS_APPROVAL`):
- `agent`: the agent asks itself (Claude Code's ask rule, which Remote Control forwards to the phone; VS Code's tool
  confirmation).
- `auto`: the MCP server asks through the agent with MCP elicitation (`elicitation/create`, a yes/no form) if the
  client declared the capability; otherwise the app asks on the Mac.
- `mac`: the app always asks on the Mac (floating window plus notification, 5 minutes, then no).
The app also asks on the Mac for any request that doesn't say how it was approved.

## Processes (with the optional Claude Code session)

```
Claude app (phone) ──Remote Control──▶ claude (pty) ◀── aos-session (LaunchAgent, KeepAlive)
                                          │ stdio
                                          ▼
                                      aos-mcp ──unix socket (0600, peer uid checked)──▶ aOS.app
                                                                                         ├─ VMHost (Virtualization.framework)
                                                                                         ├─ RFBClient ──VNC──▶ screensharingd (guest)
                                                                                         └─ SSH (root, keys) ──▶ guest kit
```

- **aOS.app** is a menu bar app (LSUIElement), registered as login item (`SMAppService.mainApp`). It hosts the VM, so
  its windows can show the guest with `VZVirtualMachineView` (setup step, help requests).
- **aos-session** is registered with `SMAppService.agent` from `Contents/Library/LaunchAgents`. It runs
  `claude --remote-control <name>` (plus `--continue` once a conversation exists) in the session folder
  (`~/Library/Application Support/aOS/Session`), waits for `api.anthropic.com:443` first, restarts with back-off
  (5 s to 2 min; after five quick exits it stops and waits for the app), and relays the terminal over
  `run/session.sock`. It recognizes Claude Code's questions (sign-in, trust, Remote Control) and reports them in
  `run/session.json`; the app then asks the user to open the session window and answer there.
- **aos-mcp** is registered by `claude mcp add --scope local` for the session folder. `.claude/settings.local.json`
  there allows `mcp__aos__*` and asks for `mcp__aos__workspace_open`; `CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS=0`
  keeps long tool calls (help requests) in the foreground.
- **aos-powerd** (optional) is a root LaunchDaemon from `Contents/Library/LaunchDaemons`, registered with
  `SMAppService.daemon` once the user wants the Mac awake with the lid closed or answers the hotspot question
  (see "Staying awake, freezing and the hotspot").
- **aos-tailnet** (Go, in Contents/MacOS) is aOS's own Tailscale node; aos-powerd runs it as the hidden user
  `_aostailnet` when the person chose "aOS sets up Tailscale" (see "Reaching the Mac on the go").

## The session as a persistent agent (routines, reminders, notes)

Since build 17 aOS's own session can stand in for a persistent agent such as Cloupi's (Settings > Claude Code; the
iPhone shows and edits the routines under Settings > Routines and the next one in the Overview):

- **Folder, effort, permissions, environment**: `sessionFolder` (empty: aOS's own folder; another folder brings its own
  `.claude` and `.mcp.json`, aOS changes nothing there), `sessionEffort` (`--effort`), `sessionPermissionMode`
  (`--permission-mode` auto, acceptEdits or plan), `sessionEnvFiles` (`KEY=VALUE` lines, `export` and quotes
  allowed; names logged, values never), `sessionStartMessage` (sent after each start).
- **Its own conversation**: after a start aOS reads Claude Code's registry (`~/.claude/sessions/<pid>.json`) and
  keeps the conversation id in `run/session-conversation.json` (with the folder); the next start resumes exactly that
  one (`--resume`), never just the newest one in the folder (the person may have started one there in the Claude
  app). Two restarts within 30 minutes start fresh; so does "Start Fresh" (socket command `ESC ] aos;fresh BEL`).
- **Routines** (`AgentSettings.routines`: name, cron with five fields in local time, prompt, on/off): `SessionMessenger`
  checks every 10 s; a routine missed while the Mac slept comes up to 6 hours late, only its latest time; a new or
  changed routine starts from now. "Run Now" is `ESC ] aos;run;<id> BEL` (the iPhone: `companion.routines.run`).
- **Inbox** (`~/Library/Application Support/aOS/Inbox/*.json`, 0700): other programs leave `{"text", "at"?,
  "source"?}` (temporary name with a leading dot, then rename). With `at`: a reminder, delivered at its time, dropped
  more than 30 minutes late; without: a note, delivered as soon as possible. Unreadable files move to `Inbox/Invalid`.
- **Delivery**: a queue in `run/routines-state.json` (survives restarts); its head is typed into the session's
  terminal as one bracketed paste plus Enter, only while Claude Code's registry says `idle` (not `busy`, not `waiting`,
  which covers permission and question dialogs). Without a reaction after 10 s, Enter once more. Each message starts
  with a header line: `[aOS routine "<name>", scheduled <time>]` (`, delivered late …` after sleep), `[aOS reminder
  for <time> from <source>]`, `[aOS note from <source>]`, `[aOS: the session just started]`.
- **Status** for the app and the iPhone: `run/routines.json` (next times, reminders waiting, queued, recently sent).

Cloupi (2026-11-09): folder `~/cloupi`, effort max, mode auto, environment from `~/cloupi/config/aos-session.env` and
`~/cloupi/state/private/cloupi.env`, its nine routines from `config/crons.json`; its one-shots and notices reach the
inbox through `~/cloupi/mac/bin/aos-bruecke.mjs` (LaunchAgent `de.cloupi.aos-bruecke`, every minute). The old agent
(`de.cloupi.agent`, Cloupi Agent.app) is unloaded. Apple Mail's automation permission belongs to `aos-session` now.

## Keeping conversations reachable (SessionKeeper)

The Claude desktop app runs a local Code session only while it works on it; once its process ends, the session goes
offline in the Claude app on the phone (Remote Control needs a running local process). `aos-session` also hosts
the keeper, when "keep conversations reachable" is on:

- **Which**: conversations from `~/.claude/projects` (title from `custom-title`/`ai-title` records, start folder and
  `entrypoint` from the start of the transcript, `bridge-session` = used Remote Control) that were started in the
  Claude app, used Remote Control and were active within `keepHours` (48 h); pinned ones always; at most `keepMax`
  (6). Never: archived or scheduled ones of the desktop app (its records in
  `~/Library/Application Support/Claude/claude-code-sessions`), ones with Remote Control switched off, ones the user
  excluded, aOS's own session folder, automation (`sdk-cli`). Terminal conversations only when pinned or with
  `keepTerminal`: tools like Cloupi manage their own terminal sessions.
- **How**: `claude --resume <id> --remote-control <title>` in the start folder, through the user's login shell
  (`exec`, so PATH is like a new terminal and the pid stays Claude Code's), in a pseudo terminal whose output is
  drained; the desktop app's permission mode is carried over, except bypassing permissions.
- **Never twice**: Claude Code's registry (`~/.claude/sessions/<pid>.json`, watched with a file system source) shows
  every running process with its session id. When another process (the desktop app, a terminal) opens the same
  conversation, the keeper ends its copy at once and takes over only 60 s after that process ended; "Remote Control
  not started here" in the output means the same. Children of an earlier keeper (run/keeper-children.json) are ended
  at start.
- **Ending**: SIGHUP (what closing a terminal sends, Claude Code exits cleanly on it), SIGTERM after 5 s, SIGKILL after
  15 s. Quick exits back off from 10 s to 30 min.
- Status in `run/keeper.json`; the app's settings (Claude Code tab) list the conversations with their state, pin and
  exclude.

## Staying awake, freezing and the hotspot

Settings > General > Staying awake (`AgentSettings.stayAwake`, migrated from the old `keepAwake`): Off, While the
lid is open, Also with the lid closed. `AwakePolicy` (AOSKit, tested) decides every two seconds in the app's
`PowerController` from the setting, whether something must stay reachable (aOS's own session or kept conversations
while the background process runs, or the workspace in use), the lid (`AppleClamshellState`), power source and
charge, thermal state, external screens, whether Cloupi is on the Mac, and whether the helper is allowed.

- **While the lid is open**: the app holds `PreventUserIdleSystemSleep`. Closing the lid sleeps the Mac.
- **Also with the lid closed**: measured on MacBookPro18,3 (Cloupi, ~/cloupi/mac/DESIGN.md 2), a closed MacBook on
  battery ignores every power assertion; only `pmset disablesleep 1` holds it, and that needs root. The helper
  **aos-powerd** sets it as a lease: the app renews it every 30 s for 180 s; the helper checks every 5 s and releases
  it when the lease ends (aOS quit or crashed), on battery below 10 percent, when the Mac gets critically hot, or when
  Cloupi appears. The hold starts while the lid is still open (set only when it closes, the Mac would already be
  asleep). `disablesleep` survives a restart, so the helper writes a marker
  (`/Library/Application Support/aOS/powerd-holding`) before setting it, and at boot (`RunAtLoad`) undoes a hold
  whose marker is left. It only ever undoes what it set: if `disablesleep` was already on, it holds without touching
  it. It exits after two idle minutes; launchd starts it again with the next message.
- **The helper's surface** (`PowerHelperXPC`, Mach service `dev.marquart.aos.powerd`): status, hold, apply the
  hotspot choice, join a network macOS already knows, restart airportd, Wi-Fi off and on (each at most every 4
  minutes), Bitwarden, the workspace's keys and disk, and since version 4 aOS's tailnet node. The listener's code signing requirement admits only aOS (`identifier "dev.marquart.aos"`, team
  S3725YB7V6), checked by the system for every message through the caller's audit token; the app requires the
  helper's signature (`aos-powerd`, same team) in turn. macOS asks the user once to allow it (Login Items &
  Extensions); the settings show its state and, only while macOS waits for that, a button to Login Items. Log:
  `/Library/Logs/aOS/powerd.log`.
- **With the lid closed** (held, no external screen):
  - **Freezing**: after 20 s with the lid closed and no input, aOS stops the user's Dock apps with SIGSTOP, with their
    child processes and the processes macOS holds them responsible for, and continues them with SIGCONT when the lid
    opens, a screen is connected, input arrives, the setting changes or aOS quits. Never frozen: aOS, Claude (the
    desktop app hosts Claude Code sessions), Cloupi, Finder and the system's tools, terminals and code editors
    (agents, Claude Code and builds run there), password managers, VPNs (the iPhone reaches the Mac through them),
    file providers (a frozen one hangs every program that opens its files), keyboard and mouse tools, and any app
    with `claude` or `aos-mcp` (an agent using the workspace) in its process tree. Menu bar apps are left as they
    are, and so are processes someone else stopped.
  - **Never left frozen**: the record `run/frozen.json` (pids with start times, and the process that froze them) is
    written before the first signal, and nothing is signalled whose start time doesn't match. aOS thaws what it lists
    at start, on SIGTERM, SIGINT and SIGHUP, and on quit; a crash signal handler continues the frozen pids (only
    kill(2)); aos-session thaws a record whose owner is gone every 15 s.
  - **Display**: while the Mac is held, macOS leaves the built-in display on when the lid closes (Cloupi measured up
    to the display sleep time, ~/cloupi/mac/DESIGN.md 32). aOS runs `pmset displaysleepnow` as the user after 2 s, at
    most every 20 s, not while the session is screen-shared.
  - **Network care** (`NetworkCarePolicy`, after Cloupi's sections 31, 36 and 37): offline for 20 s, every 45 s a scan
    by name for the user's hotspots and the first 12 known networks (names are hidden from processes without
    location access, root included, but a scan for a name finds it, and macOS's list of preferred networks has the
    names). The first known Wi-Fi network in range in macOS's order wins, else the hotspot; the helper joins with
    `networksetup -setairportnetwork` (password from the System keychain; success is an address, the message can
    say "Failed" and the Mac connects a moment later). A network whose join failed rests 45 s, 3 min, 10 min. Two
    failed joins of visible networks restart airportd (that clears its deny list), at most every 10 minutes; 4
    minutes without anything turn Wi-Fi off and on (then after 10, 20, 40, 60 minutes), with a marker so an
    interrupted cycle never leaves Wi-Fi off. Nothing while Wi-Fi is off (the user's choice), while the Mac has an
    address, or with the lid open (the user is there).
- **Cloupi**: when its wake daemon is on the Mac (`/Library/Application Support/cloupi-wake`,
  `/Library/LaunchDaemons/de.cloupi.waked.plist`, or launchd knows `system/de.cloupi.waked`), it owns sleep and Wi-Fi.
  aOS holds no assertion and freezes nothing, the helper refuses and never touches pmset or Wi-Fi, and the settings
  say "Another service takes care of this" (the user sees no product name). aOS never stops, changes or reads that
  service.

**Leaving the hotspot** (`AgentSettings.leaveHotspot`, on by default; lid open or closed): macOS never leaves a network
it is connected to for a better one. While the Mac has an iPhone hotspot address (172.20.10.x), aOS looks every 2
minutes by name for the known networks that aren't hotspots (macOS's order, first 12), takes the first one found with
at least -75 dBm and joins it through the helper; the helper counts the join only once the address is outside the
hotspot. A failed join rests like in network care.

**Updating aOS with the lid closed**: the helper exits when its program file is replaced. While it holds the Mac with
a valid lease it hands the hold over instead of releasing it: the marker gets `handover` (the lease, at least 5
minutes ahead), disablesleep stays, and the new helper, started by the new app's first call, takes the hold over
(`cleanUpEarlierRun`). Before that change the Mac fell asleep in the gap (2026-11-09).

**The iPhone hotspot.** The question (Settings > General > iPhone hotspot; in the setup under "Stay awake with the
lid closed") is "When needed: you switch it on on the iPhone" (recommended, also when unanswered) or "Connect
automatically" (`AgentSettings.hotspotJoin`). It applies only while the lid is closed (aOS's lid-closed mode): when
the lid closes the helper notes the user's own two settings (`/Library/Application Support/aOS/hotspot-before-lid.json`,
root) and sets the answer's; when the lid opens it writes the noted ones back and removes the note. With the lid open
macOS behaves as the user set it. The app asks for the restore once after every launch too, should an earlier run
have ended with the lid closed; a failed change is tried again after five minutes at the earliest (each one restarts
airportd).

| Answer (lid closed) | Auto-join of the user's hotspots | Ask to join hotspots |
|---------------------|----------------------------------|----------------------|
| When needed | off | Never |
| Automatically | on | Automatic |

How macOS 27 keeps both (found as a normal user on macOS 27.0, 26A428, MacBookPro18,3):
- Auto-join is the known-network property `AutoJoinDisabled` (`CWFNetworkProfilePropertyAutoJoinDisabledKey`) in
  airportd's store `com.apple.wifi.known-networks` (`CWFKnownNetworksStoreIdentifier`), the file
  `/Library/Preferences/com.apple.wifi.known-networks.plist` (root, 0600) with entries `wifi.network.ssid.<name>`; the
  user's own hotspots carry `PersonalHotspot`.
- Ask to join hotspots is `AutoHotspotMode` with `AskToJoin`, `Automatic` or `Never` (CoreWLAN
  `schemaStringForAutoHotspotMode`: 1, 2, 3) in airportd's global configuration (CoreWLAN `globalConfiguration()`,
  SystemConfiguration's `com.apple.airport.preferences.plist`; the sandbox denies a user process even reading it).
- Reading both works without privileges through airportd: CoreWLAN `CWGetAutoHotspotMode()` and CoreWiFi's known
  network profiles (names hidden without location access, the flags not). `aosctl power` prints them; on the
  development Mac: Never, 4 personal hotspots, auto-join on for all of them.
- Changing them through airportd needs Apple's private entitlements: its handler for "set auto hotspot mode" checks
  `com.apple.wifi.auto-hotspot` (seen in airportd's code), and the known-network calls belong to the
  `com.apple.private.corewifi` family. No other app can have them, and no command line covers either setting
  (`networksetup` has none; `airportd <interface> prefs` knows JoinMode and a few more, not these).
- So the helper writes the stores as root: the hotspot entries through CFPreferences (any user,
  `com.apple.wifi.known-networks`), `AutoHotspotMode` through SCPreferences (like the keys of airportd's own `prefs`
  verb). Then it restarts airportd (`launchctl kickstart -k`, as Cloupi's daemon does on this Mac) and reads the
  result back through airportd; if it didn't take, it writes once more and ends airportd with SIGKILL (so it can't
  write old values on its way out). The reply carries what macOS reports, the settings show it ("Now in macOS: …"),
  and if it didn't take they offer "Try Again" and "Open Wi-Fi Settings".
- Not verified, because it needs root: whether macOS 27 lets root read and write these two files (a user process
  gets "Operation not permitted" even for the world-readable airport preferences), whether `AutoHotspotMode` sits at
  the top level of the airport preferences, and whether airportd takes both after the restart. The helper reports
  the read-back result either way.

With "Only when I switch it on" and the lid closed, network care joins the hotspot while it broadcasts and the Mac
has no other network. A dormant iPhone hotspot sends no name, so broadcasting means the user switched it on (or has
the Personal Hotspot page open). Switched off, it disappears and the Mac stays disconnected; macOS doesn't join or
wake it by itself. With the lid open the user joins it from the Wi-Fi menu. Limits (Cloupi, ~/cloupi/mac/DESIGN.md
13 and 36): a closed Mac can't switch a dormant hotspot on ("AutoHotspot not allowed during dark wake", also with the
screen locked), and the iPhone ends its hotspot about 90 s after the last device left.

## aOS for iPhone (companion)

See Docs/COMPANION.md for the protocol. On the Mac:

- **Pairing** (`PairingSession`): a TCP listener on a random port with Bonjour `_aos-pair._tcp`, 3 minutes, one
  pairing, five wrong proofs end it. The QR code carries the Mac's addresses, the SHA-256 fingerprint of its ed25519
  host key, a 16-byte code, and the way on the go with the Mac's tailnet hosts (`w`, `t`, `tn`); the phone proves the code with HMAC-SHA256 over its SSH key, its name and its signing
  key, the Mac keeps the signing key in its keychain and appends the SSH key to `~/.ssh/authorized_keys`
  (`no-agent-forwarding,no-X11-forwarding`, marked `aos-companion:<id>`). Remote Login must be on; Settings > iPhone
  checks it and lists and removes paired phones (both keys go).
- **aos-companion serve** is what the phone runs over SSH: JSON lines, relayed to the app's agent socket; a second
  connection long-polls `companion.events`. Companion requests are not agent activity (they don't keep the workspace
  open). Neither aos-companion nor authorized_keys vouches for anything (any program of the user can run the one
  and edit the other): every phone request is signed with the phone's key, and `CompanionGate` in the app checks
  key, signature, time (2 minutes) and nonce before anything happens; event polls carry a subscription the app gave
  for a signed `subscribe` (Docs/COMPANION.md, "Signed requests").
- **CompanionHub** collects the events (sign-in, help, approval requests and their end); a phone that connects gets
  the open questions first. The menu shows whether a phone is connected (it asked within 45 s).
- **The Overview** (`CompanionControl`, Docs/COMPANION.md "The Mac from the iPhone"): a signed `mac.status` and one
  signed op per action (sleep, display off and on, staying awake, workspace start and stop, Bitwarden lock, restart of
  aOS's Claude Code session). What needs the app (staying awake, sleep) goes through `MacControls`, which `AppModel`
  implements; the display too, by default with AOSKit's `MacDisplayStatus.set(on:)` (tests put their own in, they run
  on a Mac someone uses); the rest is AOSKit's own. The display state is `CGDisplayIsAsleep` of each online screen
  (screen sharing's virtual display left out), read in the app, which runs in the person's GUI session. Starting the
  workspace from the phone gives no agent a lease: the agent's tools still need `workspace_open` and the person's yes.
- **Sleep from the phone with aOS's lid-closed hold**: `pmset disablesleep 1` (the helper's hold) keeps even
  `pmset sleepnow` from working. So the app first stops holding: no idle assertion, the lease released at once
  (`hold(0)`: the helper sets disablesleep back if it set it), then reads `pmset -g` until SleepDisabled is 0 (6 s at
  most) and runs `pmset sleepnow` 1.5 s after answering. Until a screen comes on again (`screensDidWake`: the person
  opened the lid or pressed a key) aOS holds nothing, so a dark wake doesn't keep the Mac up; if `willSleep` doesn't
  come within a minute, the hold returns. If SleepDisabled stays 1, someone else set it (aOS only ever undoes its own
  hold): the phone hears `sleep-disabled`, or `other-service` when Cloupi's daemon is on the Mac (aOS never touches
  it). Hotspot settings stay as they are on the way to sleep (writing them restarts airportd).

## Terminal sessions (aos-companion term)

The iPhone's terminal on the Mac survives the connection (the app in the background or killed, a new network):
macOS has no tmux, so aos-companion brings a small holder (Docs/COMPANION.md, "Terminal sessions"; AOSKit
`Terminal/`).

- **Holder** (`term hold`): one process per session, started by the first `term attach` with `posix_spawn` and
  `POSIX_SPAWN_SETSID` (no controlling terminal: sshd's hangup doesn't reach it), standard descriptors on /dev/null.
  It starts the user's login shell in a pseudo terminal (`forkpty`, argv[0] `-zsh`, the home folder, TERM
  xterm-256color, LANG from the Mac's region with UTF-8 when the SSH session brings none, `AOS_TERM_SESSION`), owns
  the master and listens on `run/terms/<id>.sock` (0700 folder, socket 0600, peer uid checked). One poll loop, no
  threads, no signal handlers but SIGTERM (ends the session like `term end`).
- **Output**: a 1 MB ring with absolute offsets. Whatever leaves the ring passes through a small terminal state tracker
  (`TermModes`: the parser's state, UTF-8, DEC private modes 1, 7, 25, 47/1047/1049, 1000-1016, 1004, 1007, 2004,
  keypad, cursor style, the kitty keyboard stacks, the window title), so the state at the ring's start is always
  known. A client that comes back with `--have N` gets exactly the bytes after N; one without (or behind the ring)
  gets a reset, the modes in effect where its replay starts, the last 256 KB from a safe point (a line break if one is
  near), and the program in the foreground gets SIGWINCH to draw itself again (vim, htop, less, Claude Code do; a
  shell redraws its prompt line). A client that falls behind while attached gets the same, in place.
- **Clients**: one at a time; a new attach takes over (after a network change, or when the iPhone app was closed in
  the background, the old SSH connection can linger on the Mac until its TCP times out). A client names its device
  (`--client`, the iPhone's phone id): the same device again replaces its older connection quietly (`replaced`), only
  another device takes the session (`taken`); `term list` says which device is attached. Input is queued for the shell
  without blocking the loop; a client's output is sent from the ring as its socket takes it (no queue per client).
- **Ending**: the shell exits (the holder sends what it wrote last, the reason and the status, removes its socket and
  exits), or `term end` / SIGTERM: SIGHUP to the foreground process group and the shell (as when a terminal window
  closes), SIGKILL after 3 s. Nothing ends sessions by age (that could kill a running job): the iPhone's Terminal tab
  lists them (`term list`) with the program in the foreground and its folder (libproc), and ends them on request.
  At most 16 at a time.
- Tested in AOSKit (`TermTests`): the tracker, the ring and its replays, frames, the holder in-process with /bin/sh,
  and the built binary end to end in a pseudo terminal (detach by hangup, come back with an offset, resize, takeover
  by another device and by the same one, end, exit).

## Reaching the Mac on the go (Tailscale)

Max's decision (2026-11-07): the iPhone reaches the Mac at home by itself; on the go through Tailscale, a private
network of the person's own devices (a "tailnet"). The setup step "On the go", right before pairing, always offers
all three ways, and recommends one by what it finds (`ReachAdvisor`, AOSTailnet, tested):

| Way (`ReachWay`, link `w`) | Recommended when | What aOS does |
|----------------------------|------------------|---------------|
| Your Tailscale app (`app`) | the Tailscale app runs on this Mac and is connected | reads its status, puts the Mac's tailnet address and MagicDNS name into the pairing code; the iPhone needs the Tailscale app too (same account) |
| aOS sets up Tailscale (`aos`) | otherwise | runs its own Tailscale node on the Mac (below) and in aOS on the iPhone; the person signs in once per device in the browser |
| Only on the same network (`lan`) | never (the fallback) | as before |

The choice is `AgentSettings.reachWay`; Settings > Connection shows it again with the state of the node of the way in
use (this Mac's tailnet name, addresses, tailnet, account, key expiry), aOS's devices in the tailnet (names starting
with `aos-`: online or last seen, key expiry) and the actions Reconnect, Sign Out (the device leaves the tailnet and
its keys are deleted) and the Tailscale admin console (https://login.tailscale.com/admin/machines). No Tailscale API
keys: users, access rules and other devices stay in Tailscale's own console. After changing the way the person pairs
the iPhone again (the code tells it the way).

- **The person's Tailscale app**: aOS runs `tailscale status --json` as the person (`TailscaleApp`: the app's own
  executable, then `/usr/local/bin/tailscale`, then Homebrew's) and reads Tailscale's status JSON (`TailnetStatus`).
  It never changes the app's settings or its sign-in.
- **aOS's own node on the Mac** (`aos-tailnet`, Go, `tailscale.com/tsnet` v1.104.5, in `Tailnet/`): userspace
  networking, no VPN, no network extension, no system setting. It must not be the person's file, because a program
  running as the person (a coding agent with a shell) could copy its keys and pose as this Mac in the tailnet. So it
  follows the custody pattern of Bitwarden and the workspace:
  - aOS's root helper starts it as the hidden user `_aostailnet` (`VaultAccount.ensure`, `Subprocess.spawn` with
    `RunAs`: the child gives up root before exec), with a fresh environment and its state (the node's keys) in
    `/Library/Application Support/aOS/Tailscale` (0700, `_aostailnet`; its log there too, sign-in URLs removed).
    The person's processes can neither read that folder nor the process's memory or environment.
  - It runs from a copy in `/Library/Application Support/aOS/bin` (root, 0755) whose code signature the helper
    checks first: `anchor apple generic and identifier "aos-tailnet" and certificate leaf[subject.OU] = "S3725YB7V6"`.
    The app bundle in /Applications belongs to the person, the copy doesn't, so nothing can be swapped between the
    check and the start.
  - The helper talks to it over the child's stdin and stdout (JSON lines: status, login, logout; no socket, no port).
    When stdin ends, the node closes. The app reaches it only through the helper's XPC call `tailnet` (a
    `TailnetRequest`: status, start with a name `aos-<Mac's local host name>`, stop, login, reconnect, logout;
    names checked: a DNS label starting with `aos-`), which only the signed aOS app may make. The app never sees a key.
  - **Exposure**: port 22 of its tailnet addresses (IPv4 and IPv6) is forwarded to `127.0.0.1:22`, the Mac's own
    sshd; the target is fixed in the program. Everything else is refused (tsnet answers only ports with a listener).
    The build (`Tailnet/build.sh`) also leaves out what would offer something in the tailnet or take remote
    configuration: the peer API server (otherwise it listens on a random port of the node's address), Taildrop,
    Tailscale SSH, the web client, Taildrive, the relay server, routes and exit nodes, remote configuration, packet
    capture, port lists and log uploads (`ts_omit_*`); a binary built without these tags refuses to start
    (`tailnet.BuiltForAOS`). Serve stays in (tsnet needs it), but the node never gets a serve configuration.
    Logs aren't sent to Tailscale (`TS_NO_LOGS_NO_SUPPORT`); a tailnet that requires network flow logs then stops
    the node with a health message.
  - **Lifetime**: the helper keeps the node on while `tailnet.json` (root, 0600: on, name) says so: it doesn't exit
    when idle meanwhile (`TailnetHost.isOn`), starts the node again whenever it starts itself (at boot, RunAtLoad;
    after an update) and after the node's process ended (2 s, 5 s, 15 s, ... 5 min). A replaced binary still makes
    way (an update): the helper stops the node first, and the new helper starts it again at the app's next call (the
    app asks for the status every 30 s while this is the way). The node doesn't need the app's window or the app.
  - **Sign-in**: without a key the node reports `NeedsLogin` with a sign-in URL in its status; the helper relays it,
    and the app opens it in the browser, only after the person clicked "Set Up Tailscale" or "Sign In" and only if
    it is an https page of `tailscale.com`. Whoever completes a sign-in URL first gets the node into their tailnet, so
    it never reaches a log. First use can create the Tailscale account there.
  - **Status** comes from tsnet's LocalClient (in the process, no LocalAPI socket): Tailscale's own status JSON, the
    same format the Tailscale app prints.
  - **The helper's version** is 4 (the `tailnet` call); its other calls are unchanged. An older helper is left alone
    until it exits (the app waits for it), a replaced binary makes way (above).
- **aOS's own node on the iPhone** (`Tailnetkit.xcframework`, built by iOS/generate.sh: the same Go package as a C
  library, `go build -buildmode=c-archive` of `Tailnet/tailnetkit` in a static framework with `tailnetkit.h`; not
  gomobile, because Open Screen Sharing's gomobile library is in the app too and two of them define the same
  Objective-C classes, GoSeqRef and others; two Go runtimes in one process, each in its own image, are what the
  end-to-end test runs): the state is in the app's container (Application Support/Tailnet, file protection until the
  first unlock, excluded from backups so the keys never move to another device), named `aos-<iPhone's name>`. The
  sign-in runs in an `ASWebAuthenticationSession` (it shares Safari's sign-ins); Tailscale's page doesn't lead back
  to the app, so the app closes the session once the node runs. The node listens on nothing; the app dials the Mac
  through it: `tailnetkit_dial` returns one end of a socket pair whose other end is spliced to the tailnet connection,
  and SwiftNIO takes that socket as its channel (`SSHRoute.tailnet`).
- **The phone's order** (`ConnectionPlan`, tested): the same network first (the address that worked last first among
  them), then the tailnet (aOS's node in the app, then the Tailscale app's VPN, detected as a utun interface with an
  address in 100.64.0.0/10 or fd7a:115c:a1e0::/48), then Bonjour (`_ssh._tcp` by the Mac's name). The attempts start
  a moment apart and the first complete SSH login wins.
- **Host keys**: whichever way, the phone accepts the Mac only with the host key pinned at pairing, so another
  device of the tailnet can't pose as the Mac (tested with a socket from a stand-in tailnet).
- **The Tailscale app later**: if the person installs the Tailscale app later and signs in with the same account,
  aOS's devices appear in the same tailnet and are managed there like any device. The app can't take over aOS's
  connection (aOS's nodes have their own keys); on the Mac both can run side by side, as two devices.
- **Tested** without an account, against Tailscale's own test coordination server (`tstest/integration/testcontrol`,
  what tsnet's tests use) and a DERP server on 127.0.0.1 (`Tailnet/build.sh test`): the Mac's node joins, a second
  node reaches a test server through its port 22 (IPv4, IPv6, MagicDNS name), a scan of all 65535 TCP ports of both
  addresses finds only 22, the node offers no peer API, the interactive sign-in and the sign-out, the line protocol,
  and aos-tailnet itself over stdin and stdout. AOSKit tests the helper's custody with a stand-in node (start, sign
  in, stop, start again after a restart, after a crash, sign out, an executable that isn't aOS's), the request
  checks, the status JSON, the recommendation and the link. End to end on the iPhone (`iOS/Tools/test-tailnet.sh`:
  a whole test tailnet on this Mac, `Tailnet/build.sh testnet`): the app's real Tailnetkit node in the simulator
  signs in through a sign-in URL, dials the Mac node's port 22 by address and by name, logs in with the pinned host
  key, runs the companion over it, and finds the other ports closed.

## Signing in for the agent

- **sign_in** (MCP tool): the agent clicks into a user name, password or code field and calls it. The workspace helper
  reports the focused field's kind and the page's host; aOS asks Bitwarden for the logins that match the host (below),
  locks the agent's other tools, posts the request with those logins (name and user name only) to the iPhone and shows
  the sign-in window on the Mac when no phone is connected (the same logins to choose from, plus user name and
  password fields with AutoFill for another password manager). Whoever answers first wins; 3 minutes. An approved
  Bitwarden login is read from Bitwarden only then, checked against the host once more, and handed to the helper.
- **Bitwarden** (`AOSKit/Sources/AOSKit/Bitwarden`): the passwords live in the user's own Bitwarden account; aOS
  keeps none (Docs/COMPANION.md, "Decisions"). aOS talks to Bitwarden only through Bitwarden's official command line
  tool `bw`, run as a program of its own: Bitwarden's SDK license forbids offering an app built with it to others,
  so aOS links nothing of Bitwarden and ships nothing of it.
  - *The tool* (`BitwardenTool`): the user's own `bw` from the usual places (PATH, /opt/homebrew/bin, /usr/local/bin,
    ~/.local/bin, ~/bin) if it is Bitwarden's signed build; otherwise aOS downloads it when the user signs in.
    Bitwarden's official link (`https://vault.bitwarden.com/download/?app=cli&platform=macos`, from
    bitwarden.com/help/cli) redirects to the newest release on GitHub (`bw-macos-<version>.zip`, Intel); aOS takes
    the Apple silicon build of the same release (`bw-macos-arm64-<version>.zip`), falls back to the Intel one,
    unpacks it with ditto and puts it into `~/Library/Application Support/aOS/bin/bw` (0700). Before every use the
    file is checked with macOS's code signing: a Developer ID signature of Bitwarden Inc, team `LTZ2PFU5D6`
    (Bitwarden's build workflow signs the macOS CLI with "Developer ID Application: Bitwarden Inc" and notarizes it;
    the desktop app's notarization names that identity's team, LTZ2PFU5D6), strictly validated for all
    architectures; the result is kept while the file's inode, size and time stay the same. A download that fails the check is deleted. Homebrew's and npm's `bw` are
    Node scripts without a signature and aren't used. Settings > Bitwarden can download the newest version again.
  - *Where it runs* (since build 9, `BitwardenRunner`, `BitwardenVaultHost`): never as the user. Any process of the
    user (a coding agent with a terminal) can read the environment of the user's own processes (`ps eww`, checked)
    but not of another user's, and arguments of everyone's. So aOS's root helper (aos-powerd, XPC that only aOS may
    open) runs `bw` as the hidden user `_aosvault` (dscl, number 360 to 399, no shell, no home, no password), from
    `/Library/Application Support/aOS/bin/bw` (root, 0755: nobody else can replace it; downloaded and checked there
    by the helper), with its files in `/Library/Application Support/aOS/Bitwarden` (0700 for `_aosvault`). The
    child gives up root itself (fork, then only async-signal-safe calls: descriptors, signals, setgroups, setgid,
    setuid, a check that root can't come back, exec) and ends with 126 if that fails. Only the commands aOS uses
    pass, each argument checked (`BitwardenVaultHost.allowed`: no `export`, no search, no raw output); from the
    app's environment only `BW_RESPONSE`, `BW_NOINTERACTION` and `TERM` (no proxies, no `NODE_OPTIONS`).
    Without the helper allowed there is no Bitwarden (the settings ask to allow it); `bw` never runs as the user.
    Bitwarden's earlier files as the user are removed when the helper takes over (one more sign-in).
  - *Running it* (`BitwardenCLI`): English messages, JSON answers (`BW_RESPONSE=true`), `BW_NOINTERACTION=true` for
    everything but the sign-in. The master password goes in through a pipe `bw` reads as `--passwordfile /dev/fd/3`
    (never the environment or a command line); item ids (UUIDs only), the email and the server address are checked
    before they reach a command line. Nothing `bw` prints is logged; errors carry Bitwarden's own message.
  - *Signing in* (`bw login <email> --passwordfile /dev/fd/3`): `bw` asks its questions with inquirer on a terminal, so
    aOS runs it with stdin and stderr on a pseudo terminal and stdout on a pipe (`Subprocess.interactive`), reads the
    questions from the terminal (escape sequences removed) and asks the user in Settings > Bitwarden: the two-step
    method when the account has several ("Two-step login method:", a list answered with arrow keys and Return;
    the CLI supports authenticator app, email and YubiKey OTP, not Duo or passkeys), the code ("Two-step login
    code:"; for email Bitwarden sends it when the method is chosen), and the code Bitwarden emails when aOS is a new
    device for an account without two-step login ("New device verification required. Enter OTP sent to login
    email:"; the CLI has no option for it, only this question). Any other question is shown as `bw` asked it. The
    answer, without line breaks, is typed into the terminal. The server (bitwarden.com, bitwarden.eu or the
    user's own) is set with `bw config server` before. The result is the session key (`raw` in the JSON answer).
  - *The session key* never leaves the helper: it keeps it in `/Library/Application Support/aOS/bitwarden-session`
    (root, 0600), puts it into `bw`'s environment itself and replaces it in replies with the marker
    `BitwardenCLI.heldSession`, which is all the app (and its keychain item) ever holds. `bw lock`, `bw logout` and
    a lock from the app make the helper forget it. Unlocking later: `bw unlock --passwordfile /dev/fd/3`.
  - *When it locks again*: never by itself (the default since build 7: sign-ins should always work; the session
    key is out of the user's reach, and every login still needs the person's approval), or `bitwardenLockHours`
    after unlocking (setting: 1, 4, 8 or 24 hours, counted from unlocking, not from the last use) and then also when
    the Mac goes to sleep (NSWorkspace notification, and the kernel's
    `kern.sleeptime` checked before every use, which also covers a sleep while aOS wasn't running), when it restarts
    (`kern.boottime`), and on demand (Settings, menu). Locking forgets the key in memory and the keychain and runs
    `bw lock`, so the old key opens nothing. Quitting aOS alone doesn't lock: an update or a restart of aOS shouldn't
    need the master password again. Open requests are offered again (same request id) whenever this changes.
  - *Logins for a request*: `bw list items --url https://<host>` (Bitwarden's matching), narrowed by
    `HostMatching` (Docs/COMPANION.md, "Matching logins"), without logins that have "master password re-prompt",
    the login used last for the host first; a stale vault (last sync over 5 minutes ago) is synced while the
    request waits. The answer may only name an offered login; right before filling, aOS reads it with `bw get item`
    (user name and password) and checks its URIs against the host again; for a code request it runs `bw get totp`
    (Bitwarden computes the code; it needs premium or an organization that allows it, otherwise the user types the
    code). Bitwarden records these reads as "viewed" in an organization's event log, like any Bitwarden client.
- **The helper** (`AOSHelper.app`, LaunchAgent in the guest, Accessibility permission) fills only into the real
  Google Chrome (checked by code signature, Google's team EQHXZ8M8AV, not by name) started without command line
  switches (they could turn off certificate checks or log traffic), only into a field of the tab's own page (not a
  frame of another page) and only on an https website with a domain name (no address, no localhost: a page the
  agent serves itself can't pass as a website; the certificate proves the site). It checks right before typing that
  the focus is still that field, sends its key events to Chrome's process only (`postToPid`: another app taking the
  focus meanwhile gets nothing), and right before Return checks again: if the focus moved, it deletes what it typed
  and submits nothing. It types Unicode key events from its own event source (Command pressed and released
  properly), finds the password field after the user name (same page, or after "Next" on the same host).
  aOS reaches it as root over SSH through its own client mode, which checks the peer of its socket by code
  signature through the kernel's audit token. Chrome's web accessibility tree is asked for with
  `AXManualAccessibility` and `AXEnhancedUserInterface` (VoiceOver's way); the frontmost app comes from LaunchServices
  plus `kAXFrontmostAttribute`. Chrome policies keep DevTools, extensions, `javascript:` URLs and Chrome's own pages
  closed (`chrome://*` except new tab, downloads, history, settings and a few more; `chrome://net-export` could
  otherwise record a filled sign-in).
- **The permission**: once, right after screen sharing in the setup (or Settings > General > Signing in). aOS
  starts the helper's request, opens Privacy & Security > Accessibility in the guest; when macOS asks for the
  password the person clicks "Enter Password" in the workspace window's bar (aOS never types it by itself: macOS's
  dialog can't be told apart from outside, System Settings hosts it in its own window and the dialog's service keeps
  running after it closed, so typing "by itself" went into other windows; and the person wants the control).
- **Approving on the Mac**: a Bitwarden login needs Touch ID or the Mac's password (LocalAuthentication, macOS's own
  dialog no other program can answer); Return doesn't approve. A finished workspace's account
  is a standard user: it becomes an administrator for that moment and a standard user again (`prepare.sh` demotes it
  at the next start should that be interrupted). TCC keeps the permission across helper updates (same signature).
- **What this does and doesn't promise.** aOS keeps the password away from the agent's tools and its normal ways of
  working: the agent gets only the result, its screenshots show dots, the clipboard isn't used, and the obvious
  side doors are closed (above). The account Chrome runs in is still the agent's: an agent that deliberately attacks
  the workspace from the inside with programs of its own can't be ruled out completely (for example Chrome's
  JavaScript from Apple Events: Chrome has no policy for it; the helper refuses while a profile has it on, but can
  only see the profile files, not a running Chrome's memory). So: approve sign-ins for agents you trust
  with the account, and prefer accounts with two-factor sign-in. On the Mac's side (since build 9): Bitwarden's
  files, its session key and the master password are out of reach of the user's other programs (above), and
  `put_file` refuses aOS's data, Bitwarden's folders and the browsers' profiles. Since build 11 the workspace's keys and disk
  are in the helper's custody too (AOSKit Guest/WorkspaceCustody.swift; WorkspaceCustodyHost runs in aos-powerd):
  the maintenance and stop keys, the pinned host key and the account's password live in a folder of the hidden user
  `_aosworkspace` (0700), `ssh` to the guest runs as that user, started by the helper, and the app only asks for
  commands to run (it holds the account's password in memory: it types it in the setup and logs in to screen
  sharing). The disk image lives in /Library/Application Support/aOS/Workspace (root, 0700); the helper attaches it
  without mounting (hdiutil, raw) and hands the app an open descriptor of the device for the VM
  (VZDiskBlockDeviceStorageDeviceAttachment); the device files belong to root:operator 0640, and while it is
  attached a Disk Arbitration approval session in the helper refuses mounting, unmounting and ejecting anything on
  it (an administrator on the console may otherwise mount any attached volume; measured: macOS tries to mount the
  workspace's volumes right after the attach). Once the VM opens the device, macOS removes its partitions anyway.
  The helper detaches the disk when the VM stops or the app's connection ends, and doesn't exit while it is
  attached. The host key is pinned under the fixed name `aos-workspace`, whatever the address: a VM someone else
  starts can't pass for the workspace; only a disk the helper created or took over may pin a new key on its first
  connection. Only the signed aOS app may talk to the helper. A workspace of an earlier aOS is handed over at the
  first launch (keys, password and the host key the earlier version recorded; the disk while the workspace is off),
  the user's copies are removed (not to the Trash: they would stay readable there), and at the next start the
  guest gets new keys and a new password (Provisioner.rotateSecrets: the new keys go in beside the old ones and are
  tried first; the password changes in the account's session with its login keychain, see aos-guest-helper
  Rekey.swift; the automatic login follows through sysadminctl's prompt on a pseudo terminal; secrets only on
  stdin). If the automatic login ever loses the password, the next start finds the workspace at the login window,
  sets it again and restarts the guest once. Still open: the VM's saved state (only when sign-ins are kept: the
  workspace is suspended instead of shut down) and its NVRAM file stay files of the user, because Virtualization
  opens them by path in its own process; Apple encrypts the saved state for this user on this Mac, so a program
  running as the user could restore it in a VM of its own (with a disk of its own; the real one stays out of reach).
  The vault as a whole, other logins and the master password stay out of its reach. Approvals from the iPhone: only requests signed with the paired phone's key count, so a
  program on the Mac (a coding agent with a shell, as the same user) can't approve a sign-in, finish a help or
  approval request, read the open requests or get the workspace's screen sharing login through the agent socket.
  It can still stop the phone's requests (delete the keychain item, rewrite authorized_keys, replace what the phone
  runs over SSH) and, by putting its own program in place of aos-companion, read what the Mac sends the phone in
  plaintext (the open requests) and drop answers; it can't change or replay the phone's requests.
- **The workspace's screen login** (since 2026-11-07, Docs/COMPANION.md "The workspace's screen login"): the Mac sends
  it to the phone only sealed. The phone's signed `screen` request carries a one-time P-256 key; the Mac answers with
  its own one-time key and an AES-GCM box (ECDH, HKDF-SHA256 over a context naming the op, the phone, the request's
  nonce and both keys). A program in aos-companion's place sees two public keys and ciphertext; swapping or removing
  the phone's key breaks the signature, and an answer kept from one request doesn't open for a later one. Neither side
  falls back to plaintext for the workspace (the Mac's own screen has no login to send). Still open: the Mac's
  one-time key is vouched for by nothing the phone trusts, so such a program could answer with a box of its own and
  point the phone at a screen it serves (it would get what the person types there, not the workspace's login).
- Open hardening steps: signed answers from the Mac app (a key of the app the phone learns at pairing), a key only
  the signed helper can use, so the request is encrypted to it (instead of trusting the socket's peer), and a check
  of Chrome's profile settings before each sign-in.

## New chats from the Claude app (server mode)

aos-session runs Claude Code's Remote Control server mode (`claude remote-control --spawn same-dir
--no-create-session-in-dir --permission-mode default --remote-control-session-name-prefix aOS`) in the folder the user
chose (default: the home folder), on by default (Settings > Claude Code). The Mac then appears as a device in the
Claude app; every chat started there runs here with the user's own Claude Code and aOS's tools. `RemoteServer`
waits for the network (the server gives up after 10 minutes without it), starts it again with back-off, follows the
settings every 2 s and reports run/remote.json. Learned while testing it:
- Only one server per folder and device. A server that was killed (SIGKILL) stays registered for some minutes, and
  a new one in the same folder is refused ("already served"). So it is ended with SIGTERM only (it says goodbye and
  ends within one or two seconds), SIGKILL only after 10 s.
- After a SIGHUP the server stops answering signals: never send one.
- While stopping, its terminal must still be read: on the way out it writes, and with nobody reading it blocks.
- A folder Claude Code hasn't trusted yet makes it ask "Trust …? [y/N]". aOS never answers on its own: the settings
  show the question and a "Trust the Folder" button; only that click sends the yes.
- Children started in a pseudo terminal inherit ignored signals across exec: aos-session ignores SIGTERM itself
  (it handles it through a dispatch source), so every child now starts with all signals at their default.

## The workspace: programs and website sign-ins

- The Mac's /Applications is shared read only into the workspace (/Volumes/My Shared Files/Applications, setting
  "Programs of this Mac in the workspace", on by default). The programs start there fresh, without the user's data
  and sign-ins (their data lives in the guest account); App Store and licensed apps often don't run. The agent's
  instructions say where they are.
- Website sign-ins when the workspace closes: all sign out, all except a list (default: Google, fewer captchas), or
  none. Chrome policies: DefaultCookiesSetting 4 (session only) with CookiesAllowedForUrls for the list, or 1 (kept)
  for none. Applies at the next start of the workspace.

## Two traps found on the way

- **Foundation's Process**: `waitUntilExit` (and the termination handler) notice the exit through the run loop of the
  thread that started the process. On Swift concurrency threads that run loop doesn't run, and an SSH call waited
  forever for an ssh that had long ended. `Subprocess` starts programs with posix_spawn (only stdin, stdout and stderr
  inherited), reads output as it comes (no 64 KB pipe stall) and reaps with its own waitpid on threads of its own.
- **FileHandle.AsyncBytes**: all instances share one serial queue; a connection waiting for its next line (the phone's
  long poll, an agent between calls) blocked reading on every other connection. The socket server now gives each
  connection a thread with plain reads.

## Anthropic's terms

From Claude Code's legal page (2026-11): third-party apps may not offer Claude.ai login, collect or intermediate
credentials, or bundle ("preinstall") Claude Code without commercial terms; an end user signing in to the unmodified
binary with their own subscription is allowed, including where a platform hosts Claude Code. Therefore:

- Claude Code is installed with Anthropic's own installer, run visibly in a terminal inside aOS.
- Sign-in runs `claude auth login` visibly; aOS reads only `claude auth status` (exit code and auth method).
- The supervisor starts the unmodified `claude` and never answers its questions; the user answers them in the
  session window.
- The product name and icon must not use "Claude" or "Anthropic".
- Before publishing: confirm with Anthropic that this model is fine (open question).

## The VM

- **Bundle** (`VM/`): `disk.img` (sparse raw, 64 GB), `aux.img`, `hardware-model.bin`, `machine-identifier.bin`,
  `config.json` (`VMState`), `suspended.vzvmsave` while suspended.
- **Hardware**: 4 CPUs, 4 GB, one display 1280x800 at 1x (screenshots need no scaling: coordinates Claude sees are guest
  pixels), NAT network with a fixed MAC (the IP comes from `/var/db/dhcpd_leases`), Mac keyboard and trackpad, virtio
  file system with the macOS automount tag (exchange folder at `/Volumes/My Shared Files/Exchange`). No clipboard, no
  audio, no USB.
- **Install**: `VZMacOSRestoreImage.latestSupported` gives Apple's IPSW URL; a resumable download (HTTP range) puts it
  into `RestoreImages/`; `VZMacOSInstaller` installs; the IPSW is deleted afterwards.
- **First boot**: `VZMacGuestProvisioningOptions` (macOS 27) creates the account `aos` (administrator, random
  32-character password in `Keys/guest-account.pw`), automatic login and SSH. No setup assistant.
- **Bootstrap** (`Provisioner.bootstrap`): SSH with the password (through `SSH_ASKPASS`), uploads a self-contained
  script (files as base64) and runs it with `sudo -S`. `setup.sh` installs root's `authorized_keys` (maintenance key:
  `restrict`; stop key: `restrict,command=shutdown.sh`), locks sshd to root with keys, allows screen sharing for the
  account only, turns off sleep, screen saver, relaunch at login and automatic updates, sets language and region like
  the host with the ABC keyboard layout, installs Chrome from Google's signed enterprise package and the guest
  service. Afterwards password SSH is checked to fail.
- **Screen sharing** can only be switched on by a person (enabled through launchctl, screensharingd delivers a black
  picture: "must be enabled from System Settings or via MDM"). The app opens the Sharing settings in the guest over
  SSH and shows the guest; the user flips the switch, and the app types the account password through
  `VZVirtualMachineView` key events when macOS asks. The app then checks for a picture that isn't black and runs
  `finish.sh`: the account becomes a standard user, only screen sharing and SSH are on.
- **Closing**: with "sign-ins expire" (default) the stop key runs `shutdown.sh`: every Chrome quits through the "quit"
  Apple event (only then does it clear site data per its policies), then `shutdown -h now`. Otherwise the VM is paused
  and its state saved (`saveMachineStateTo`), resumed in seconds next time.
- **Session preparation** (`prepare.sh`, once per cold boot, before the agent gets the screen): macOS removes
  `/Library/Managed Preferences` at every login, and right after it the guest is so busy that the guest service needs
  up to half a minute (a single `id` took 14 s) to put the Chrome policies back. aOS waits for the login over the
  maintenance key, has the policies put back, checks them and quits a Chrome that is already running.
- **Reopen at login**: loginwindow keeps its list of apps to reopen
  (`~/Library/Group Containers/group.com.apple.loginwindow.persistent-apps/persistantApps`) up to date while running
  and writes it at shutdown from memory, ignoring `TALLogoutSavesState` and `LoginwindowLaunchesRelaunchApps`
  (`TALBlockSavingAndLaunch` is no preference either). It reopened Chrome at every login, before its policies were
  back. The guest service keeps an empty list there, owned by root and locked (`uchg`); loginwindow then reports
  `previouslyRunningApps count:0`.
- **Chrome policies on a Mac without MDM**: Chrome blocks "sensitive" policies unless the Mac is MDM-enrolled or bound
  to a directory (`base::IsManagedOrEnterpriseDevice`). The sign-in policies are not sensitive and apply
  (`DefaultCookiesSetting`, `CookiesAllowedForUrls`, `ClearBrowsingDataOnExitList`); `DefaultSearchProvider*` and
  `RestoreOnStartup` are, so the search engine choice appears once per workspace. The agent answers it (the MCP
  instructions say so) and Chrome keeps the answer in the profile, which survives the clearing on quit. While that
  modal choice is open Chrome ignores the "quit" Apple event, so `shutdown.sh` had to SIGTERM it and site data stayed.
  Known leftover: Chrome marks every profile exit as "Crashed" (Local State says `exited_cleanly`), so a "Restore
  pages?" bubble appears; it doesn't cover the page and cookies are gone anyway.
- **Idle**: a lease (`workspace_open(purpose, minutes)`) ends after its minutes; without a lease the workspace closes
  after `idleMinutes` (default 20) without tool calls.

## Local network permission

macOS counts the VM's NAT network (`bridge100`) as local network, so the app needs the Local Network permission
(`NSLocalNetworkUsageDescription`); SSH, started by the app, counts as the app. Network.framework reports the denial
as path `unsatisfied (Local network prohibited)`, `RFBStream` turns that into `RFBError.localNetworkDenied`. A plain
ENETDOWN is not a denial: right after a VM start the connection first takes the Wi-Fi route (the bridge doesn't exist
yet) and fails when the bridge appears. `workspace_open` probes port 22 first so a missing permission is reported in
seconds instead of after the SSH timeouts.
macOS identifies the app by its main executable's UUID. After an update (new UUID) the first connection is refused
once ("allowed by preference ... but received prompt", nehelper then caches the new UUID), so the probe tolerates a
denial for a few seconds. Several copies of the app with different UUIDs (debug builds) confuse that cache
(FB15568200): during development, keep one copy registered with LaunchServices.

## Screen and input

`RFBClient` speaks RFB 3.8 to screensharingd: Apple's RSA authentication (type 33: credentials 2x64 bytes AES-128-ECB
with a random key, key encrypted with the server's RSA key, PKCS#1 v1.5). The connection stays open because
screensharingd drops input during the first seconds after connecting. Screenshots are non-incremental full updates
encoded as JPEG (quality 0.8). Keys are X11 keysyms (Command = Super_L); printable ASCII is typed key by key, anything
else goes through the guest's clipboard (`pbcopy` over SSH as the account, then cmd+v).

What screensharingd does with the standard protocol (measured against the workspace, macOS 27.2, `aosctl rfbprobe`):
- Picture encodings it uses when asked: raw, zlib (6), ZRLE (16), and its own halftone (1000, 1 bit), gray (1001,
  4 bits) and thousands (1002, x-5-5-5), each zlib data with a stream of its own. Not Hextile (it sends raw instead),
  no continuous updates, no pointer positions (-232). It sends RichCursor shapes (-239; then leaves the pointer out
  of the picture) and DesktopSize (-223).
- Pixel formats: 32 bits and 16 bits (also 4-4-4 in 16); depths below 12 or 8 bits per pixel close the connection.
- One full 1280x800 picture of the photo desktop: raw 4.1 MB, zlib 1.99 MB, ZRLE 1.70 MB, ZRLE 5-6-5 0.76 MB,
  thousands 0.68 MB, ZRLE 4-4-4 0.45 MB, gray 0.15 MB, halftone 0.05 MB. The iPhone's qualities: best = ZRLE 24 bit,
  balanced = thousands, saver = ZRLE 4-4-4, gray = gray.
- A connection without a pending request learns about a new screen size only with a later update; a screenshot asks
  for one more pixel after its picture, and after the host changed the display it waits for the new size.

`RFBFramebuffer` keeps 32-bit pixels and the changed rectangles of complete updates; the iPhone uploads only those
into a Metal texture. The agent's connection asks for ZRLE without the cursor pseudo-encodings.

The workspace's display can take the iPhone's shape while the iPhone shows it (companion op `display`,
Docs/COMPANION.md): `VMHost.setDisplay` reconfigures the VZMacGraphicsDisplay (pixels, and 160 pixels per inch for
Retina, at which macOS draws exactly two pixels per point in both orientations; at 220 it picked a "more space" mode
for portrait shapes), for a lease the phone renews. The display goes back to the bundle's size when the lease runs
out, before a suspend and after a restore from a saved state. The agent's pictures bigger than 1280 pixels on the long
side are scaled down for it and its coordinates scaled back up.

## Exchange folder

`put_file` copies from the Mac (refuses keychains, `.ssh`, `.gnupg`, cloud credentials, Claude's own config, the
home folder itself, anything over 2 GB); `get_file` moves into `Fetched/` and refuses symbolic links anywhere in the
item (a link created by the guest would point at the Mac's files).

## Not in version 1

- Push notifications on the phone while its app is closed (planned: CloudKit, no server of our own). Until then the
  phone sees requests while the app is open; the Mac window and notification cover the rest.
- Waking a sleeping Mac from the phone (Cloupi's RTC wakes, mailbox and relay); aOS keeps the Mac awake or lets it
  sleep.
- Automating the screen sharing switch (blind keyboard navigation of System Settings).
