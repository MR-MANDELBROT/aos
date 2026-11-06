import Darwin
import Foundation
import Security

/// Bitwarden's session key while the vault is unlocked for aOS, with when it was unlocked and when it locks again.
/// The key opens the vault for `bw` (BW_SESSION) until `bw lock`; it never leaves the Mac.
public struct BitwardenSession: Codable, Equatable, Sendable {
    public var key: String
    public var unlocked: Date
    public var until: Date

    public init(key: String, unlocked: Date, until: Date) {
        self.key = key
        self.unlocked = unlocked
        self.until = until
    }

    /// Still good: before its time, and the Mac neither slept nor restarted since it was unlocked.
    public func isValid(now: Date = Date(), lastSleep: Date? = SystemClock.lastSleep, boot: Date? = SystemClock.boot) -> Bool {
        if now >= until || now < unlocked.addingTimeInterval(-300) { return false }
        if let boot, boot > unlocked { return false }
        if let lastSleep, lastSleep > unlocked { return false }
        return true
    }
}

/// When the Mac last went to sleep and when it started (the kernel's own clock of both).
public enum SystemClock {
    public static var lastSleep: Date? { time("kern.sleeptime") }
    public static var boot: Date? { time("kern.boottime") }

    private static func time(_ name: String) -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000)
    }
}

/// Where the session key is kept while the vault is unlocked.
public protocol BitwardenSessionStore: Sendable {
    func load() -> BitwardenSession?
    func save(_ session: BitwardenSession) throws
    func delete()
}

/// In the Mac's login keychain: one generic password item that only aOS may read. macOS puts the program that
/// created an item on its access list; any other program has to ask the person (macOS names who asks), so aOS's
/// session key isn't readable for other programs without the person's yes. Never synchronized.
public struct KeychainSessionStore: BitwardenSessionStore {
    public let service: String
    let account = "session"

    public init(service: String = Brand.bundleIdentifierPrefix + ".bitwarden") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> BitwardenSession? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(BitwardenSession.self, from: data)
    }

    public func save(_ session: BitwardenSession) throws {
        delete()
        var attributes = query
        attributes[kSecValueData as String] = try JSONEncoder().encode(session)
        attributes[kSecAttrLabel as String] = "\(Brand.name): Bitwarden session"
        attributes[kSecAttrDescription as String] = "Unlocks Bitwarden for \(Brand.name) until it locks again"
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw BitwardenError.unexpected("keychain \(status)") }
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// In memory only (tests, and when the keychain refuses).
public final class MemorySessionStore: BitwardenSessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: BitwardenSession?

    public init(_ session: BitwardenSession? = nil) { self.session = session }

    public func load() -> BitwardenSession? { lock.withLock { session } }
    public func save(_ session: BitwardenSession) throws { lock.withLock { self.session = session } }
    public func delete() { lock.withLock { session = nil } }
}
