import Foundation

/// The helper in the workspace (Resources/GuestHelper, installed at `GuestHelper.executable`): a small app in the
/// account's session with the Accessibility permission. It tells which field has the focus on which website and types
/// sign-ins into exactly that page. aOS talks to it as root over the maintenance key; the helper's own client mode
/// checks that the program answering on its socket is the installed helper, so nothing else in the workspace can pose
/// as it and receive a password.
public struct GuestHelper: Sendable {
    public static let bundle = "\(GuestKit.libexec)/AOSHelper.app"
    public static let executable = "\(bundle)/Contents/MacOS/AOSHelper"

    /// The focused field, as the helper sees it.
    public struct Focus: Codable, Sendable {
        public var ok: Bool
        /// "username", "password", "code" or "none"
        public var kind: String?
        public var host: String?
        public var app: String?
        public var error: String?
    }

    public struct Status: Codable, Sendable {
        public var ok: Bool
        public var trusted: Bool?
        public var version: String?
        public var error: String?
    }

    public struct FillResult: Codable, Sendable {
        public var ok: Bool
        public var filled: [String]?
        public var submitted: Bool?
        public var host: String?
        public var error: String?
    }

    let ssh: SSH

    public init(provisioner: Provisioner, host: String) {
        ssh = provisioner.maintenance(host: host)
    }

    /// One request to the helper: a JSON line in (on stdin, never in the command line), a JSON line out.
    func call<T: Decodable>(_ request: [String: Any], timeout: TimeInterval = 30) async throws -> T {
        let line = try JSONSerialization.data(withJSONObject: request) + Data([0x0A])
        let result = try await ssh.run("\(Self.executable) client", input: line, timeout: timeout, check: false,
                                       what: "workspace helper")
        let text = result.text.split(separator: "\n").last.map(String.init) ?? ""
        guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw GuestHelperError.unavailable(result.text.isEmpty ? "no answer (status \(result.status))"
                                                : String(result.text.prefix(300)))
        }
        return value
    }

    public func status() async throws -> Status { try await call(["op": "status"], timeout: 20) }
    public func focus() async throws -> Focus { try await call(["op": "focus"], timeout: 20) }

    /// Types the answer into the page (only if the focus is still on `host`) and submits it.
    public func fill(host: String, kind: String, username: String?, password: String?, code: String?) async throws
        -> FillResult {
        var request: [String: Any] = ["op": "fill", "host": host, "kind": kind]
        if let username { request["username"] = username }
        if let password { request["password"] = password }
        if let code { request["code"] = code }
        return try await call(request, timeout: 60)
    }
}

public enum GuestHelperError: LocalizedError {
    case unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let s): return "The workspace helper doesn't answer: \(s)"
        }
    }
}

/// The user's answer to a sign-in request.
public struct SignInAnswer: Sendable {
    public var username: String?
    public var password: String?
    public var code: String?
    public var declined: Bool
    /// Where the answer came from ("mac" or the phone's name), for the log.
    public var from: String

    public init(username: String?, password: String?, code: String?, declined: Bool, from: String) {
        self.username = username
        self.password = password
        self.code = code
        self.declined = declined
        self.from = from
    }
}

extension WorkspaceController {
    /// How long the user has to answer a sign-in request.
    static let signInTimeout: TimeInterval = 180

