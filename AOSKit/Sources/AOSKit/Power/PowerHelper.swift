import Foundation

/// aos-powerd, aOS's privileged helper: a root LaunchDaemon inside the app bundle (Contents/Library/LaunchDaemons,
/// registered with SMAppService.daemon). Its whole surface is this interface; it accepts only aOS itself (code
/// signature, checked by the system on every message through the caller's audit token). Replies are JSON
/// (`HelperReply`) so both sides decode the same Codable types.
@objc public protocol PowerHelperXPC {
    /// State: whether it holds the Mac awake, pmset's SleepDisabled, the user's hotspots by name.
    func status(reply: @escaping (Data) -> Void)
    /// Keep the Mac awake with the lid closed (pmset disablesleep 1) for `seconds` (at most 180, the app renews);
    /// 0 releases it at once.
    func hold(seconds: Int, reply: @escaping (Data) -> Void)
    /// Apply a `HotspotJoin` (raw value) to macOS: the user's hotspots' auto-join flag and "Ask to join hotspots";
    /// airportd restarts (Wi-Fi reconnects within seconds), the result is read back and returned.
    func applyHotspotJoin(_ mode: String, reply: @escaping (Data) -> Void)
    /// Join a network macOS already knows (its password is in the System keychain), by name.
    func join(network: String, reply: @escaping (Data) -> Void)
    /// "restartAirportd" or "cycleWiFi" (off and on), for network care with the lid closed.
    func recover(_ step: String, reply: @escaping (Data) -> Void)
    /// Bitwarden's `bw` as the hidden user `_aosvault` (a `VaultRequest`, answered with a `VaultReply`; see
    /// BitwardenRunner and BitwardenVaultHost).
    func vault(_ request: Data, reply: @escaping (Data) -> Void)
}

public enum PowerHelperService {
    public static let label = Brand.bundleIdentifierPrefix + ".powerd"
    public static let machService = label
    public static let plistName = label + ".plist"
    public static let teamID = "S3725YB7V6"
    /// Xcode signs a command line tool with its file name as identifier.
    public static let helperIdentifier = "aos-powerd"
    /// Bumped when the interface changes.
    public static let version = 2

    /// Only aOS may talk to the helper.
    public static var appRequirement: String {
        "anchor apple generic and identifier \"\(Brand.bundleIdentifierPrefix)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// And aOS talks only to its own helper.
    public static var helperRequirement: String {
        "anchor apple generic and identifier \"\(helperIdentifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    public enum Recovery: String, Sendable { case restartAirportd, cycleWiFi }
}

public struct HelperStatus: Codable, Equatable, Sendable {
    public var version: Int
    /// The helper set pmset disablesleep 1 and holds it.
    public var holding: Bool
    public var leaseUntil: Date?
    /// pmset's SleepDisabled as read last.
    public var sleepDisabled: Int?
    public var cloupiPresent: Bool
    /// The user's own hotspots by name, from macOS's known networks (nil when the helper couldn't read them).
    public var hotspotNames: [String]?
    /// The last problem, for the settings.
    public var note: String?

    public init(version: Int = PowerHelperService.version, holding: Bool = false, leaseUntil: Date? = nil,
                sleepDisabled: Int? = nil, cloupiPresent: Bool = false, hotspotNames: [String]? = nil, note: String? = nil) {
        self.version = version
        self.holding = holding
        self.leaseUntil = leaseUntil
        self.sleepDisabled = sleepDisabled
        self.cloupiPresent = cloupiPresent
        self.hotspotNames = hotspotNames
        self.note = note
    }
}

public struct HelperReply: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var status: HelperStatus?
    /// After applying the hotspot choice: what macOS reports now.
    public var wifi: WiFiState?

    public init(ok: Bool, message: String = "", status: HelperStatus? = nil, wifi: WiFiState? = nil) {
        self.ok = ok
        self.message = message
        self.status = status
        self.wifi = wifi
    }

    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data("{\"ok\":false,\"message\":\"encoding\"}".utf8) }

    public static func decode(_ data: Data) -> HelperReply {
        (try? JSONDecoder().decode(HelperReply.self, from: data)) ?? HelperReply(ok: false, message: "unreadable reply")
    }
}

/// The app's side of the connection. Calls are async and never hang: each has a deadline.
public final class PowerHelperClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init() {}

    private func proxy(_ onError: @escaping (Error) -> Void) -> PowerHelperXPC? {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let c = NSXPCConnection(machServiceName: PowerHelperService.machService, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: PowerHelperXPC.self)
            c.setCodeSigningRequirement(PowerHelperService.helperRequirement)
            c.invalidationHandler = { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.connection = nil
                self.lock.unlock()
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? PowerHelperXPC
    }

    /// Ends the connection (the helper exits on its own when idle).
    public func disconnect() {
        lock.lock()
        let c = connection
        connection = nil
        lock.unlock()
        c?.invalidate()
    }

    private func call(timeout: TimeInterval, _ body: @escaping (PowerHelperXPC, @escaping (Data) -> Void) -> Void) async -> HelperReply {
        await withCheckedContinuation { (continuation: CheckedContinuation<HelperReply, Never>) in
            let once = Once()
            let finish: (HelperReply) -> Void = { reply in if once.claim() { continuation.resume(returning: reply) } }
            guard let p = proxy({ error in finish(HelperReply(ok: false, message: error.localizedDescription)) }) else {
                finish(HelperReply(ok: false, message: "no connection to the helper"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(HelperReply(ok: false, message: "the helper didn't answer"))
            }
            body(p) { data in finish(HelperReply.decode(data)) }
        }
    }

    public func status() async -> HelperReply { await call(timeout: 10) { $0.status(reply: $1) } }
    public func hold(seconds: Int, timeout: TimeInterval = 15) async -> HelperReply {
        await call(timeout: timeout) { $0.hold(seconds: seconds, reply: $1) }
    }
    /// The choice for the closed lid; the helper notes the user's own settings first.
    public func apply(_ join: HotspotJoin) async -> HelperReply {
        await call(timeout: 90) { $0.applyHotspotJoin(join.rawValue, reply: $1) }
    }

    /// The lid opened: the user's own hotspot settings again (nothing happens if none were noted).
    public func restoreHotspot() async -> HelperReply {
        await call(timeout: 90) { $0.applyHotspotJoin("restore", reply: $1) }
    }
    public func join(network: String) async -> HelperReply { await call(timeout: 60) { $0.join(network: network, reply: $1) } }
    /// Bitwarden through the helper (`HelperBitwardenRunner(send:)` uses this).
    public func vault(_ request: VaultRequest) async -> VaultReply {
        await withCheckedContinuation { (continuation: CheckedContinuation<VaultReply, Never>) in
            let once = Once()
            let finish: (VaultReply) -> Void = { r in if once.claim() { continuation.resume(returning: r) } }
            guard let p = proxy({ error in finish(VaultReply(ok: false, message: error.localizedDescription)) }) else {
                finish(VaultReply(ok: false, message: "no connection to the helper"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + (request.timeout ?? 120) + 15) {
                finish(VaultReply(ok: false, message: "the helper didn't answer"))
            }
            p.vault(request.data) { data in finish(VaultReply.decode(data)) }
        }
    }

    public func recover(_ step: PowerHelperService.Recovery) async -> HelperReply {
        await call(timeout: 45) { $0.recover(step.rawValue, reply: $1) }
    }
}

/// True exactly once (a reply, an error and a deadline race to finish one call).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
