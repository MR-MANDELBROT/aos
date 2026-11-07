import CryptoKit
import Foundation
import os

private let log = Logger(subsystem: "dev.marquart.aos.ios", category: "companion")

/// The byte pipe the companion API runs over: the exec channel of `aos-companion serve`, or memory in tests.
protocol CompanionTransport: Sendable {
    func send(_ data: Data) async throws
    /// What arrives, in chunks of any size. Called once.
    func incoming() -> AsyncThrowingStream<Data, Error>
    func close() async
}

extension SessionChannel: CompanionTransport {
    func send(_ data: Data) async throws { try await write(data) }
    func incoming() -> AsyncThrowingStream<Data, Error> { output }
}

enum CompanionError: LocalizedError, Equatable {
    case closed
    case timeout
    /// The Mac answered with `ok: false`.
    case refused(String)
    case invalidAnswer
    /// The Mac has no signing key for this iPhone (paired before requests were signed, or removed on the Mac).
    case pairAgain
    /// The request has a value that can't be signed (a line break where none may be).
    case unsignable
    /// The Mac answered the workspace's screen without sealing its login (aOS on the Mac is older).
    case updateMac

    var errorDescription: String? {
        switch self {
        case .closed: String(localized: "The connection to aOS on the Mac ended.")
        case .timeout: String(localized: "aOS on the Mac didn't answer in time.")
        case .refused(let message): message
        case .invalidAnswer: String(localized: "aOS on the Mac sent an answer this app doesn't understand.")
        case .pairAgain: String(localized: "Pair again to keep approving from this iPhone.")
        case .unsignable: String(localized: "This request couldn't be signed.")
        case .updateMac: String(localized: "Update aOS on the Mac to see the workspace from this iPhone.")
        }
    }
}

