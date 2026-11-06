import CryptoKit
import Foundation
import Security

// Signed requests from the iPhone (Docs/COMPANION.md, "Signed requests"). Every process of the user can reach the
// agent socket and run aos-companion, and ~/.ssh/authorized_keys is the user's to edit: neither proves that a request
// comes from the paired iPhone. So the iPhone signs each request with a P-256 key that pairing gave the Mac (bound to
// the pairing code), the Mac keeps those keys in its keychain, and the app checks every phone request against them.

/// The signature on one request from the iPhone.
public struct CompanionAuth: Codable, Sendable, Equatable {
    /// The phone's id: the first 12 hex characters of its SSH key's SHA-256, as in authorized_keys.
    public var key: String
    /// When the phone signed, Unix time in seconds.
    public var ts: Int
    /// 16 random bytes in base64url without padding; the Mac takes each one once.
    public var nonce: String
    /// ECDSA P-256 with SHA-256 over `CompanionSignature.message`: r and s (64 bytes) in base64.
    public var sig: String

    public init(key: String, ts: Int, nonce: String, sig: String) {
        self.key = key
        self.ts = ts
        self.nonce = nonce
        self.sig = sig
    }
}

/// What a phone signs: one line per field, in this order, UTF-8, joined with "\n" (no newline at the end):
///
///     aos-companion-v1
///     op=<op as the app gets it: companion.status, signin.answer, ...>
///     key=<phone id>
///     ts=<seconds>
///     nonce=<nonce>
///     request=<request id or empty>
///     decision=<login|fill|code|decline for signin.answer, allow|deny for approval.answer, done for help.done, else empty>
///     login=<Bitwarden item id or empty>
///     host=<the sign-in's website or empty>
///     target=<mac|workspace for companion.screen, else empty>
///     data=<hex SHA-256 of the free text fields, see `dataDigest`>
///
/// No value may contain a line break (such a request is refused), so no two requests have the same message.
public enum CompanionSignature {
    public static let version = "aos-companion-v1"

    public struct Fields: Equatable, Sendable {
        public var op: String
        public var key: String
        public var ts: Int
        public var nonce: String
        public var request = ""
        public var decision = ""
        public var login = ""
        public var host = ""
        public var target = ""
        public var data = CompanionSignature.dataDigest()

        public init(op: String, key: String, ts: Int, nonce: String, request: String = "", decision: String = "",
                    login: String = "", host: String = "", target: String = "",
                    data: String = CompanionSignature.dataDigest()) {
            self.op = op
            self.key = key
            self.ts = ts
            self.nonce = nonce
            self.request = request
            self.decision = decision
            self.login = login
            self.host = host
            self.target = target
            self.data = data
        }
    }

