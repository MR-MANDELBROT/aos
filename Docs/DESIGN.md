# Annex design

Annex productizes a setup that ran by hand on one Mac (a Tart VM, a Python MCP server, shell installers and a launchd
supervisor around Claude Code). It is an extension for the user's own coding agent: Annex brings the workspace and an
MCP server; the agent (Claude Code, Codex CLI, Gemini CLI, VS Code, Cursor, Windsurf, opencode, anything with MCP)
brings the model and the account. Goals for version 1: one download, a setup that a non-developer finishes in about an
hour (most of it waiting for the macOS download), no Terminal, no sudo, no server of our own.

## Agents and approval

`AgentIntegration` knows how each agent adds an MCP server: Claude Code (`claude mcp add --scope user` plus rules in
`~/.claude/settings.json`: allow `mcp__annex__*`, ask `mcp__annex__workspace_open`), Codex (`codex mcp add`, then
`tool_timeout_sec = 900` in `config.toml`, Codex waits only 60 s by default), Gemini CLI (`gemini mcp add --scope
user --timeout`), VS Code (`code --add-mcp`), Cursor, Windsurf and opencode (their JSON files, merged, with a backup;
files with comments are left alone and the user gets a snippet), anything else (snippet to copy). The server's
environment carries `ANNEX_AGENT` and `ANNEX_APPROVAL`.

Opening the workspace needs the user's yes, one of three ways (`ANNEX_APPROVAL`):
- `agent`: the agent asks itself (Claude Code's ask rule, which Remote Control forwards to the phone; VS Code's tool
  confirmation).
- `auto`: the MCP server asks through the agent with MCP elicitation (`elicitation/create`, a yes/no form) if the
  client declared the capability; otherwise the app asks on the Mac.
- `mac`: the app always asks on the Mac (floating window plus notification, 5 minutes, then no).
The app also asks on the Mac for any request that doesn't say how it was approved.

## Processes (with the optional Claude Code session)

```
Claude app (phone) ──Remote Control──▶ claude (pty) ◀── annex-session (LaunchAgent, KeepAlive)
                                          │ stdio
                                          ▼
                                      annex-mcp ──unix socket (0600, peer uid checked)──▶ Annex.app
                                                                                         ├─ VMHost (Virtualization.framework)
                                                                                         ├─ RFBClient ──VNC──▶ screensharingd (guest)
                                                                                         └─ SSH (root, keys) ──▶ guest kit
```

- **Annex.app** is a menu bar app (LSUIElement), registered as login item (`SMAppService.mainApp`). It hosts the VM, so
  its windows can show the guest with `VZVirtualMachineView` (setup step, help requests).
- **annex-session** is registered with `SMAppService.agent` from `Contents/Library/LaunchAgents`. It runs
  `claude --remote-control <name>` (plus `--continue` once a conversation exists) in the session folder
  (`~/Library/Application Support/Annex/Session`), waits for `api.anthropic.com:443` first, restarts with back-off
  (5 s to 2 min; after five quick exits it stops and waits for the app), and relays the terminal over
  `run/session.sock`. It recognizes Claude Code's questions (sign-in, trust, Remote Control) and reports them in
  `run/session.json`; the app then asks the user to open the session window and answer there.
- **annex-mcp** is registered by `claude mcp add --scope local` for the session folder. `.claude/settings.local.json`
  there allows `mcp__annex__*` and asks for `mcp__annex__workspace_open`; `CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS=0`
  keeps long tool calls (help requests) in the foreground.

## Keeping conversations reachable (SessionKeeper)

The Claude desktop app runs a local Code session only while it works on it; once its process ends, the session goes
offline in the Claude app on the phone (Remote Control needs a running local process). `annex-session` also hosts
the keeper, when "keep conversations reachable" is on:

