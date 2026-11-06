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
    /// Keep the Mac awake while something must stay reachable: not at all, while the lid is open (idle sleep
    /// prevented), or also with the lid closed (aOS's background helper; other apps freeze meanwhile).
    /// Settings written before this existed carry `keepAwake` (true: while the lid is open).
    public var stayAwake: StayAwake = .lidOpen
    /// How the Mac joins the user's iPhone hotspot; nil until the user answered the question (then aOS leaves
    /// macOS's own settings alone).
    public var hotspotJoin: HotspotJoin?
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

    // New chats from the Claude app (Claude Code's Remote Control server mode)
    /// The Mac appears as a device in the Claude app; a chat started there runs here.
    public var newChats: Bool = true
    /// Folder new chats start in (empty: the home folder).
    public var newChatsFolder: String = ""

    // The workspace
    /// Which websites forget their sign-in when the workspace closes.
    public var signOutWebsites: SignOutWebsites = .allExcept
    /// The Mac's programs are available in the workspace (read only, they start without the user's data).
    public var shareApplications: Bool = true

    public enum SignOutWebsites: String, Codable, Sendable, CaseIterable {
        /// Every website forgets its sign-in.
        case all
        /// All except the domains in `keepSignedIn`.
        case allExcept
        /// Websites stay signed in.
        case none
    }

    private enum CodingKeys: String, CodingKey {
        case expireSignIns, keepSignedIn, idleMinutes, sessionName, sessionEnabled, stayAwake, hotspotJoin, agents
        case setupFinished
        case keepReachable, keepAutomatic, keepHours, keepTerminal, keepMax, keptConversations, skippedConversations
        case newChats, newChatsFolder, signOutWebsites, shareApplications
    }

    /// Keys of earlier versions, read once and written in their new form.
    private enum LegacyKeys: String, CodingKey { case keepAwake }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentSettings()
        expireSignIns = try c.decodeIfPresent(Bool.self, forKey: .expireSignIns) ?? d.expireSignIns
        keepSignedIn = try c.decodeIfPresent([String].self, forKey: .keepSignedIn) ?? d.keepSignedIn
        idleMinutes = try c.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? d.idleMinutes
        sessionName = try c.decodeIfPresent(String.self, forKey: .sessionName) ?? d.sessionName
        sessionEnabled = try c.decodeIfPresent(Bool.self, forKey: .sessionEnabled) ?? d.sessionEnabled
        if let mode = try? c.decodeIfPresent(StayAwake.self, forKey: .stayAwake) {
            stayAwake = mode
        } else if let old = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Bool.self, forKey: .keepAwake) {
            stayAwake = old ? .lidOpen : .off
        } else {
            stayAwake = d.stayAwake
        }
        hotspotJoin = try? c.decodeIfPresent(HotspotJoin.self, forKey: .hotspotJoin)
        agents = try c.decodeIfPresent([String].self, forKey: .agents) ?? d.agents
        setupFinished = try c.decodeIfPresent(Bool.self, forKey: .setupFinished) ?? d.setupFinished
        keepReachable = try c.decodeIfPresent(Bool.self, forKey: .keepReachable) ?? d.keepReachable
        keepAutomatic = try c.decodeIfPresent(Bool.self, forKey: .keepAutomatic) ?? d.keepAutomatic
        keepHours = min(max(try c.decodeIfPresent(Int.self, forKey: .keepHours) ?? d.keepHours, 1), 24 * 30)
        keepTerminal = try c.decodeIfPresent(Bool.self, forKey: .keepTerminal) ?? d.keepTerminal
        keepMax = min(max(try c.decodeIfPresent(Int.self, forKey: .keepMax) ?? d.keepMax, 1), 20)
        keptConversations = try c.decodeIfPresent([String].self, forKey: .keptConversations) ?? d.keptConversations
        skippedConversations = try c.decodeIfPresent([String].self, forKey: .skippedConversations) ?? d.skippedConversations
        newChats = try c.decodeIfPresent(Bool.self, forKey: .newChats) ?? d.newChats
        newChatsFolder = try c.decodeIfPresent(String.self, forKey: .newChatsFolder) ?? d.newChatsFolder
        // Before the choice existed, "sign-ins expire" off meant they stayed
        signOutWebsites = try c.decodeIfPresent(SignOutWebsites.self, forKey: .signOutWebsites)
            ?? (expireSignIns ? .allExcept : .none)
        shareApplications = try c.decodeIfPresent(Bool.self, forKey: .shareApplications) ?? d.shareApplications
    }

    /// The folder new chats from the Claude app start in.
    public var newChatsDirectory: URL {
        let path = (newChatsFolder as NSString).expandingTildeInPath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The Chrome policies these settings ask for.
    public var chromePolicies: ChromePolicies {
        switch signOutWebsites {
        case .all: return ChromePolicies(keepSignedIn: [], keepAll: false)
        case .allExcept: return ChromePolicies(keepSignedIn: keepSignedIn, keepAll: false)
        case .none: return ChromePolicies(keepSignedIn: [], keepAll: true)
        }
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
