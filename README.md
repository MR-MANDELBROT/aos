# Annex

*Working title.* Annex gives Claude its own Mac: a virtual macOS machine with its own screen, pointer, keyboard and
browser, separate from yours. A Claude Code session runs on your Mac in the background, and you reach it from the
Claude app on your phone (Remote Control) at any time. When a task needs a website or an app, Claude asks to open its
workspace; you approve it in the Claude app.

Annex runs Claude Code. It is not made by or affiliated with Anthropic.

## Requirements

- A Mac with Apple silicon, macOS 27 or later, 8 GB of memory or more (16 GB recommended), about 60 GB free disk space
- A Claude subscription that includes Claude Code and Remote Control (Pro, Max, Team or Enterprise)

## Setup

1. Download Annex, move it to Applications, open it.
2. Install Claude Code (Anthropic's installer, shown in a terminal inside Annex) and sign in. You sign in through
   Claude Code's own flow; Annex never sees your credentials.
3. Annex downloads macOS from Apple (about 18 GB) and creates the workspace. It needs no setup assistant: macOS 27's
   guest provisioning creates the account, automatic login and SSH.
4. One step needs you: switch on Screen Sharing in the workspace's System Settings (macOS only allows a person to do
   this). Annex opens the right place and enters the workspace password for you.
5. Start the session once and answer Claude Code's two questions (trust the folder, enable Remote Control). From then
   on it runs in the background, and Annex starts at login.

## How it works

| Part | What it does |
|------|--------------|
| `Annex.app` | Menu bar app: setup, settings, the workspace window, and the workspace engine (runs the VM with Apple's Virtualization framework, talks to the guest over SSH and screen sharing) |
| `annex-mcp` | MCP server that Claude Code starts. Its tools (open, screenshot, click, type, keys, scroll, drag, files, close) go to the app over a private socket |
| `annex-session` | Keeps the Claude Code session running in a pseudo terminal (LaunchAgent), restarts it, waits for the network, and lets the app show its terminal |
| Guest kit | Scripts that run inside the VM: SSH lock-down, Chrome policies, orderly shutdown |

Details: [Docs/DESIGN.md](Docs/DESIGN.md).

## Security model

- Opening the workspace always needs your approval in the Claude app (`permissions.ask` plus the MCP
  `requiresUserInteraction` hint). Without it no other tool works.
- The account in the VM is a standard user. Maintenance happens as root over SSH with keys that only this Mac has;
  password logins are off.
- Sign-ins on websites expire when the workspace closes (Chrome policies, orderly shutdown), except the domains you
  choose to keep (default: Google, which reduces captchas).
- Claude never types passwords or one-time codes and never solves captchas; it asks you, and you do it in the
  workspace window.
- Files cross only through the exchange folder. Links planted by the guest are refused; files from the workspace are
  treated as untrusted. Credentials and key folders of your Mac can't be put into the workspace.
- Annex does not collect, store or forward Claude credentials and has no server of its own.

## Building

```bash
Tools/generate.sh      # Xcode project from project.yml (XcodeGen)
Tools/build.sh         # Debug build
cd AnnexKit && swift test
Tools/release.sh       # signed, notarized DMG and Sparkle appcast item
```

`AnnexKit/Sources/annexctl` is a development tool that drives the engine without the app.
