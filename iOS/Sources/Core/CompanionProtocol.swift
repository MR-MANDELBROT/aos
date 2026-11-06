import CryptoKit
import Foundation

// The companion API between the iPhone and `aos-companion serve` on the Mac (Docs/COMPANION.md, "Companion API"):
// JSON lines in both directions (UTF-8, one object per line). Requests carry an `id`; answers repeat it with `ok` and
// either a result or `error`. After `subscribe` the Mac sends events without `id` at any time.

/// Any JSON value; messages are decoded leniently so a newer Mac can add fields.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var number: Double? { if case .number(let n) = self { return n }; return nil }
    var int: Int? { number.flatMap { $0.rounded() == $0 && abs($0) < 1e15 ? Int($0) : nil } }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    subscript(key: String) -> JSONValue? { object?[key] }
}

enum ScreenTarget: String, Codable, Sendable, CaseIterable {
    /// The paired Mac's own screen (screen sharing on 127.0.0.1:5900 of the Mac).
    case mac
    /// The aOS workspace, the virtual Mac.
    case workspace
}

/// Requests from the iPhone.
enum CompanionRequest: Sendable, Equatable {
    case hello(app: String, device: String)
    case status
    case subscribe
    case screen(target: ScreenTarget)
    /// A Bitwarden login the person approved (its id): the Mac gets it from Bitwarden and fills it (for a code
    /// request: its current one-time code). `host`: the request's website, as the person saw it (signed).
    case signInLogin(request: String, host: String, login: String)
    /// A sign-in from another password app (AutoFill). Never logged, never stored.
    case signInAnswer(request: String, host: String, username: String, password: String, totp: String?)
    case signInDecline(request: String, host: String)
    /// A one-time code, for a request whose field is `code` (only `totp` goes out).
    case signInCode(request: String, host: String, totp: String)
    case helpDone(request: String)
    /// Whether the agent may open the workspace.
    case approvalAnswer(request: String, allowed: Bool)
    /// Types text into the running workspace (ASCII as keys, the rest through the guest's clipboard).
    case type(text: String)

    var op: String {
        switch self {
        case .hello: "hello"
        case .status: "status"
        case .subscribe: "subscribe"
        case .screen: "screen"
        case .signInLogin, .signInAnswer, .signInDecline, .signInCode: "signin.answer"
        case .helpDone: "help.done"
        case .approvalAnswer: "approval.answer"
        case .type: "type"
        }
    }

    /// The operation as aOS on the Mac gets it from `aos-companion` (what the signature names).
    var signedOp: String {
        switch self {
        case .hello, .status, .subscribe, .screen, .type: "companion." + op
        default: op
        }
    }

    /// The totp that goes out with an AutoFill answer (an empty one doesn't).
    private static func sentTOTP(_ totp: String?) -> String? {
        guard let totp, !totp.isEmpty else { return nil }
        return totp
    }

    /// What the Mac reads from this request to check its signature (Docs/COMPANION.md, "Signed requests").
    func signatureFields(key: String, ts: Int, nonce: String) -> CompanionSignature.Fields {
        var f = CompanionSignature.Fields(op: signedOp, key: key, ts: ts, nonce: nonce)
        switch self {
        case .hello, .status, .subscribe:
            break
        case .screen(let target):
            f.target = target.rawValue
        case .signInLogin(let request, let host, let login):
            f.request = request
            f.host = host
            f.decision = "login"
            f.login = login
        case .signInAnswer(let request, let host, let username, let password, let totp):
            f.request = request
            f.host = host
            f.decision = "fill"
            f.data = CompanionSignature.dataDigest(username: username, password: password, totp: Self.sentTOTP(totp))
        case .signInDecline(let request, let host):
            f.request = request
            f.host = host
            f.decision = "decline"
        case .signInCode(let request, let host, let totp):
            f.request = request
            f.host = host
            f.decision = "code"
            f.data = CompanionSignature.dataDigest(totp: totp)
        case .helpDone(let request):
            f.request = request
            f.decision = "done"
        case .approvalAnswer(let request, let allowed):
            f.request = request
            f.decision = allowed ? "allow" : "deny"
        case .type(let text):
            f.data = CompanionSignature.dataDigest(text: text)
        }
        return f
    }

