import Foundation

/// Who asks the user before the workspace opens.
public enum ApprovalMode: String, Codable, Sendable {
    /// The agent asks itself (a per-tool permission rule or its default tool approval).
    case agent
    /// Annex asks through the agent (MCP elicitation); if the agent can't, Annex asks on the Mac.
    case auto
    /// Annex always asks on the Mac.
    case mac
}

/// A coding agent that Annex can connect to: it registers Annex's MCP server in the agent's own configuration.
public struct AgentIntegration: Identifiable, Sendable, Hashable {
    public enum Method: Sendable, Hashable {
        /// The agent's own CLI adds the server.
        case cli
        /// A JSON file with an `mcpServers`-style object (path, key of the servers object).
        case jsonFile(path: String, serversKey: String, style: JSONStyle)
        /// Only a snippet to copy.
        case manual
    }

    public enum JSONStyle: Sendable, Hashable { case mcpServers, opencode }

    public let id: String
    public let name: String
    public let method: Method
    /// The approval the agent provides without help (Claude Code: permissions.ask; VS Code: confirms tool calls).
    public let approval: ApprovalMode
    /// Can keep a session reachable from the phone (Claude Code Remote Control).
    public let supportsRemoteSession: Bool

    public static let all: [AgentIntegration] = [
        AgentIntegration(id: "claude-code", name: "Claude Code", method: .cli, approval: .agent, supportsRemoteSession: true),
        AgentIntegration(id: "codex", name: "Codex CLI", method: .cli, approval: .auto, supportsRemoteSession: false),
        AgentIntegration(id: "gemini", name: "Gemini CLI", method: .cli, approval: .auto, supportsRemoteSession: false),
        AgentIntegration(id: "vscode", name: "VS Code (Copilot)", method: .cli, approval: .agent, supportsRemoteSession: false),
        AgentIntegration(id: "cursor", name: "Cursor", method: .jsonFile(path: "~/.cursor/mcp.json", serversKey: "mcpServers", style: .mcpServers),
                         approval: .auto, supportsRemoteSession: false),
        AgentIntegration(id: "windsurf", name: "Windsurf", method: .jsonFile(path: "~/.codeium/windsurf/mcp_config.json", serversKey: "mcpServers", style: .mcpServers),
                         approval: .auto, supportsRemoteSession: false),
        AgentIntegration(id: "opencode", name: "opencode", method: .jsonFile(path: "~/.config/opencode/opencode.json", serversKey: "mcp", style: .opencode),
                         approval: .auto, supportsRemoteSession: false),
        AgentIntegration(id: "other", name: "Another agent", method: .manual, approval: .auto, supportsRemoteSession: false),
    ]

    public static func byID(_ id: String) -> AgentIntegration? { all.first { $0.id == id } }

