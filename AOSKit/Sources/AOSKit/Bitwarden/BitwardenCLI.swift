import Foundation

/// Bitwarden's own command line program (`bw`), run as a program of its own: never linked into aOS and never shipped
/// with it (`BitwardenTool` finds Bitwarden's signed build or downloads it from Bitwarden). aOS asks it for exactly
/// what a sign-in needs.
///
/// Secrets never go on a command line: the master password reaches `bw` in an environment variable whose name
/// `--passwordenv` gives, the session key as BW_SESSION, one-time codes on its terminal. Nothing `bw` prints is
/// logged; errors carry only Bitwarden's own message.
public struct BitwardenCLI: Sendable {
    public let executable: String
    /// Bitwarden's own files for aOS (BITWARDENCLI_APPDATA_DIR), apart from the user's own `bw`, if they have one.
    public let dataDirectory: URL
    /// How long one command may take (a sync of a large vault takes a while).
    public var timeout: TimeInterval = 90

    /// The environment variable that carries the master password (only its name is on the command line).
    static let passwordVariable = "AOS_BW_MASTER_PASSWORD"

    public init(executable: String, dataDirectory: URL) {
        self.executable = executable
        self.dataDirectory = dataDirectory
    }

    // MARK: Account

    public struct Status: Equatable, Sendable {
        public enum State: String, Sendable { case unauthenticated, locked, unlocked }
        public var state: State
        public var email: String?
        /// The server's address as Bitwarden has it; nil is Bitwarden's US cloud.
        public var serverURL: String?
        public var lastSync: Date?
    }