    /// The request as one JSON line (with its terminating "\n"), with the phone's signature if given.
    func line(id: Int, auth: CompanionAuth? = nil) throws -> Data {
        var object: [String: JSONValue] = ["id": .number(Double(id)), "op": .string(op)]
        switch self {
        case .hello(let app, let device):
            object["app"] = .string(app)
            object["device"] = .string(device)
        case .status, .subscribe:
            break
        case .screen(let target):
            object["target"] = .string(target.rawValue)
        case .signInLogin(let request, let host, let login):
            object["request"] = .string(request)
            object["host"] = .string(host)
            object["login"] = .string(login)
        case .signInAnswer(let request, let host, let username, let password, let totp):
            object["request"] = .string(request)
            object["host"] = .string(host)
            object["username"] = .string(username)
            object["password"] = .string(password)
            if let totp = Self.sentTOTP(totp) { object["totp"] = .string(totp) }
        case .signInDecline(let request, let host):
            object["request"] = .string(request)
            object["host"] = .string(host)
            object["decline"] = .bool(true)
        case .signInCode(let request, let host, let totp):
            object["request"] = .string(request)
            object["host"] = .string(host)
            object["totp"] = .string(totp)
        case .helpDone(let request):
            object["request"] = .string(request)
        case .approvalAnswer(let request, let allowed):
            object["request"] = .string(request)
            object["allowed"] = .bool(allowed)
        case .type(let text):
            object["text"] = .string(text)
        }
        if let auth { object["auth"] = auth.json }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(JSONValue.object(object))
        data.append(0x0A)
        return data
    }
}

/// The signature on a request (`"auth"` in its line). The Mac checks it before it does anything.
struct CompanionAuth: Sendable, Equatable {
    /// This iPhone's id on the Mac: first 12 hex characters of the SHA-256 of its SSH key blob.
    var key: String
    /// Unix time in seconds; the Mac takes it within 2 minutes of its own clock.
    var ts: Int
    /// 16 random bytes, base64url without padding; never the same twice.
    var nonce: String
    /// ECDSA P-256 with SHA-256 over `CompanionSignature.message`: r and s (64 bytes), base64.
    var sig: String

    var json: JSONValue {
        .object(["key": .string(key), "ts": .number(Double(ts)), "nonce": .string(nonce), "sig": .string(sig)])
    }

    init(key: String, ts: Int, nonce: String, sig: String) {
        self.key = key
        self.ts = ts
        self.nonce = nonce
        self.sig = sig
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let key = o["key"]?.string, let ts = o["ts"]?.int, let nonce = o["nonce"]?.string,
              let sig = o["sig"]?.string else { return nil }
        self.init(key: key, ts: ts, nonce: nonce, sig: sig)
    }
}

/// What the iPhone signs, the same text the Mac rebuilds (AOSKit `CompanionSignature`): these lines, UTF-8, joined with
/// "\n" and no newline at the end. No value may contain a line break.
///
///     aos-companion-v1
///     op=<companion.hello|companion.status|companion.subscribe|companion.screen|companion.type|signin.answer|help.done|approval.answer>
///     key=<phone id>
///     ts=<seconds>
///     nonce=<nonce>
///     request=<request id or empty>
///     decision=<login|fill|code|decline, allow|deny, done, or empty>
///     login=<Bitwarden item id or empty>
///     host=<the sign-in's website or empty>
///     target=<mac|workspace or empty>
///     data=<dataDigest of user name, password, code, typed text>
enum CompanionSignature {
    static let version = "aos-companion-v1"

    struct Fields: Equatable, Sendable {
        var op: String
        var key: String
        var ts: Int
        var nonce: String
        var request = ""
        var decision = ""
        var login = ""
        var host = ""
        var target = ""
        var data = CompanionSignature.dataDigest()
    }

