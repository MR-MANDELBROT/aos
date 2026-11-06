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
  minutes). The listener's code signing requirement admits only aOS (`identifier "dev.marquart.aos"`, team
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
  host key and a 16-byte code; the phone proves the code with HMAC-SHA256 over its key and name, the Mac appends the
  key to `~/.ssh/authorized_keys` (`no-agent-forwarding,no-X11-forwarding`, marked `aos-companion:<id>`). Remote
  Login must be on; Settings > iPhone checks it and lists and removes paired phones.
- **aos-companion serve** is what the phone runs over SSH: JSON lines, relayed to the app's agent socket; a second
  connection long-polls `companion.events`. Companion requests are not agent activity (they don't keep the workspace
  open).
- **CompanionHub** collects the events (sign-in, help, approval requests and their end); a phone that connects gets
  the open questions first. The menu shows whether a phone is connected (it asked within 45 s).

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
  - *Running it* (`BitwardenCLI`): a small environment of its own (no inherited secrets), English messages, JSON
    answers (`BW_RESPONSE=true`), `BW_NOINTERACTION=true` for everything but the sign-in, and
    `BITWARDENCLI_APPDATA_DIR=~/Library/Application Support/aOS/Bitwarden`, so aOS's sign-in is apart from the
    user's own `bw`. The master password goes in only through `--passwordenv` (the variable's name is on the command
    line, the password in the child's environment), the session key only as `BW_SESSION`; item ids (UUIDs only),
    the email and the server address are checked before they reach a command line. Nothing `bw` prints is logged;
    errors carry Bitwarden's own message.
  - *Signing in* (`bw login <email> --passwordenv`): `bw` asks its questions with inquirer on a terminal, so
    aOS runs it with stdin and stderr on a pseudo terminal and stdout on a pipe (`Subprocess.interactive`), reads the
    questions from the terminal (escape sequences removed) and asks the user in Settings > Bitwarden: the two-step
    method when the account has several ("Two-step login method:", a list answered with arrow keys and Return;
    the CLI supports authenticator app, email and YubiKey OTP, not Duo or passkeys), the code ("Two-step login
    code:"; for email Bitwarden sends it when the method is chosen), and the code Bitwarden emails when aOS is a new
    device for an account without two-step login ("New device verification required. Enter OTP sent to login
    email:"; the CLI has no option for it, only this question). Any other question is shown as `bw` asked it. The
    answer, without line breaks, is typed into the terminal. The server (bitwarden.com, bitwarden.eu or the
    user's own) is set with `bw config server` before. The result is the session key (`raw` in the JSON answer).
  - *The session key* stays in a generic password item of the login keychain (service `dev.marquart.aos.bitwarden`,
    not synchronized). macOS puts the program that created an item on its access list, so another program can only
    read it after the person allows it in macOS's own dialog. Unlocking later: `bw unlock --passwordenv`.
  - *When it locks again*: `bitwardenLockHours` after unlocking (setting: 1, 4, 8 (default) or 24 hours, counted
    from unlocking, not from the last use), when the Mac goes to sleep (NSWorkspace notification, and the kernel's
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
  starts the helper's request, opens Privacy & Security > Accessibility in the guest; during the first setup (no
  agent has used the workspace yet) it enters the workspace account's password itself when macOS asks (the dialog is
  recognized by its program's path). Later the person clicks "Enter the workspace password" themselves while looking
  at the dialog: an agent could have left programs that wait for exactly this moment. A finished workspace's account
  is a standard user: it becomes an administrator for that moment and a standard user again (`prepare.sh` demotes it
  at the next start should that be interrupted). TCC keeps the permission across helper updates (same signature).
- **What this does and doesn't promise.** aOS keeps the password away from the agent's tools and its normal ways of
  working: the agent gets only the result, its screenshots show dots, the clipboard isn't used, and the obvious
  side doors are closed (above). The account Chrome runs in is still the agent's: an agent that deliberately attacks
  the workspace from the inside with programs of its own can't be ruled out completely (for example Chrome's
  JavaScript from Apple Events: Chrome has no policy for it; the helper refuses while a profile has it on, but can
  only see the profile files, not a running Chrome's memory). So: approve sign-ins for agents you trust
  with the account, and prefer accounts with two-factor sign-in. On the Mac's side: while `bw` runs for a sign-in
  or an unlock (seconds), the master password is in its environment, which other programs of the same macOS user
  could read; the session key is in the keychain behind macOS's access list, and in `bw`'s environment while it
  runs. That is the CLI's own model (`--passwordenv`, `BW_SESSION`); the workspace (the agent's account in the VM)
  reaches none of it. Open hardening steps: a key only the signed helper
  can use, so the request is encrypted to it (instead of trusting the socket's peer), and a check of Chrome's profile
  settings before each sign-in.

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
with a random key, key encrypted with the server's RSA key, PKCS#1 v1.5), 32-bit RGBX pixels, raw and zlib rectangles
(one zlib stream per connection). The connection stays open because screensharingd drops input during the first two
seconds after connecting. Screenshots are non-incremental full updates encoded as JPEG (quality 0.8). Keys are X11
keysyms (Command = Super_L); printable ASCII is typed key by key, anything else goes through the guest's clipboard
(`pbcopy` over SSH as the account, then cmd+v).

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
