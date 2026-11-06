# aOS

*Working title.* aOS gives your coding agent its own Mac: a virtual macOS machine with its own screen, pointer,
keyboard and browser, separate from yours. Bring your own agent: Claude Code, Codex CLI, Gemini CLI, VS Code
(Copilot), Cursor, Windsurf, opencode or any agent that speaks MCP. aOS adds itself to the agent as an MCP server;
when a task needs a website or an app, the agent asks to open its workspace, and you approve it.

When a website needs a sign-in, the agent asks and you approve on your iPhone or Mac; aOS fills it in, and the
agent never sees the password. Your passwords stay in your own Bitwarden account: you sign in to Bitwarden once in
aOS, a request shows which of your logins fit the website, and aOS asks Bitwarden for exactly the one you approve. With Claude Code, aOS keeps your conversations reachable from the Claude app on your
phone even after the window or terminal that ran them closed (Remote Control).

**aOS for iPhone** (in `iOS/`) pairs with the Mac by QR code: approve sign-ins with Face ID (one of your Bitwarden
logins, or from another password manager through AutoFill; the iPhone never talks to Bitwarden), open your Mac's
terminal, and watch and control your Mac and the workspace.

aOS is not made by or affiliated with Anthropic, OpenAI, Google, Microsoft or any other agent's maker.

## Requirements

- A Mac with Apple silicon, macOS 27 or later, 8 GB of memory or more (16 GB recommended), about 75 GB free disk space
- A coding agent that supports MCP servers

## Setup

1. Download aOS, move it to Applications, open it.
2. Choose your agents. aOS finds the installed ones.
3. aOS downloads macOS from Apple (about 26 GB) and creates the workspace. It needs no setup assistant: macOS 27's
   guest provisioning creates the account, automatic login and SSH.
4. One step needs you: switch on Screen Sharing in the workspace's System Settings (macOS only allows a person to do
   this), and right after, aOS Helper under Accessibility (for sign-ins). aOS opens the right places and enters
   the workspace password for you.
5. aOS connects your agents (their own `mcp add` commands or their MCP config files; a snippet for anything else).
6. Claude Code: keep your conversations reachable from the phone (on by default), and optionally an always-on
   session of its own. You sign in through Claude Code's own flow; aOS never sees credentials.
7. Optional: sign in to your Bitwarden account (Settings > Bitwarden: email, master password, and the code Bitwarden
   asks for). aOS downloads Bitwarden's official command line tool from Bitwarden for this and checks Bitwarden's
   signature.
8. Optional: pair aOS for iPhone (Settings > iPhone, scan the QR code; needs Remote Login on the Mac).

## Approval

Opening the workspace always needs the user's yes:

- Agents with per-tool approval ask themselves (Claude Code gets a `permissions.ask` rule for `workspace_open`, which
  Remote Control forwards to the phone; VS Code confirms tool calls).
- Other agents are asked through MCP elicitation ("<agent> wants to open its workspace: <purpose>").
- If an agent can do neither, aOS asks on the Mac.

## How it works

| Part | What it does |
|------|--------------|
| `aOS.app` | Menu bar app: setup, settings, the workspace window, and the workspace engine (runs the VM with Apple's Virtualization framework, talks to the guest over SSH and screen sharing) |
| `aos-mcp` | MCP server that the agent starts. Its tools (open, screenshot, click, type, keys, scroll, drag, files, close) go to the app over a private socket |
| `aos-session` | LaunchAgent: keeps Claude Code conversations reachable (resumes them with Remote Control when no other process has them) and the optional always-on session |
| `aos-companion` | What the iPhone app runs over SSH: requests and events between the phone and the app |
| Bitwarden's `bw` | Bitwarden's official command line tool, not part of aOS: downloaded from Bitwarden when you sign in (or yours, if it is Bitwarden's signed build), checked by its signature before every use; aOS runs it to sign in to your Bitwarden account and to get the login you approve |
| Guest kit | Scripts and the helper that run inside the VM: SSH lock-down, Chrome policies, orderly shutdown, sign-ins (aOS Helper) |
| `iOS/` | aOS for iPhone |

Details: [Docs/DESIGN.md](Docs/DESIGN.md).

## Security model

- Opening the workspace always needs your approval (see above). Without it no other tool works.
- The account in the VM is a standard user. Maintenance happens as root over SSH with keys that only this Mac has;
  password logins are off.
- Sign-ins on websites expire when the workspace closes (Chrome policies, orderly shutdown), except the domains you
  choose to keep (default: Google, which reduces captchas).
- Sign-ins: the agent clicks into the field and calls `sign_in`; you approve on your iPhone (Face ID) or your Mac, and
  aOS Helper in the workspace types it into exactly that field and submits, only in the real Google Chrome (by code
  signature) and only on https websites with a domain name. The agent gets the result, not the password; DevTools,
  extensions and Chrome's internal pages are off, so the page can't hand a filled password back. The agent is told
  never to type passwords or codes itself and never to solve captchas. An agent that deliberately attacks its own
  workspace with programs of its own can't be ruled out completely (Docs/DESIGN.md, "What this does and doesn't
  promise"): approve sign-ins for agents you trust with the account.
- Bitwarden: your master password goes to Bitwarden's tool when you sign in or unlock and is never stored. aOS keeps
  only Bitwarden's session key, in a keychain item of its own, and asks Bitwarden for a login only after you approved
  it, checking again that it belongs to the website. Bitwarden locks again 8 hours after unlocking (a setting), when
  the Mac sleeps or restarts, or when you lock it. The iPhone sees names and user names of your logins, never a
  password.
- Files cross only through the exchange folder. Links planted by the guest are refused; files from the workspace are
  treated as untrusted. Credentials and key folders of your Mac can't be put into the workspace.
- aOS does not collect, store or forward any agent's credentials and has no server of its own.

## Building

```bash
Tools/generate.sh      # Xcode project from project.yml (XcodeGen)
Tools/build.sh         # Debug build
cd AOSKit && swift test
Tools/release.sh       # signed, notarized DMG and Sparkle appcast item
```

`AOSKit/Sources/aosctl` is a development tool that drives the engine without the app.
