import Foundation

// The companion API between the iPhone and `annex-companion serve` on the Mac (Docs/COMPANION.md, "Companion API"):
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
    /// The Annex workspace, the virtual Mac.
    case workspace
}

/// Requests from the iPhone.
enum CompanionRequest: Sendable, Equatable {
    case hello(app: String, device: String)
    case status
    case subscribe
    case screen(target: ScreenTarget)
    /// The sign-in for a request. Never logged, never stored.
    case signInAnswer(request: String, username: String, password: String, totp: String?)
    case signInDecline(request: String)
    /// A one-time code, for a request whose field is `code` (only `totp` goes out).
    case signInCode(request: String, totp: String)
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
        case .signInAnswer, .signInDecline, .signInCode: "signin.answer"
        case .helpDone: "help.done"
        case .approvalAnswer: "approval.answer"
        case .type: "type"
        }
    }

    /// The request as one JSON line (with its terminating "\n").
    func line(id: Int) throws -> Data {
        var object: [String: JSONValue] = ["id": .number(Double(id)), "op": .string(op)]
        switch self {
        case .hello(let app, let device):
            object["app"] = .string(app)
            object["device"] = .string(device)
        case .status, .subscribe:
            break
        case .screen(let target):
            object["target"] = .string(target.rawValue)
        case .signInAnswer(let request, let username, let password, let totp):
            object["request"] = .string(request)
            object["username"] = .string(username)
            object["password"] = .string(password)
            if let totp, !totp.isEmpty { object["totp"] = .string(totp) }
        case .signInDecline(let request):
            object["request"] = .string(request)
            object["decline"] = .bool(true)
        case .signInCode(let request, let totp):
            object["request"] = .string(request)
            object["totp"] = .string(totp)
        case .helpDone(let request):
            object["request"] = .string(request)
        case .approvalAnswer(let request, let allowed):
            object["request"] = .string(request)
            object["allowed"] = .bool(allowed)
        case .type(let text):
            object["text"] = .string(text)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(JSONValue.object(object))
        data.append(0x0A)
        return data
    }
}

/// An answer to a request.
struct CompanionResponse: Sendable, Equatable {
    var id: Int
    var ok: Bool
    var error: String?
    var body: [String: JSONValue]
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
    /// `annex-companion` can't reach the Mac app (`unavailable`, it keeps trying), or can again.
    case mac(state: String, detail: String)
    case workspace(WorkspaceState)
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
            return .event(.signIn(SignInRequest(
                id: request, agent: object["agent"]?.string ?? "", host: host,
                purpose: object["purpose"]?.string ?? "",
                expires: object["expires"]?.string.flatMap(ISO8601.parse),
                field: SignInRequest.Field(rawValue: object["field"]?.string ?? "") ?? .password)))
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
        default:
            return .ignored
        }
    }
}

// MARK: Results of requests

struct HelloResult: Equatable, Sendable {
    var mac: String
    var annex: String

    init(_ r: CompanionResponse) {
        mac = r.body["mac"]?.string ?? ""
        annex = r.body["annex"]?.string ?? ""
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