    // MARK: Detection

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    static func which(_ name: String) -> String? {
        let candidates = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                          "\(home)/.bun/bin", "\(home)/.volta/bin", "/usr/bin"]
        for dir in candidates where FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") {
            return "\(dir)/\(name)"
        }
        return nil
    }

    /// The program used to configure (and for CLIs: run) the agent.
    public var executable: String? {
        switch id {
        case "claude-code": return Self.which("claude")
        case "codex": return Self.which("codex")
        case "gemini": return Self.which("gemini")
        case "vscode":
            for app in ["/Applications/Visual Studio Code.app", "\(Self.home)/Applications/Visual Studio Code.app"] {
                let code = "\(app)/Contents/Resources/app/bin/code"
                if FileManager.default.isExecutableFile(atPath: code) { return code }
            }
            return nil
        default: return nil
        }
    }

    public var isInstalled: Bool {
        switch method {
        case .cli: return executable != nil
        case .jsonFile(let path, _, _):
            let dir = (Self.expand(path) as NSString).deletingLastPathComponent
            let apps = ["cursor": "/Applications/Cursor.app", "windsurf": "/Applications/Windsurf.app"]
            if let app = apps[id], FileManager.default.fileExists(atPath: app) { return true }
            if id == "opencode" { return Self.which("opencode") != nil || FileManager.default.fileExists(atPath: dir) }
            return FileManager.default.fileExists(atPath: dir)
        case .manual: return true
        }
    }

    // MARK: Configuration

    /// What the MCP server needs to know about its agent.
    public func environment(approval: ApprovalMode) -> [String: String] {
        ["ANNEX_AGENT": id, "ANNEX_APPROVAL": approval.rawValue]
    }

    /// Generic snippet (mcpServers format) for agents without automatic setup.
    public static func snippet(binary: URL) -> String {
        let obj: [String: Any] = ["mcpServers": [Brand.mcpServerName: [
            "command": binary.path, "args": [String](), "env": ["ANNEX_APPROVAL": "auto"],
        ]]]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public enum IntegrationError: LocalizedError {
        case notInstalled(String)
        case command(String, String)
        case unreadableConfig(String)
        case manual

        public var errorDescription: String? {
            switch self {
            case .notInstalled(let n): return "\(n) is not installed."
            case .command(let n, let out): return "\(n) could not add the server: \(out.prefix(300))"
            case .unreadableConfig(let p): return "\(p) is not plain JSON (comments?). Add the server by hand with the snippet."
            case .manual: return "Copy the snippet into your agent's MCP configuration."
            }
        }
    }

    /// Registers Annex's MCP server with this agent. `sessionFolder`: Claude Code's always-on session folder (its
    /// permission rules live there).
    public func configure(binary: URL, sessionFolder: URL?) throws {
        switch method {
        case .manual: throw IntegrationError.manual
        case .jsonFile(let path, let key, let style):
            try Self.patchJSON(path: Self.expand(path), serversKey: key, style: style, binary: binary,
                               env: environment(approval: approval))
        case .cli:
            guard let exe = executable else { throw IntegrationError.notInstalled(name) }
            let server = Brand.mcpServerName
            let env = environment(approval: approval)
            switch id {
            case "claude-code":
                _ = try? Self.run(exe, ["mcp", "remove", "--scope", "user", server])
                // The name comes first: --env takes several values and would swallow it.
                let (code, out) = try Self.run(exe, ["mcp", "add", "--scope", "user", "--transport", "stdio", server]
                    + env.sorted { $0.key < $1.key }.flatMap { ["--env", "\($0.key)=\($0.value)"] }
                    + ["--", binary.path])
                guard code == 0 else { throw IntegrationError.command(name, out) }
                try Self.claudeUserPermissions(server: server)
                if let sessionFolder { try Self.claudeSessionSettings(folder: sessionFolder, server: server) }
            case "codex":
                _ = try? Self.run(exe, ["mcp", "remove", server])
                let (code, out) = try Self.run(exe, ["mcp", "add", server]
                    + env.sorted { $0.key < $1.key }.flatMap { ["--env", "\($0.key)=\($0.value)"] }
                    + ["--", binary.path])
                guard code == 0 else { throw IntegrationError.command(name, out) }
                try Self.codexTimeouts(server: server)
            case "gemini":
                _ = try? Self.run(exe, ["mcp", "remove", "--scope", "user", server])
                let (code, out) = try Self.run(exe, ["mcp", "add", "--scope", "user", "--timeout", "900000"]
                    + env.sorted { $0.key < $1.key }.flatMap { ["-e", "\($0.key)=\($0.value)"] }
                    + [server, binary.path])
                guard code == 0 else { throw IntegrationError.command(name, out) }
            case "vscode":
                let spec: [String: Any] = ["name": server, "type": "stdio", "command": binary.path, "args": [String](), "env": env]
                let json = String(decoding: try JSONSerialization.data(withJSONObject: spec, options: [.withoutEscapingSlashes]), as: UTF8.self)
                let (code, out) = try Self.run(exe, ["--add-mcp", json])
                guard code == 0 else { throw IntegrationError.command(name, out) }
            default:
                throw IntegrationError.manual
            }
        }
    }

    // MARK: Helpers

    @discardableResult
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 60) throws -> (Int32, String) {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.removeValue(forKey: "CLAUDECODE")
        let r = try Subprocess.runBlocking(exe, args, environment: env,
                                           cwd: FileManager.default.homeDirectoryForCurrentUser.path, timeout: timeout)
        return (r.status, String(decoding: r.stdout + r.stderr, as: UTF8.self))
    }

    /// Adds Annex's server to a JSON config (keeps everything else; a backup of the old file stays next to it).
    static func patchJSON(path: String, serversKey: String, style: JSONStyle, binary: URL, env: [String: String]) throws {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: path), !data.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw IntegrationError.unreadableConfig(path)
            }
            root = obj
            try? fm.removeItem(atPath: path + ".annex-backup")
            try fm.copyItem(atPath: path, toPath: path + ".annex-backup")
        } else {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        var servers = root[serversKey] as? [String: Any] ?? [:]
        switch style {
        case .mcpServers:
            servers[Brand.mcpServerName] = ["command": binary.path, "args": [String](), "env": env]
        case .opencode:
            servers[Brand.mcpServerName] = ["type": "local", "command": [binary.path], "enabled": true, "environment": env]
        }
        root[serversKey] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Claude Code: workspace_open asks (also over Remote Control), the other tools don't. In ~/.claude/settings.json,
    /// merged into the existing rules.
    static func claudeUserPermissions(server: String) throws {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? "\(home)/.claude"
        let url = URL(fileURLWithPath: "\(dir)/settings.json")
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: url.path), !data.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw IntegrationError.unreadableConfig(url.path)
            }
            root = obj
            try? FileManager.default.removeItem(atPath: url.path + ".annex-backup")
            try FileManager.default.copyItem(atPath: url.path, toPath: url.path + ".annex-backup")
        }
        var permissions = root["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        var ask = permissions["ask"] as? [String] ?? []
        let allRule = "mcp__\(server)__*", openRule = "mcp__\(server)__workspace_open"
        if !allow.contains(allRule) { allow.append(allRule) }
        if !ask.contains(openRule) { ask.append(openRule) }
        permissions["allow"] = allow
        permissions["ask"] = ask
        root["permissions"] = permissions
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// The always-on session's folder: long tool calls (approval, help) stay in the foreground there.
    static func claudeSessionSettings(folder: URL, server: String) throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let settings: [String: Any] = ["env": ["CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS": "0"]]
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent(".claude/settings.local.json"), options: .atomic)
    }

    /// Codex waits only 60 s for a tool by default; opening (cold boot plus approval) and help requests take longer.
    static func codexTimeouts(server: String) throws {
        let dir = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "\(home)/.codex"
        let url = URL(fileURLWithPath: "\(dir)/config.toml")
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let header = "[mcp_servers.\(server)]"
        guard let range = text.range(of: header) else { return }
        let sectionEnd = text[range.upperBound...].range(of: "\n[")?.lowerBound ?? text.endIndex
        let section = text[range.upperBound..<sectionEnd]
        var add = ""
        if !section.contains("tool_timeout_sec") { add += "\ntool_timeout_sec = 900" }
        if !section.contains("startup_timeout_sec") { add += "\nstartup_timeout_sec = 30" }
        guard !add.isEmpty else { return }
        text.insert(contentsOf: add, at: range.upperBound)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
