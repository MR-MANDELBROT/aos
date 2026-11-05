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
- **Idle**: a lease (`workspace_open(purpose, minutes)`) ends after its minutes; without a lease the workspace closes
  after `idleMinutes` (default 20) without tool calls.

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

- Companion (BW Agent): sign-ins from a password manager, live view and help on the phone.
- Staying reachable with the lid closed (needs a privileged helper for `pmset disablesleep`); version 1 only prevents
  idle sleep.
- Automating the screen sharing switch (blind keyboard navigation of System Settings).