    /// `bw status`. With the session key, an unlocked vault reports "unlocked".
    public func status(session: String? = nil) async throws -> Status {
        let reply = try await run(["status"], session: session, timeout: 30)
        let template = (reply.object?["template"] as? [String: Any]) ?? reply.object ?? [:]
        let raw = template["status"] as? String ?? ""
        let state = Status.State(rawValue: raw) ?? (raw.isEmpty ? .unauthenticated : .locked)
        return Status(state: state, email: (template["userEmail"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                      serverURL: (template["serverUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                      lastSync: (template["lastSync"] as? String).flatMap(Self.date))
    }

    /// `bw config server`: only while nobody is signed in.
    public func setServer(_ server: BitwardenServer) async throws {
        _ = try await run(["config", "server", server.configValue], timeout: 30)
    }

    /// `bw --version`, for the settings.
    public func version() async -> String? {
        guard let result = try? await Subprocess.run(executable, ["--version"], environment: environment(interactive: false),
                                                     timeout: 30), result.status == 0 else { return nil }
        let text = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.range(of: #"^[0-9][0-9A-Za-z.\-]{0,30}$"#, options: .regularExpression) != nil ? text : nil
    }

    /// Starts `bw login`: the master password goes in through the environment, the questions Bitwarden asks next
    /// (two-step method and code, new device code) come through the returned conversation.
    public func startLogin(email: String, password: String) throws -> BitwardenLoginConversation {
        guard Self.isEmail(email) else { throw BitwardenError.invalidEmail }
        var env = environment(interactive: true)
        env[Self.passwordVariable] = password
        let process = try Subprocess.interactive(executable, ["login", email, "--passwordenv", Self.passwordVariable],
                                                 environment: env, timeout: BitwardenLoginConversation.timeout)
        return BitwardenLoginConversation(process: process, email: email)
    }

    /// `bw unlock` with the master password; returns the new session key.
    public func unlock(password: String) async throws -> String {
        let reply = try await run(["unlock", "--passwordenv", Self.passwordVariable], password: password, timeout: 60)
        guard let key = reply.object?["raw"] as? String, Self.isSessionKey(key) else {
            throw BitwardenError.unexpected("no session key")
        }
        return key
    }

    /// `bw lock`: the session key stops working.
    public func lock() async throws { _ = try await run(["lock"], timeout: 30) }

    /// `bw logout`: Bitwarden's data for aOS is removed.
    public func logout() async throws { _ = try await run(["logout"], timeout: 30) }

    /// `bw sync`: the newest state of the vault from the server.
    public func sync(session: String) async throws { _ = try await run(["sync"], session: session, timeout: 120) }

    // MARK: Logins

    /// A login as aOS shows it: never its password and never its authenticator key.
    public struct Item: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var username: String
        public var uris: [String]
        /// It has an authenticator key: Bitwarden can give its current one-time code.
        public var hasTOTP: Bool
        /// "Master password re-prompt" is on for it in Bitwarden.
        public var reprompt: Bool

        public init(id: String, name: String, username: String, uris: [String], hasTOTP: Bool, reprompt: Bool = false) {
            self.id = id
            self.name = name
            self.username = username
            self.uris = uris
            self.hasTOTP = hasTOTP
            self.reprompt = reprompt
        }

        /// From Bitwarden's JSON for an item; only logins (type 1) that aren't in the trash.
        init?(json o: [String: Any]) {
            guard let id = o["id"] as? String, BitwardenCLI.isItemID(id), (o["type"] as? Int) == 1,
                  let login = o["login"] as? [String: Any] else { return nil }
            if let deleted = o["deletedDate"], !(deleted is NSNull) { return nil }
            self.id = id
            name = o["name"] as? String ?? ""
            username = login["username"] as? String ?? ""
            uris = (login["uris"] as? [[String: Any]] ?? []).compactMap { $0["uri"] as? String }
            hasTOTP = !((login["totp"] as? String) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            reprompt = (o["reprompt"] as? Int ?? 0) != 0
        }
    }

    /// `bw list items --url https://<host>`: the logins Bitwarden finds for the site (its own matching, which aOS
    /// narrows with `HostMatching`).
    public func items(forHost host: String, session: String) async throws -> [Item] {
        guard Self.isHost(host) else { throw BitwardenError.unexpected("not a website") }
        let reply = try await run(["list", "items", "--url", "https://" + host], session: session)
        let list = (reply.object?["data"] as? [[String: Any]]) ?? (reply.data as? [[String: Any]]) ?? []
        return list.compactMap(Item.init(json:))
    }

    /// `bw get item <id>`: the login with its password, for filling only.
    public func login(id: String, session: String) async throws -> (item: Item, password: String) {
        guard Self.isItemID(id) else { throw BitwardenError.notFound }
        let reply = try await run(["get", "item", id], session: session)
        guard let o = reply.object, let item = Item(json: o), let login = o["login"] as? [String: Any] else {
            throw BitwardenError.notALogin
        }
        return (item, login["password"] as? String ?? "")
    }

    /// `bw get password <id>`.
    public func password(id: String, session: String) async throws -> String {
        guard Self.isItemID(id) else { throw BitwardenError.notFound }
        guard let password = try await run(["get", "password", id], session: session).string else {
            throw BitwardenError.unexpected("no password")
        }
        return password
    }

    /// `bw get totp <id>`: the login's current one-time code.
    public func totp(id: String, session: String) async throws -> String {
        guard Self.isItemID(id) else { throw BitwardenError.notFound }
        guard let code = try await run(["get", "totp", id], session: session).string,
              code.range(of: #"^[0-9A-Za-z]{4,12}$"#, options: .regularExpression) != nil else {
            throw BitwardenError.unexpected("no code")
        }
        return code
    }

    // MARK: Running bw

    /// What `bw` answered (with BW_RESPONSE: `{"success":…,"message":…,"data":…}` on stdout).
    struct Reply {
        var success: Bool
        var message: String?
        var data: Any?

        var object: [String: Any]? { data as? [String: Any] }
        /// A StringResponse (`{"object":"string","data":"…"}`).
        var string: String? { (object?["data"] as? String) ?? (data as? String) }
    }

    /// The last line of the output that is Bitwarden's JSON answer; everything else is ignored (and never logged).
    static func reply(from output: Data) -> Reply? {
        for line in output.split(separator: 0x0A).reversed() {
            guard let first = line.first(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }), first == UInt8(ascii: "{"),
                  let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let success = o["success"] as? Bool else { continue }
            return Reply(success: success, message: o["message"] as? String, data: o["data"])
        }
        return nil
    }

    private func run(_ arguments: [String], session: String? = nil, password: String? = nil,
                     timeout: TimeInterval? = nil) async throws -> Reply {
        var env = environment(interactive: false)
        if let session { env["BW_SESSION"] = session }
        if let password { env[Self.passwordVariable] = password }
        let result: Subprocess.Result
        do {
            result = try await Subprocess.run(executable, arguments, environment: env, timeout: timeout ?? self.timeout)
        } catch {
            throw BitwardenError.notRunnable(error.localizedDescription)
        }
        if result.timedOut { throw BitwardenError.timeout }
        guard let reply = Self.reply(from: result.stdout) else {
            throw BitwardenError.unexpected(Self.describe(result))
        }
        guard reply.success else { throw BitwardenError(message: reply.message) }
        return reply
    }

    /// For an answer without JSON: the exit status and the first line on stderr (an error text, never a secret:
    /// `bw` writes what it's asked for to stdout).
    static func describe(_ result: Subprocess.Result) -> String {
        let text = BitwardenPrompt.plain(String(decoding: result.stderr.prefix(2000), as: UTF8.self))
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return "status \(result.status)" + (line.map { ": " + String($0.prefix(200)) } ?? "")
    }

    /// A small environment of its own: no secrets of the app's, Bitwarden's files apart, English messages, and JSON
    /// answers (BW_RESPONSE). Commands other than the login never ask anything (BW_NOINTERACTION).
    func environment(interactive: Bool) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": inherited["HOME"] ?? NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "BITWARDENCLI_APPDATA_DIR": dataDirectory.path,
            "BW_RESPONSE": "true",
        ]
        for key in ["USER", "LOGNAME", "TMPDIR", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy",
                    "no_proxy", "NODE_EXTRA_CA_CERTS"] {
            if let value = inherited[key] { env[key] = value }
        }
        if interactive {
            env["TERM"] = "xterm-256color"
        } else {
            env["BW_NOINTERACTION"] = "true"
        }
        return env
    }

    // MARK: Checks (what goes on a command line must be what it claims to be)

    /// Bitwarden's item ids are UUIDs; nothing else reaches the command line (an id can't pose as an option).
    static func isItemID(_ id: String) -> Bool {
        id.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
                 options: .regularExpression) != nil
    }

    static func isEmail(_ email: String) -> Bool {
        email.count <= 254 && email.range(of: #"^[^\s@\-][^\s@]*@[^\s@]+$"#, options: .regularExpression) != nil
    }

    static func isHost(_ host: String) -> Bool {
        host.count <= 253 && host.range(of: #"^[A-Za-z0-9][A-Za-z0-9.\-]*$"#, options: .regularExpression) != nil
    }

    /// Bitwarden's session keys are base64 (64 bytes); anything else is not one.
    static func isSessionKey(_ key: String) -> Bool {
        key.count >= 16 && key.count <= 512 && key.range(of: #"^[A-Za-z0-9+/=]+$"#, options: .regularExpression) != nil
    }

    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Where the Bitwarden account lives.
public enum BitwardenServer: Equatable, Sendable, Hashable {
    /// bitwarden.com (US cloud, Bitwarden's default)
    case us
    /// bitwarden.eu
    case eu
    /// The user's own Bitwarden server (https address)
    case selfHosted(String)

    public static let euURL = "https://vault.bitwarden.eu"

    /// What `bw config server` takes.
    var configValue: String {
        switch self {
        case .us: return "bitwarden.com"
        case .eu: return Self.euURL
        case .selfHosted(let url): return url
        }
    }

    /// From `bw status` (nil: Bitwarden's US cloud).
    public init(serverURL: String?) {
        guard let url = serverURL?.trimmingCharacters(in: .whitespaces), !url.isEmpty,
              let host = URL(string: url)?.host?.lowercased() else { self = .us; return }
        switch host {
        case "bitwarden.com", "vault.bitwarden.com": self = .us
        case "bitwarden.eu", "vault.bitwarden.eu": self = .eu
        default: self = .selfHosted(url)
        }
    }

    /// A self-hosted server's address as the user typed it: https only, a host, nothing that could pose as an option.
    public static func selfHosted(address: String) -> BitwardenServer? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard text.range(of: #"^https://[^\s"'\\]+$"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let host = URL(string: text)?.host, isHost(host) || HostMatching.isIPAddress(host) else { return nil }
        // bitwarden.com or bitwarden.eu typed in by hand are those clouds.
        return BitwardenServer(serverURL: text)
    }

    private static func isHost(_ host: String) -> Bool {
        host.range(of: #"^[A-Za-z0-9]([A-Za-z0-9\-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9\-]*[A-Za-z0-9])?)*$"#,
                   options: .regularExpression) != nil
    }

    /// For the settings: "bitwarden.com", "bitwarden.eu" or the server's host.
    public var name: String {
        switch self {
        case .us: return "bitwarden.com"
        case .eu: return "bitwarden.eu"
        case .selfHosted(let url): return URL(string: url)?.host ?? url
        }
    }
}

public enum BitwardenError: LocalizedError, Equatable {
    case notRunnable(String)
    case timeout
    case locked
    case notLoggedIn
    case notFound
    case notALogin
    case wrongPassword
    case invalidEmail
    case cancelled
    /// Bitwarden's own message.
    case failed(String)
    case unexpected(String)

    init(message: String?) {
        let text = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch text {
        case "Vault is locked.": self = .locked
        case "You are not logged in.", "No active account found": self = .notLoggedIn
        case "Not found.": self = .notFound
        case "Not a login.": self = .notALogin
        case "Invalid master password.": self = .wrongPassword
        case "": self = .unexpected("no message")
        default: self = .failed(String(text.prefix(400)))
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notRunnable(let detail): return "Bitwarden's command line tool could not be started (\(detail))."
        case .timeout: return "Bitwarden's command line tool didn't answer in time."
        case .locked: return "Bitwarden is locked."
        case .notLoggedIn: return "Not signed in to Bitwarden."
        case .notFound: return "Bitwarden doesn't have this login (any more)."
        case .notALogin: return "This Bitwarden item isn't a login."
        case .wrongPassword: return "The master password isn't right."
        case .invalidEmail: return "That isn't an email address."
        case .cancelled: return "Cancelled."
        case .failed(let message): return message
        case .unexpected(let detail): return "Bitwarden's command line tool answered unexpectedly (\(detail))."
        }
    }
}