- **Which**: conversations from `~/.claude/projects` (title from `custom-title`/`ai-title` records, start folder and
  `entrypoint` from the start of the transcript, `bridge-session` = used Remote Control) that were started in the
  Claude app, used Remote Control and were active within `keepHours` (48 h); pinned ones always; at most `keepMax`
  (6). Never: archived or scheduled ones of the desktop app (its records in
  `~/Library/Application Support/Claude/claude-code-sessions`), ones with Remote Control switched off, ones the user
  excluded, Annex's own session folder, automation (`sdk-cli`). Terminal conversations only when pinned or with
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

## Annex for iPhone (companion)

See Docs/COMPANION.md for the protocol. On the Mac:

- **Pairing** (`PairingSession`): a TCP listener on a random port with Bonjour `_annex-pair._tcp`, 3 minutes, one
  pairing, five wrong proofs end it. The QR code carries the Mac's addresses, the SHA-256 fingerprint of its ed25519
  host key and a 16-byte code; the phone proves the code with HMAC-SHA256 over its key and name, the Mac appends the
  key to `~/.ssh/authorized_keys` (`no-agent-forwarding,no-X11-forwarding`, marked `annex-companion:<id>`). Remote
  Login must be on; Settings > iPhone checks it and lists and removes paired phones.
- **annex-companion serve** is what the phone runs over SSH: JSON lines, relayed to the app's agent socket; a second
  connection long-polls `companion.events`. Companion requests are not agent activity (they don't keep the workspace
  open).
- **CompanionHub** collects the events (sign-in, help, approval requests and their end); a phone that connects gets
  the open questions first. The menu shows whether a phone is connected (it asked within 45 s).

## Signing in for the agent

- **sign_in** (MCP tool): the agent clicks into a user name, password or code field and calls it. The workspace helper
  reports the focused field's kind and the page's host; Annex locks the agent's other tools, posts the request
  (iPhone) and shows the sign-in window on the Mac when no phone is connected (user name and password fields with
  AutoFill, so a password manager on the Mac fills them). Whoever answers first wins; 3 minutes.
- **The helper** (`AnnexHelper.app`, LaunchAgent in the guest, Accessibility permission) checks right before typing
  that the focus is still the field on that host, types with Unicode key events from its own event source (Command
  pressed and released properly), finds the password field after the user name (same page, or after "Next" on the
  same host), and submits. Annex reaches it as root over SSH through its own client mode, which accepts only the
  installed helper binary as the peer of its socket (so nothing else in the guest can receive a password). Chrome's
  web accessibility tree is asked for with `AXManualAccessibility` and `AXEnhancedUserInterface` (VoiceOver's way);
  the frontmost app comes from LaunchServices plus `kAXFrontmostAttribute` (the system-wide element sometimes has no
  focused app, and a background app's NSWorkspace doesn't follow activations). DevTools are off, so a filled password
  can't be read back.
- **The permission**: once, right after screen sharing in the setup (or Settings > General > Signing in). Annex
  starts the helper's request, opens Privacy & Security > Accessibility in the guest, and when macOS asks for the
  password (LocalAuthenticationUI on macOS 27, SecurityAgent before) enters the workspace account's password itself:
  the user only flips the switch. A finished workspace's account is a standard user: it becomes an administrator for
  that moment and a standard user again (`prepare.sh` demotes it at the next start should that be interrupted). TCC
  keeps the permission across helper updates (same signature).

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

- Claude Code is installed with Anthropic's own installer, run visibly in a terminal inside Annex.
- Sign-in runs `claude auth login` visibly; Annex reads only `claude auth status` (exit code and auth method).
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
- **First boot**: `VZMacGuestProvisioningOptions` (macOS 27) creates the account `annex` (administrator, random
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
  up to half a minute (a single `id` took 14 s) to put the Chrome policies back. Annex waits for the login over the
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
- Staying reachable with the lid closed (needs a privileged helper for `pmset disablesleep`); version 1 only prevents
  idle sleep.
- Automating the screen sharing switch (blind keyboard navigation of System Settings).