    /// The bytes that are signed, or nil if a value has a line break.
    public static func message(_ f: Fields) -> Data? {
        let values = [f.op, f.key, String(f.ts), f.nonce, f.request, f.decision, f.login, f.host, f.target, f.data]
        // By scalar: "\r\n" is one Character, which a Character-wise search for "\n" misses.
        guard !values.contains(where: { $0.unicodeScalars.contains { $0 == "\n" || $0 == "\r" } }) else { return nil }
        let lines = [version, "op=\(f.op)", "key=\(f.key)", "ts=\(f.ts)", "nonce=\(f.nonce)", "request=\(f.request)",
                     "decision=\(f.decision)", "login=\(f.login)", "host=\(f.host)", "target=\(f.target)",
                     "data=\(f.data)"]
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// The free text a request carries (user name, password, code, typed text), hashed so the signature covers it
    /// without a line format for it: for each field that is present, in this order, `<name>:<UTF-8 byte count>:<value>\n`,
    /// then SHA-256 in lowercase hex (of nothing, if no field is present).
    public static func dataDigest(username: String? = nil, password: String? = nil, totp: String? = nil,
                                  text: String? = nil) -> String {
        var data = Data()
        for (name, value) in [("username", username), ("password", password), ("totp", totp), ("text", text)] {
            guard let value else { continue }
            data.append(Data("\(name):\(value.utf8.count):".utf8))
            data.append(Data(value.utf8))
            data.append(0x0A)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What the answer decides, read from its fields the way the app acts on them.
    public static func decision(for r: AgentRequest) -> String {
        switch r.op {
        case "signin.answer":
            if r.decline == true { return "decline" }
            if r.login != nil { return "login" }
            if r.username != nil || r.password != nil { return "fill" }
            return r.totp != nil ? "code" : ""
        case "approval.answer": return r.allowed == true ? "allow" : "deny"
        case "help.done": return "done"
        default: return ""
        }
    }

    public static func fields(for r: AgentRequest, auth: CompanionAuth) -> Fields {
        Fields(op: r.op, key: auth.key, ts: auth.ts, nonce: auth.nonce, request: r.request ?? "",
               decision: decision(for: r), login: r.login ?? "", host: r.host ?? "", target: r.target ?? "",
               data: dataDigest(username: r.username, password: r.password, totp: r.totp, text: r.text))
    }
}

/// A phone the user paired with this Mac, as the Mac trusts it.
public struct TrustedPhone: Codable, Sendable, Equatable {
    /// The id from authorized_keys (first 12 hex characters of the SSH key's SHA-256).
    public var id: String
    public var name: String
    /// The phone's P-256 signing key in X9.63 form (65 bytes).
    public var signingKey: Data
    public var paired: Date

    public init(id: String, name: String, signingKey: Data, paired: Date = Date()) {
        self.id = id
        self.name = name
        self.signingKey = signingKey
        self.paired = paired
    }

    static func isID(_ text: String) -> Bool {
        text.count == 12 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// Where the Mac keeps the phones' signing keys.
public protocol PhoneKeyStore: Sendable {
    func phone(id: String) -> TrustedPhone?
    /// The ids of the phones with a key (without reading the keys).
    func ids() -> [String]
    func save(_ phone: TrustedPhone) throws
    func remove(id: String) throws
}

/// One generic password item per phone in the login keychain (service `dev.marquart.aos.phonekeys`, account = phone
/// id): never synchronized, and this device only where macOS honors it (`kSecAttrAccessible` belongs to the data
/// protection keychain, which needs an entitlement aOS doesn't have; the login keychain ignores it).
///
/// Why not a file: another program of the same user could write one. An item another program writes into the login
/// keychain (even with aOS on its access list, or "any application") carries that program's partition, and macOS
/// asks the person before aOS may read it. aOS never lets macOS ask for these items: such an item doesn't count,
/// and that phone has to pair again.
public struct KeychainPhoneKeys: PhoneKeyStore {
    public let service: String

    public init(service: String = Brand.bundleIdentifierPrefix + ".phonekeys") {
        self.service = service
    }

    private func query(_ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    public func phone(id: String) -> TrustedPhone? {
        guard TrustedPhone.isID(id) else { return nil }
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = Self.withoutDialogs { SecItemCopyMatching(q as CFDictionary, &item) }
        guard status == errSecSuccess, let data = item as? Data,
              let phone = try? JSONDecoder().decode(TrustedPhone.self, from: data), phone.id == id else { return nil }
        return phone
    }

    public func ids() -> [String] {
        var q = query()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else { return [] }
        return list.compactMap { $0[kSecAttrAccount as String] as? String }.filter(TrustedPhone.isID)
    }

    public func save(_ phone: TrustedPhone) throws {
        guard TrustedPhone.isID(phone.id) else { throw PhoneKeyError.invalidID }
        try remove(id: phone.id)
        var attributes = query(phone.id)
        attributes[kSecValueData as String] = try JSONEncoder().encode(phone)
        attributes[kSecAttrLabel as String] = "\(Brand.name): iPhone \(phone.name)"
        attributes[kSecAttrDescription as String] = "Lets this iPhone approve sign-ins and requests in \(Brand.name)"
        attributes[kSecAttrSynchronizable as String] = false
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw PhoneKeyError.keychain(status) }
    }

    public func remove(id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PhoneKeyError.keychain(status) }
    }

    private static let dialogLock = NSLock()
    private typealias GetInteraction = @convention(c) (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus
    private typealias SetInteraction = @convention(c) (DarwinBoolean) -> OSStatus
    // The login keychain's own switch (SecKeychainGet/SetUserInteractionAllowed, deprecated with the rest of
    // SecKeychain but the only thing that works here), looked up by name so the build stays free of warnings.
    private static let getInteraction = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainGetUserInteractionAllowed")
        .map { unsafeBitCast($0, to: GetInteraction.self) }
    private static let setInteraction = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainSetUserInteractionAllowed")
        .map { unsafeBitCast($0, to: SetInteraction.self) }

    /// Runs a keychain read with macOS's dialogs switched off for this process. LAContext's `interactionNotAllowed`
    /// does not keep the login keychain from asking about an item another program made (seen on macOS 27: the read
    /// waits on the dialog); the keychain's own switch does, and the read fails at once.
    static func withoutDialogs<T>(_ body: () -> T) -> T {
        guard let getInteraction, let setInteraction else { return body() }
        dialogLock.lock()
        defer { dialogLock.unlock() }
        var allowed: DarwinBoolean = true
        _ = getInteraction(&allowed)
        _ = setInteraction(false)
        defer { _ = setInteraction(allowed) }
        return body()
    }
}

/// In memory (tests).
public final class MemoryPhoneKeys: PhoneKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var phones: [String: TrustedPhone]

    public init(_ phones: [TrustedPhone] = []) {
        self.phones = Dictionary(phones.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    }

    public func phone(id: String) -> TrustedPhone? { lock.withLock { phones[id] } }
    public func ids() -> [String] { lock.withLock { phones.keys.sorted() } }
    public func save(_ phone: TrustedPhone) throws { lock.withLock { phones[phone.id] = phone } }
    public func remove(id: String) throws { _ = lock.withLock { phones.removeValue(forKey: id) } }
}

public enum PhoneKeyError: LocalizedError {
    case invalidID
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidID: return "Not a phone id."
        case .keychain(let status): return "The keychain refused the iPhone's key (\(status))."
        }
    }
}

/// Why a phone request was refused: `code` for the phone ("pair-again" means the Mac has no key for it), `message`
/// for the person, `reason` for the log (never a secret).
public struct CompanionRefusal: Error, Equatable, Sendable {
    public var code: String
    public var message: String
    public var reason: String

    static func pairAgain(_ reason: String) -> CompanionRefusal {
        CompanionRefusal(code: "pair-again", message: "This iPhone can't approve on this Mac until it is paired again: pair it again in \(Brand.name) on the iPhone (update the app first if it doesn't offer that).", reason: reason)
    }

    static func invalid(_ reason: String, _ message: String = "The request's signature doesn't check out. It was changed on its way or doesn't come from the paired iPhone.") -> CompanionRefusal {
        CompanionRefusal(code: "invalid", message: message, reason: reason)
    }

    static let clock = CompanionRefusal(code: "clock", message: "The iPhone's clock and the Mac's differ by more than 2 minutes. Check the time on both.", reason: "timestamp outside the window")

    static let subscriptionEnded = CompanionRefusal(code: "subscription-ended", message: "The iPhone has to subscribe again.", reason: "unknown or expired subscription")
}

/// Checks the phone's requests before the app acts on them: a known key, a valid signature, a time within 2 minutes,
/// a nonce not seen before. Event polls (aos-companion asks for them by itself, every 25 s) carry a subscription
/// instead: a random token the app gave for a signed `companion.subscribe`, kept by aos-companion only.
@MainActor
public final class CompanionGate {
    /// How far the phone's time may be off, either way.
    public static let window: TimeInterval = 120
    static let nonceCapacity = 4096
    /// A subscription ends when nobody polled with it for this long, and after a day at the latest.
    static let subscriptionIdle: TimeInterval = 300
    static let subscriptionLifetime: TimeInterval = 24 * 3600
    static let subscriptionCapacity = 32

    public let store: PhoneKeyStore
    var now: () -> Date = Date.init
    /// Nonces taken, with their time stamp; forgotten once that time is outside the window anyway.
    private var nonces: [String: Int] = [:]
    private struct Subscription { var phone: String; var created: Date; var used: Date }
    private var subscriptions: [String: Subscription] = [:]

    public init(store: PhoneKeyStore) {
        self.store = store
    }

    /// The phone that sent the request, or why it is refused.
    public func admit(_ r: AgentRequest) -> Result<TrustedPhone, CompanionRefusal> {
        if r.op == "companion.events" { return subscriber(r.subscription) }
        guard let auth = r.auth else { return .failure(.pairAgain("not signed")) }
        guard TrustedPhone.isID(auth.key) else { return .failure(.invalid("malformed key id")) }
        guard auth.nonce.count >= 16, auth.nonce.count <= 64,
              auth.nonce.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return .failure(.invalid("malformed nonce"))
        }
        guard let phone = store.phone(id: auth.key) else { return .failure(.pairAgain("no key for phone \(auth.key)")) }
        let current = now().timeIntervalSince1970
        guard abs(Double(auth.ts) - current) <= Self.window else {
            var refusal = CompanionRefusal.clock
            refusal.reason = "timestamp off by \(Int(Double(auth.ts) - current)) s from phone \(auth.key)"
            return .failure(refusal)
        }
        guard let message = CompanionSignature.message(CompanionSignature.fields(for: r, auth: auth)) else {
            return .failure(.invalid("a field has a line break"))
        }
        guard let raw = Data(base64Encoded: auth.sig), raw.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
              let key = try? P256.Signing.PublicKey(x963Representation: phone.signingKey),
              key.isValidSignature(signature, for: message) else {
            return .failure(.invalid("bad signature from phone \(auth.key)"))
        }
        prune(current)
        guard nonces[auth.nonce] == nil else {
            return .failure(.invalid("nonce seen before (phone \(auth.key))", "This request was sent before."))
        }
        guard nonces.count < Self.nonceCapacity else {
            return .failure(.invalid("too many requests", "Too many requests from the iPhone. Try again in a minute."))
        }
        nonces[auth.nonce] = auth.ts
        return .success(phone)
    }

    /// A new subscription for a phone whose `companion.subscribe` was admitted.
    public func subscribe(_ phone: TrustedPhone) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let time = now()
        subscriptions = subscriptions.filter { live($0.value, at: time) }
        while subscriptions.count >= Self.subscriptionCapacity,
              let oldest = subscriptions.min(by: { $0.value.used < $1.value.used })?.key {
            subscriptions[oldest] = nil
        }
        subscriptions[token] = Subscription(phone: phone.id, created: time, used: time)
        return token
    }

    private func subscriber(_ token: String?) -> Result<TrustedPhone, CompanionRefusal> {
        let time = now()
        guard let token, let s = subscriptions[token], live(s, at: time) else {
            if let token { subscriptions[token] = nil }
            return .failure(.subscriptionEnded)
        }
        // A phone removed meanwhile loses its subscriptions too.
        guard let phone = store.phone(id: s.phone) else {
            subscriptions[token] = nil
            var refusal = CompanionRefusal.subscriptionEnded
            refusal.reason = "phone \(s.phone) no longer paired"
            return .failure(refusal)
        }
        subscriptions[token]?.used = time
        return .success(phone)
    }

    private func live(_ s: Subscription, at time: Date) -> Bool {
        time.timeIntervalSince(s.used) < Self.subscriptionIdle && time.timeIntervalSince(s.created) < Self.subscriptionLifetime
    }

    private func prune(_ current: TimeInterval) {
        guard nonces.count > 64 else { return }
        nonces = nonces.filter { abs(Double($0.value) - current) <= Self.window + 5 }
    }
}

extension WorkspaceController {
    static func isCompanion(_ op: String) -> Bool {
        op.hasPrefix("companion.") || ["signin.answer", "help.done", "approval.answer"].contains(op)
    }

    /// The iPhone's requests: checked (signature, or subscription for event polls) before anything happens. The
    /// device name the rest sees is the paired phone's, not what the request says.
    func admitCompanion(_ request: AgentRequest) async -> AgentResponse {
        let phone: TrustedPhone
        switch phones.admit(request) {
        case .success(let p):
            phone = p
        case .failure(let refusal):
            log("iPhone request \(request.op) refused: \(refusal.reason)")
            return AgentResponse(id: request.id, ok: false, text: refusal.message, code: refusal.code)
        }
        var r = request
        r.device = phone.name
        if r.op == "companion.subscribe" {
            companion.seen(device: phone.name)
            let data = (try? JSONSerialization.data(withJSONObject: ["subscription": phones.subscribe(phone)])) ?? Data()
            return AgentResponse(id: r.id, ok: true, text: String(decoding: data, as: UTF8.self))
        }
        // The phone signed the website it approves for: it must be the one this request is about.
        if r.op == "signin.answer", let id = r.request, let offer = signInOffers[id], r.host != offer.host {
            log("iPhone answer for sign-in \(id) refused: signed for another website")
            return .failure(r.id, "This answer is for another website than the sign-in request. Look at the request again on the iPhone.")
        }
        return await handleCompanion(r)
    }
}