    static func message(_ f: Fields) -> Data? {
        let values = [f.op, f.key, String(f.ts), f.nonce, f.request, f.decision, f.login, f.host, f.target, f.data]
        guard !values.contains(where: { $0.unicodeScalars.contains { $0 == "\n" || $0 == "\r" } }) else { return nil }
        let lines = [version, "op=\(f.op)", "key=\(f.key)", "ts=\(f.ts)", "nonce=\(f.nonce)", "request=\(f.request)",
                     "decision=\(f.decision)", "login=\(f.login)", "host=\(f.host)", "target=\(f.target)",
                     "data=\(f.data)"]
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// For each field present, in this order: `<name>:<UTF-8 byte count>:<value>\n`; SHA-256 of that, lowercase hex.
    static func dataDigest(username: String? = nil, password: String? = nil, totp: String? = nil,
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
}

/// An answer to a request.
struct CompanionResponse: Sendable, Equatable {
    var id: Int
    var ok: Bool
    var error: String?
    var body: [String: JSONValue]

    /// Why the Mac refused: "pair-again" (it has no signing key for this iPhone), "clock", "invalid".
    var code: String? { body["code"]?.string }
}

enum WorkspaceState: Equatable, Sendable {
    case stopped, starting, open, closing
    case other(String)

    init(_ raw: String) {
        switch raw {
        case "stopped": self = .stopped
        case "starting": self = .starting
        case "open": self = .open
        case "closing": self = .closing
        default: self = .other(raw)
        }
    }
}

/// A sign-in the agent asks for. Shown to the person, who approves or declines it.
struct SignInRequest: Identifiable, Equatable, Sendable {
    /// Where the agent clicked on the page.
    enum Field: String, Sendable {
        case username, password
        /// A one-time code: the answer carries the code only.
        case code
    }

    var id: String
    var agent: String
    var host: String
    var purpose: String
    var expires: Date?
    var field: Field = .password
    /// The person's Bitwarden logins for the site, as the Mac found them (never a password).
    var logins: [BitwardenLogin] = []
    var bitwarden: BitwardenState = .off

    /// The logins that can answer this request: all of them, for a code those with an authenticator key.
    var choices: [BitwardenLogin] { field == .code ? logins.filter(\.hasCode) : logins }
}

/// A Bitwarden login the Mac offers for a sign-in: which one, never its password or authenticator key.
struct BitwardenLogin: Identifiable, Equatable, Sendable {
    /// Bitwarden's id; the answer names it.
    var id: String
    var name: String
    var username: String
    /// Bitwarden has an authenticator key for it: the Mac fills its current one-time code.
    var hasCode: Bool
}

/// Bitwarden in aOS on the Mac, as a sign-in request reports it.
enum BitwardenState: String, Sendable, Equatable {
    /// Unlocked: the request's logins are its matches for the site (maybe none).
    case unlocked
    /// Signed in, but locked: the person unlocks it in aOS on the Mac first.
    case locked
    /// No Bitwarden account in aOS (or a Mac from before Bitwarden): another password app's AutoFill only.
    case off
    /// Bitwarden didn't answer on the Mac.
    case unavailable
}

enum SignInResult: String, Sendable, Equatable {
    case filled, declined, expired, failed
    case unknown
}

/// The agent asks for help in the workspace (a captcha, a sign-in it can't do).
struct HelpRequest: Identifiable, Equatable, Sendable {
    struct Region: Equatable, Sendable {
        var x: Double, y: Double, width: Double, height: Double
        var isEmpty: Bool { width <= 0 || height <= 0 }
    }

    var id: String
    var agent: String
    var purpose: String
    /// The part of the workspace screen (pixels) that needs the person, if the agent named one.
    var region: Region?
}

/// An agent that can't ask by itself wants to open the workspace.
struct ApprovalRequest: Identifiable, Equatable, Sendable {
    var id: String
    var agent: String
    var purpose: String
    /// How long the workspace would stay open.
    var minutes: Int?
    var expires: Date?
}

enum ApprovalResult: String, Sendable, Equatable {
    case allowed, declined
    case unknown
}

enum CompanionEvent: Equatable, Sendable {
    case signIn(SignInRequest)
    case signInClosed(request: String, result: SignInResult)
    case help(HelpRequest)
    case helpClosed(request: String)
    case approval(ApprovalRequest)
    case approvalClosed(request: String, result: ApprovalResult)
    /// `aos-companion` can't reach the Mac app (`unavailable`, it keeps trying), or can again.
    case mac(state: String, detail: String)
    case workspace(WorkspaceState)
    /// The Mac ended the event subscription (aOS restarted, or it ran out): the iPhone subscribes again, signed.
    case subscriptionEnded
}

/// One decoded line from the Mac.
enum CompanionMessage: Equatable, Sendable {
    case response(CompanionResponse)
    case event(CompanionEvent)
    /// Valid JSON the app doesn't know (a newer Mac); ignored.
    case ignored

    enum DecodeError: Error, Equatable { case notJSON, notAnObject }

    static func decode(line: Data) throws -> CompanionMessage {
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: line) } catch { throw DecodeError.notJSON }
        guard let object = value.object else { throw DecodeError.notAnObject }

        if let id = object["id"]?.int {
            return .response(CompanionResponse(id: id, ok: object["ok"]?.bool ?? false,
                                               error: object["error"]?.string, body: object))
        }
        guard let name = object["event"]?.string else { return .ignored }
        let request = object["request"]?.string ?? ""
        switch name {
        case "signin":
            guard !request.isEmpty, let host = object["host"]?.string, !host.isEmpty else { return .ignored }
            let logins: [BitwardenLogin] = (object["logins"]?.array ?? []).compactMap { value in
                guard let o = value.object, let id = o["id"]?.string, !id.isEmpty else { return nil }
                return BitwardenLogin(id: id, name: o["name"]?.string ?? "", username: o["username"]?.string ?? "",
                                      hasCode: o["totp"]?.bool ?? false)
            }
            return .event(.signIn(SignInRequest(
                id: request, agent: object["agent"]?.string ?? "", host: host,
                purpose: object["purpose"]?.string ?? "",
                expires: object["expires"]?.string.flatMap(ISO8601.parse),
                field: SignInRequest.Field(rawValue: object["field"]?.string ?? "") ?? .password,
                logins: logins,
                bitwarden: BitwardenState(rawValue: object["bitwarden"]?.string ?? "") ?? .off)))
        case "signin.closed":
            guard !request.isEmpty else { return .ignored }
            return .event(.signInClosed(request: request,
                                        result: SignInResult(rawValue: object["result"]?.string ?? "") ?? .unknown))
        case "help":
            guard !request.isEmpty else { return .ignored }
            var region: HelpRequest.Region?
            if let r = object["region"]?.object, let x = r["x"]?.number, let y = r["y"]?.number,
               let w = r["w"]?.number, let h = r["h"]?.number {
                let candidate = HelpRequest.Region(x: x, y: y, width: w, height: h)
                region = candidate.isEmpty ? nil : candidate
            }
            return .event(.help(HelpRequest(id: request, agent: object["agent"]?.string ?? "",
                                            purpose: object["purpose"]?.string ?? "", region: region)))
        case "help.closed":
            guard !request.isEmpty else { return .ignored }
            return .event(.helpClosed(request: request))
        case "approval":
            guard !request.isEmpty else { return .ignored }
            return .event(.approval(ApprovalRequest(
                id: request, agent: object["agent"]?.string ?? "", purpose: object["purpose"]?.string ?? "",
                minutes: object["minutes"]?.int, expires: object["expires"]?.string.flatMap(ISO8601.parse))))
        case "approval.closed":
            guard !request.isEmpty else { return .ignored }
            return .event(.approvalClosed(request: request,
                                          result: ApprovalResult(rawValue: object["result"]?.string ?? "") ?? .unknown))
        case "mac":
            guard let state = object["state"]?.string else { return .ignored }
            return .event(.mac(state: state, detail: object["detail"]?.string ?? ""))
        case "workspace":
            guard let state = object["state"]?.string else { return .ignored }
            return .event(.workspace(WorkspaceState(state)))
        case "subscription":
            return object["state"]?.string == "ended" ? .event(.subscriptionEnded) : .ignored
        default:
            return .ignored
        }
    }
}

