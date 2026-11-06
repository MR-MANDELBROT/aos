import Foundation

/// File locations. Everything lives under ~/Library/Application Support/<Brand> unless the user
/// moves the exchange folder. `AOS_HOME` overrides the root (tests, development).
public struct Paths: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let env = ProcessInfo.processInfo.environment["AOS_HOME"], !env.isEmpty {
            self.root = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = support.appendingPathComponent(Brand.name, isDirectory: true)
        }
    }

    public static let `default` = Paths()

    /// The VM bundle (disk, auxiliary storage, hardware model, machine identifier, config).
    public var vm: URL { root.appendingPathComponent("VM", isDirectory: true) }
    /// Downloaded macOS restore images.
    public var restoreImages: URL { root.appendingPathComponent("RestoreImages", isDirectory: true) }
    /// Sockets, pid files and other runtime state.
    public var run: URL { root.appendingPathComponent("run", isDirectory: true) }
    /// The agent's control socket (JSON lines; the MCP tool and the app connect here).
    public var agentSocket: URL { run.appendingPathComponent("agent.sock") }
    /// SSH keys and known_hosts for maintaining the guest.
    public var keys: URL { root.appendingPathComponent("Keys", isDirectory: true) }
    /// Logs.
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    /// Folder shared with the guest (appears there as /Volumes/My Shared Files/Exchange).
    public var exchange: URL { root.appendingPathComponent("Exchange", isDirectory: true) }
    /// Files fetched out of the exchange folder for the session (after the agent copied them).
    public var fetched: URL { root.appendingPathComponent("Fetched", isDirectory: true) }
    /// Working directory of the Claude Code session.
    public var session: URL { root.appendingPathComponent("Session", isDirectory: true) }
    /// Guest scripts copied out of the app bundle for upload.
    public var guestKit: URL { root.appendingPathComponent("GuestKit", isDirectory: true) }

    /// Creates the directories that must exist, with private permissions.
    public func prepare() throws {
        let fm = FileManager.default
        for dir in [root, vm, restoreImages, run, keys, logs, exchange, fetched, session] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        // The root and the key/run folders must stay private even if they existed before.
        for dir in [root, keys, run] {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }
}
