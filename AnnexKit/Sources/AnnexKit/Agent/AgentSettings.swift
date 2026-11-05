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
    /// Keep the session running in the background.
    public var sessionEnabled: Bool = true
    /// Keep the Mac from going to sleep while idle, so the session stays reachable (closing the lid of a laptop
    /// still puts it to sleep).
    public var keepAwake: Bool = true

    private enum CodingKeys: String, CodingKey {
        case expireSignIns, keepSignedIn, idleMinutes, sessionName, sessionEnabled, keepAwake
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
