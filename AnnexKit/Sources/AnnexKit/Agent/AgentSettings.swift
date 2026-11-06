import Foundation

/// User settings the engine needs (the app edits them; stored as settings.json in the root folder).
public struct AgentSettings: Codable, Sendable, Equatable {
    /// Shut the workspace down after each use, so sign-ins on websites expire (except `keepSignedIn`).
    /// Off: the workspace is suspended and continues exactly where it was.
    public var expireSignIns: Bool = true
    /// Domains whose cookies survive (Chrome URL patterns).
    public var keepSignedIn: [String] = ["[*.]google.com"]
    /// Close the workspace after this many minutes without any tool call.
    public var idleMinutes: Int = 20
    /// Name of the Claude Code session in the Claude app.
    public var sessionName: String = Brand.defaultSessionName
    /// Keep the Claude Code session running in the background (only once it was set up).
    public var sessionEnabled: Bool = true
    /// Keep the Mac from going to sleep while idle, so the session stays reachable (closing the lid of a laptop
    /// still puts it to sleep).
    public var keepAwake: Bool = true
    /// Agents connected during setup (ids of AgentIntegration).
    public var agents: [String] = []
    /// The setup ran to the end once.
    public var setupFinished: Bool = false

    // Keeping Claude Code conversations reachable from the Claude app (SessionKeeper)
    /// Keep conversations running in the background after the window or terminal that ran them closed.
    public var keepReachable: Bool = false
    /// Besides the pinned ones: every conversation that used Remote Control within `keepHours`.
    public var keepAutomatic: Bool = true
    public var keepHours: Int = 48
    /// Also conversations started in a terminal (off: only the Claude app's; terminal ones can still be pinned).
    public var keepTerminal: Bool = false
    /// At most this many at once (each one is a Claude Code process, about 250 MB).
    public var keepMax: Int = 6
    /// Conversation ids the user pinned (kept regardless of age).
    public var keptConversations: [String] = []
    /// Conversation ids the user doesn't want kept.
    public var skippedConversations: [String] = []

    private enum CodingKeys: String, CodingKey {
        case expireSignIns, keepSignedIn, idleMinutes, sessionName, sessionEnabled, keepAwake, agents, setupFinished
        case keepReachable, keepAutomatic, keepHours, keepTerminal, keepMax, keptConversations, skippedConversations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentSettings()
        expireSignIns = try c.decodeIfPresent(Bool.self, forKey: .expireSignIns) ?? d.expireSignIns
        keepSignedIn = try c.decodeIfPresent([String].self, forKey: .keepSignedIn) ?? d.keepSignedIn
        idleMinutes = try c.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? d.idleMinutes
        sessionName = try c.decodeIfPresent(String.self, forKey: .sessionName) ?? d.sessionName
        sessionEnabled = try c.decodeIfPresent(Bool.self, forKey: .sessionEnabled) ?? d.sessionEnabled
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? d.keepAwake
        agents = try c.decodeIfPresent([String].self, forKey: .agents) ?? d.agents
        setupFinished = try c.decodeIfPresent(Bool.self, forKey: .setupFinished) ?? d.setupFinished
        keepReachable = try c.decodeIfPresent(Bool.self, forKey: .keepReachable) ?? d.keepReachable
        keepAutomatic = try c.decodeIfPresent(Bool.self, forKey: .keepAutomatic) ?? d.keepAutomatic
        keepHours = min(max(try c.decodeIfPresent(Int.self, forKey: .keepHours) ?? d.keepHours, 1), 24 * 30)
        keepTerminal = try c.decodeIfPresent(Bool.self, forKey: .keepTerminal) ?? d.keepTerminal
        keepMax = min(max(try c.decodeIfPresent(Int.self, forKey: .keepMax) ?? d.keepMax, 1), 20)
        keptConversations = try c.decodeIfPresent([String].self, forKey: .keptConversations) ?? d.keptConversations
        skippedConversations = try c.decodeIfPresent([String].self, forKey: .skippedConversations) ?? d.skippedConversations
    }

    public init() {}

    public static func load(_ paths: Paths) -> AgentSettings {
        let url = paths.root.appendingPathComponent("settings.json")
        guard let data = FileManager.default.contents(atPath: url.path),
              let s = try? JSONDecoder().decode(AgentSettings.self, from: data) else { return AgentSettings() }
        return s
    }

    public func save(_ paths: Paths) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: paths.root.appendingPathComponent("settings.json"), options: .atomic)
    }
}
