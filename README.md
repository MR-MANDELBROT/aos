# Annex

*Working title.* Annex gives your coding agent its own Mac: a virtual macOS machine with its own screen, pointer,
keyboard and browser, separate from yours. Bring your own agent: Claude Code, Codex CLI, Gemini CLI, VS Code
(Copilot), Cursor, Windsurf, opencode or any agent that speaks MCP. Annex adds itself to the agent as an MCP server;
when a task needs a website or an app, the agent asks to open its workspace, and you approve it.

When a website needs a sign-in, the agent asks and you approve on your iPhone or Mac; Annex fills it in, and the
agent never sees the password. With Claude Code, Annex keeps your conversations reachable from the Claude app on your
phone even after the window or terminal that ran them closed (Remote Control).

**Annex for iPhone** (in `iOS/`) pairs with the Mac by QR code: approve sign-ins with Face ID (from its own vault, or
from your password manager through AutoFill), open your Mac's terminal, and watch and control your Mac and the
workspace.

Annex is not made by or affiliated with Anthropic, OpenAI, Google, Microsoft or any other agent's maker.

## Requirements

- A Mac with Apple silicon, macOS 27 or later, 8 GB of memory or more (16 GB recommended), about 75 GB free disk space
- A coding agent that supports MCP servers

## Setup

1. Download Annex, move it to Applications, open it.
2. Choose your agents. Annex finds the installed ones.
3. Annex downloads macOS from Apple (about 26 GB) and creates the workspace. It needs no setup assistant: macOS 27's
   guest provisioning creates the account, automatic login and SSH.
4. One step needs you: switch on Screen Sharing in the workspace's System Settings (macOS only allows a person to do
   this), and right after, Annex Helper under Accessibility (for sign-ins). Annex opens the right places and enters
   the workspace password for you.
5. Annex connects your agents (their own `mcp add` commands or their MCP config files; a snippet for anything else).
6. Claude Code: keep your conversations reachable from the phone (on by default), and optionally an always-on
   session of its own. You sign in through Claude Code's own flow; Annex never sees credentials.
7. Optional: pair Annex for iPhone (Settings > iPhone, scan the QR code; needs Remote Login on the Mac).

## Approval

Opening the workspace always needs the user's yes:

- Agents with per-tool approval ask themselves (Claude Code gets a `permissions.ask` rule for `workspace_open`, which
  Remote Control forwards to the phone; VS Code confirms tool calls).
- Other agents are asked through MCP elicitation ("<agent> wants to open its workspace: <purpose>").
- If an agent can do neither, Annex asks on the Mac.

## How it works

| Part | What it does |
|------|--------------|
| `Annex.app` | Menu bar app: setup, settings, the workspace window, and the workspace engine (runs the VM with Apple's Virtualization framework, talks to the guest over SSH and screen sharing) |
| `annex-mcp` | MCP server that the agent starts. Its tools (open, screenshot, click, type, keys, scroll, drag, files, close) go to the app over a private socket |
| `annex-session` | LaunchAgent: keeps Claude Code conversations reachable (resumes them with Remote Control when no other process has them) and the optional always-on session |
| `annex-companion` | What the iPhone app runs over SSH: requests and events between the phone and the app |
| Guest kit | Scripts and the helper that run inside the VM: SSH lock-down, Chrome policies, orderly shutdown, sign-ins (Annex Helper) |
| `iOS/` | Annex for iPhone |

Details: [Docs/DESIGN.md](Docs/DESIGN.md).

## Security model

- Opening the workspace always needs your approval (see above). Without it no other tool works.
- The account in the VM is a standard user. Maintenance happens as root over SSH with keys that only this Mac has;
  password logins are off.
- Sign-ins on websites expire when the workspace closes (Chrome policies, orderly shutdown), except the domains you
  choose to keep (default: Google, which reduces captchas).
- Sign-ins: the agent clicks into the field and calls `sign_in`; you approve on your iPhone (Face ID) or your Mac, and
  Annex Helper in the workspace types it into exactly that field on that website and submits. The agent never sees
  passwords; DevTools are off, so the page can't hand a filled password back. The agent is told never to type
  passwords or codes itself and never to solve captchas.
- Files cross only through the exchange folder. Links planted by the guest are refused; files from the workspace are
  treated as untrusted. Credentials and key folders of your Mac can't be put into the workspace.
- Annex does not collect, store or forward any agent's credentials and has no server of its own.

## Building

```bash
Tools/generate.sh      # Xcode project from project.yml (XcodeGen)
Tools/build.sh         # Debug build
cd AnnexKit && swift test
Tools/release.sh       # signed, notarized DMG and Sparkle appcast item
```

`AnnexKit/Sources/annexctl` is a development tool that drives the engine without the app.