    /// sign_in: the agent is at a sign-in field; the user approves on the Mac or the iPhone, the helper fills it.
    /// The agent never sees what was typed.
    func signIn(_ request: AgentRequest) async throws -> AgentResponse {
        _ = try requireLease()
        guard let ip = try host.guestAddress() else { throw WorkspaceError.notOpen }
        let helper = GuestHelper(provisioner: provisioner, host: ip)
        let status = try await helper.status()
        guard status.trusted == true else { throw WorkspaceError.helperNotAllowed }
        let focus = try await helper.focus()
        guard focus.ok, let kind = focus.kind, kind != "none", let site = focus.host, !site.isEmpty else {
            throw WorkspaceError.noSignInField(focus.error)
        }
        let id = UUID().uuidString
        let agent = request.agent ?? "Your agent"
        let purpose = (request.purpose ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let expires = Date().addingTimeInterval(Self.signInTimeout)
        signingIn = true
        defer { signingIn = false }
        // The lease must not run out while the user decides.
        if let l = lease { lease = (max(l.until, Date().addingTimeInterval(10 * 60)), l.purpose) }
        log("sign-in: \(agent) asks for \(site) (\(kind))")
        companion.post(CompanionEvent(event: "signin", request: id, agent: agent, host: site, field: kind,
                                      purpose: purpose.isEmpty ? nil : purpose, expires: expires))
        let answer: SignInAnswer? = await withCheckedContinuation { cont in
            pendingSignIns[id] = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.signInTimeout * 1_000_000_000))
                self?.answerSignIn(id, nil)
            }
        }
        guard let answer else {
            companion.post(CompanionEvent(event: "signin.closed", request: id, result: "expired"))
            return AgentResponse(id: request.id, ok: false,
                                 text: "The user did not answer the sign-in request for \(site) within 3 minutes. Tell them in the chat.")
        }
        if answer.declined {
            companion.post(CompanionEvent(event: "signin.closed", request: id, result: "declined"))
            log("sign-in for \(site) declined (\(answer.from))")
            return AgentResponse(id: request.id, ok: false,
                                 text: "The user declined the sign-in for \(site). Don't try again unless they ask you to.")
        }
        do {
            let result = try await helper.fill(host: site, kind: kind, username: answer.username,
                                               password: answer.password, code: answer.code)
            guard result.ok else { throw GuestHelperError.unavailable(result.error ?? "the fields could not be filled") }
            companion.post(CompanionEvent(event: "signin.closed", request: id, result: "filled"))
            log("sign-in for \(site) filled (\((result.filled ?? []).joined(separator: ", ")), approved on \(answer.from))")
            let fields = (result.filled ?? []).map { $0 == "username" ? "user name" : $0 }
            let what = fields.isEmpty ? "The sign-in" : "The " + fields.joined(separator: " and ")
            let verb = fields.count > 1 ? "were" : "was"
            return AgentResponse(id: request.id, ok: true,
                                 text: "The user approved. \(what) for \(site) \(verb) filled\(result.submitted == true ? " and submitted" : ""). Take a screenshot to see the result; never ask for or type the password yourself.")
        } catch {
            companion.post(CompanionEvent(event: "signin.closed", request: id, result: "failed"))
            log("sign-in for \(site) failed: \(error.localizedDescription)")
            return AgentResponse(id: request.id, ok: false,
                                 text: "The sign-in for \(site) could not be filled: \(error.localizedDescription) Take a screenshot; if the page changed, click into the sign-in field and call sign_in again.")
        }
    }

    /// The user's answer (or nil when it expired). Whoever answers first wins: the Mac window or a phone.
    public func answerSignIn(_ id: String, _ answer: SignInAnswer?) {
        guard let cont = pendingSignIns.removeValue(forKey: id) else { return }
        cont.resume(returning: answer)
        onChange?()
    }

    /// The open sign-in requests (for the Mac window).
    public var openSignIns: [CompanionEvent] {
        companion.open.values.filter { $0.event == "signin" }.sorted { $0.seq < $1.seq }
    }

    // MARK: Companion

    func handleCompanion(_ r: AgentRequest) async -> AgentResponse {
        switch r.op {
        case "companion.hello":
            companion.seen(device: r.device)
            let info: [String: Any] = ["mac": Host.current().localizedName ?? "Mac",
                                       "aos": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"]
            return json(r.id, info)
        case "companion.status":
            companion.seen(device: r.device)
            var workspace: [String: Any] = ["state": host.isRunning ? (lease != nil ? "open" : "running") : "stopped"]
            if let lease {
                workspace["purpose"] = lease.purpose
                workspace["until"] = ISO8601DateFormatter().string(from: lease.until)
            }
            return json(r.id, ["workspace": workspace, "setupComplete": setupComplete])
        case "companion.events":
            companion.seen(device: r.device)
            let (events, seq) = await companion.events(since: r.since ?? 0, timeout: min(r.seconds ?? 25, 50))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let list = (try? JSONSerialization.jsonObject(with: encoder.encode(events))) ?? []
            return json(r.id, ["events": list, "seq": seq])
        case "companion.screen":
            if r.target == "workspace" {
                guard host.isRunning, let ip = try? host.guestAddress(), let password = try? guestPassword() else {
                    return .failure(r.id, "The workspace is not running.")
                }
                return json(r.id, ["host": ip, "port": 5900, "username": Brand.guestUser, "password": password])
            }
            return json(r.id, ["host": "127.0.0.1", "port": 5900])
        case "signin.answer":
            guard let id = r.request, pendingSignIns[id] != nil else {
                return .failure(r.id, "This sign-in request is no longer open.")
            }
            answerSignIn(id, SignInAnswer(username: r.username, password: r.password, code: r.totp,
                                          declined: r.decline ?? false, from: r.device ?? "iPhone"))
            return AgentResponse(id: r.id, ok: true, text: "ok")
        case "companion.type":
            // The user types into the workspace from the phone (umlauts and emoji go through the guest's clipboard,
            // as for the agent). Not while the agent signs in.
            guard host.isRunning, let ip = try? host.guestAddress() else { return .failure(r.id, "The workspace is not running.") }
            guard !signingIn else { return .failure(r.id, "A sign-in is in progress.") }
            let text = r.text ?? ""
            guard !text.isEmpty, text.count <= 4000 else { return .failure(r.id, "Nothing to type.") }
            do {
                let client = try await screenClient(ip: ip)
                try await typeRuns(text, client: client, privately: true)
                return AgentResponse(id: r.id, ok: true, text: "ok")
            } catch {
                return .failure(r.id, error.localizedDescription)
            }
        case "help.done", "approval.answer":
            if let error = onCompanionAnswer?(r) { return .failure(r.id, error) }
            return AgentResponse(id: r.id, ok: true, text: "ok")
        default:
            return .failure(r.id, "unknown companion operation \(r.op)")
        }
    }

    private func json(_ id: Int, _ object: [String: Any]) -> AgentResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return AgentResponse(id: id, ok: true, text: String(decoding: data, as: UTF8.self))
    }
}