/// The iPhone's side of the companion API: requests with ids, answers matched to them, events as a stream. With a
/// signer every request carries this iPhone's signature (the Mac refuses requests without one).
actor CompanionClient {
    private let transport: CompanionTransport
    private let signer: CompanionSigner?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<CompanionResponse, Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var readTask: Task<Void, Never>?
    private var finished: Error?

    /// Events from the Mac (after `subscribe`). Ends when the connection ends.
    nonisolated let events: AsyncStream<CompanionEvent>
    private let eventSink: AsyncStream<CompanionEvent>.Continuation

    init(transport: CompanionTransport, signer: CompanionSigner? = nil) {
        self.transport = transport
        self.signer = signer
        (events, eventSink) = AsyncStream<CompanionEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Starts reading. Call once, before the first request.
    func start() {
        guard readTask == nil else { return }
        let stream = transport.incoming()
        readTask = Task { await self.read(stream) }
    }

    func close() async {
        readTask?.cancel()
        await transport.close()
        finish(CompanionError.closed)
    }

    var isClosed: Bool { finished != nil }

    // MARK: Requests

    func hello(app: String, device: String) async throws -> HelloResult {
        HelloResult(try await request(.hello(app: app, device: device)))
    }

    func status() async throws -> WorkspaceStatus {
        WorkspaceStatus(try await request(.status))
    }

    func subscribe() async throws {
        _ = try await request(.subscribe)
    }

    /// Where a screen is: the Mac's own (no login), or the workspace's with its login (`workspaceLogin`).
    func screen(_ target: ScreenTarget) async throws -> ScreenEndpoint {
        if target == .workspace { return try await workspaceLogin() }
        guard let endpoint = ScreenEndpoint(try await request(.screen(target: target))) else {
            throw CompanionError.invalidAnswer
        }
        return endpoint
    }

    /// The workspace's screen sharing login: address, port, account name and password. The Mac seals it to a P-256
    /// key made for this one request (kept here in memory only until the answer is open; the signature covers it), so
    /// `aos-companion`, and whatever stands in for it on the Mac, sees only ciphertext (`ScreenSeal`). An answer
    /// without a sealed login is refused (`CompanionError.updateMac`), never taken in plaintext; one that doesn't
    /// open is `CompanionError.invalidAnswer`.
    func workspaceLogin() async throws -> ScreenEndpoint {
        let oneTime = P256.KeyAgreement.PrivateKey()
        let request = CompanionRequest.screen(target: .workspace,
                                              reply: oneTime.publicKey.x963Representation.base64EncodedString())
        let (response, auth) = try await send(request)
        do {
            return try ScreenSeal.login(in: response, with: oneTime, op: request.signedOp, auth: auth)
        } catch {
            log.notice("Workspace screen login not taken: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Approves one of the request's Bitwarden logins: the Mac gets it from Bitwarden. `host` is the request's
    /// website (the signature names it; the Mac checks it is the one it asked about).
    func answerSignIn(request id: String, host: String, login: String) async throws {
        _ = try await request(.signInLogin(request: id, host: host, login: login))
    }

    /// Sends a sign-in from another password app. The values only pass through; nothing here keeps or logs them.
    func answerSignIn(request id: String, host: String, username: String, password: String, totp: String?) async throws {
        _ = try await request(.signInAnswer(request: id, host: host, username: username, password: password, totp: totp))
    }

    func declineSignIn(request id: String, host: String) async throws {
        _ = try await request(.signInDecline(request: id, host: host))
    }

    /// A one-time code for a request whose field is `code`.
    func answerSignInCode(request id: String, host: String, code: String) async throws {
        _ = try await request(.signInCode(request: id, host: host, totp: code))
    }

    func helpDone(request id: String) async throws {
        _ = try await request(.helpDone(request: id))
    }

    func answerApproval(request id: String, allowed: Bool) async throws {
        _ = try await request(.approvalAnswer(request: id, allowed: allowed))
    }

    /// Types text into the running workspace.
    func type(_ text: String) async throws {
        _ = try await request(.type(text: text), timeout: .seconds(60))
    }

    /// Asks for the workspace's display in a size ("WIDTHxHEIGHT@SCALE") or its own size back ("reset"); returns the
    /// size it got.
    func display(_ size: String) async throws -> (width: Int, height: Int) {
        let response = try await request(.display(target: .workspace, size: size), timeout: .seconds(10))
        return (response.body["width"]?.int ?? 0, response.body["height"]?.int ?? 0)
    }

    /// The Overview: the Mac's status, or an action. A refusal comes as `MacRefusal` with the Mac's code.
    func mac(_ action: MacAction, value: String? = nil) async throws -> MacActionResult {
        let response = try await request(.mac(action, value: value), refusalsThrow: false)
        guard response.ok else {
            if response.code == "pair-again" { throw CompanionError.pairAgain }
            throw MacRefusal(code: response.code, message: response.error ?? "")
        }
        return MacActionResult(response)
    }

    /// Sends a request and waits for the answer with its id. `refusalsThrow: false` returns an `ok: false` answer
    /// as it is.
    func request(_ request: CompanionRequest, timeout: Duration = .seconds(20),
                 refusalsThrow: Bool = true) async throws -> CompanionResponse {
        try await send(request, timeout: timeout, refusalsThrow: refusalsThrow).response
    }

    /// Sends a request, waits for its answer; also returns the signature it went with (the sealed screen login is
    /// bound to its nonce).
    private func send(_ request: CompanionRequest, timeout: Duration = .seconds(20), refusalsThrow: Bool = true)
        async throws -> (response: CompanionResponse, auth: CompanionAuth?) {
        if let finished { throw finished }
        let id = nextID
        nextID += 1
        let auth = try signer?.auth(for: request)
        let line = try request.line(id: id, auth: auth)
        let op = request.op
        let response: CompanionResponse = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await self.transport.send(line)
                } catch {
                    self.resolve(id, with: .failure(error))
                }
            }
            timers[id] = Task {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { self.resolve(id, with: .failure(CompanionError.timeout)) }
            }
        }
        guard response.ok else {
            log.notice("Companion \(op, privacy: .public) refused (\(response.code ?? "", privacy: .public)): \(response.error ?? "", privacy: .public)")
            if !refusalsThrow { return (response, auth) }
            if response.code == "pair-again" { throw CompanionError.pairAgain }
            throw CompanionError.refused(response.error ?? String(localized: "aOS on the Mac said no."))
        }
        return (response, auth)
    }

    // MARK: Reading

    private func read(_ stream: AsyncThrowingStream<Data, Error>) async {
        var splitter = LineSplitter()
        do {
            for try await chunk in stream {
                for line in try splitter.append(chunk) where !line.isEmpty {
                    do {
                        handle(try CompanionMessage.decode(line: line))
                    } catch {
                        // Not JSON (a login message of the shell, for example): skipped, never logged in full.
                        log.debug("Skipped a line that isn't a message (\(line.count) bytes)")
                    }
                }
            }
            finish(CompanionError.closed)
        } catch {
            finish(error)
        }
    }

    private func handle(_ message: CompanionMessage) {
        switch message {
        case .response(let response):
            resolve(response.id, with: .success(response))
        case .event(let event):
            eventSink.yield(event)
        case .ignored:
            break
        }
    }

    private func resolve(_ id: Int, with result: Result<CompanionResponse, Error>) {
        timers.removeValue(forKey: id)?.cancel()
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func finish(_ error: Error) {
        guard finished == nil else { return }
        finished = error
        let waiting = pending
        pending.removeAll()
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
        eventSink.finish()
    }
}