// MARK: Results of requests

struct HelloResult: Equatable, Sendable {
    var mac: String
    var aos: String

    init(_ r: CompanionResponse) {
        mac = r.body["mac"]?.string ?? ""
        aos = r.body["aos"]?.string ?? ""
    }
}

struct WorkspaceStatus: Equatable, Sendable {
    struct Session: Equatable, Sendable, Identifiable {
        var id: Int
        var title: String
        var state: String
    }

    var state: WorkspaceState
    var purpose: String
    var until: Date?
    var sessions: [Session]

    init(state: WorkspaceState, purpose: String = "", until: Date? = nil, sessions: [Session] = []) {
        self.state = state
        self.purpose = purpose
        self.until = until
        self.sessions = sessions
    }

    init(_ r: CompanionResponse) {
        let workspace = r.body["workspace"]?.object ?? [:]
        state = WorkspaceState(workspace["state"]?.string ?? "stopped")
        purpose = workspace["purpose"]?.string ?? ""
        until = workspace["until"]?.string.flatMap(ISO8601.parse)
        sessions = (r.body["sessions"]?.array ?? []).enumerated().compactMap { index, value in
            guard let o = value.object else { return nil }
            return Session(id: index, title: o["title"]?.string ?? "", state: o["state"]?.string ?? "")
        }
    }
}

/// Where a screen is and how to log in to it.
struct ScreenEndpoint: Equatable, Sendable {
    var host: String
    var port: UInt16
    var username: String?
    var password: String?

    init(host: String, port: UInt16, username: String? = nil, password: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    init?(_ r: CompanionResponse) {
        guard let host = r.body["host"]?.string, !host.isEmpty,
              let port = r.body["port"]?.int, (1...65535).contains(port) else { return nil }
        self.host = host
        self.port = UInt16(port)
        username = r.body["username"]?.string
        password = r.body["password"]?.string
    }
}

enum ISO8601 {
    static func parse(_ text: String) -> Date? {
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        return (try? withFraction.parse(text)) ?? (try? plain.parse(text))
    }

    static func format(_ date: Date) -> String { date.formatted(Date.ISO8601FormatStyle()) }
}

/// Splits a byte stream into lines ("\n", an optional "\r" before it is dropped). Lines longer than `limit` are an
/// error, so a broken peer can't make the app buffer without end.
struct LineSplitter: Sendable {
    var limit = 1 << 20
    private var buffer = Data()

    struct LineTooLong: Error {}

    init(limit: Int = 1 << 20) { self.limit = limit }

    mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(Data(line))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if buffer.count > limit { throw LineTooLong() }
        return lines
    }
}
