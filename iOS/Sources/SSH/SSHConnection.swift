@preconcurrency import Citadel
import Foundation
import Network
import NIOCore
@preconcurrency import NIOSSH
import NIOTransportServices
import os

private let log = Logger(subsystem: "dev.marquart.aos.ios", category: "ssh")

/// How the server's host key is checked.
enum HostKeyPolicy: Sendable, Equatable {
    /// Pairing: the key must have this fingerprint (`SHA256:...` from the QR code).
    case fingerprint(String)
    /// A key pinned earlier (OpenSSH public key line).
    case pinned(String)
    /// Nothing known yet: the connection stops at the key and reports it, so the person can check and trust it.
    case askFirst
}

/// Who logs in and how. One method per connection (Citadel asks a custom login delegate once): this iPhone's key
/// when there is one and the server takes keys, otherwise the password.
struct SSHLogin: Sendable {
    var username: String
    var key: DeviceKey?
    var password: String?
}

enum SSHConnectError: LocalizedError, Equatable {
    /// The server presented another key than expected: a different computer, or the Mac's key changed.
    case hostKeyMismatch(host: String, presented: String)
    /// First connection to a host: the key needs the person's OK. `key` is the OpenSSH line, `fingerprint` its SHA-256.
    case unknownHostKey(host: String, key: String, fingerprint: String)
    case authenticationFailed(host: String)
    /// No address answered. Each entry: the address and what went wrong there.
    case unreachable([HostFailure])
    case localNetworkDenied

    struct HostFailure: Equatable, Sendable {
        var host: String
        var reason: String
    }

    var errorDescription: String? {
        switch self {
        case .hostKeyMismatch(let host, let presented):
            String(localized: "\(host) answered with a different SSH key (\(presented)). If the Mac was set up again, pair it again.")
        case .unknownHostKey(let host, _, let fingerprint):
            String(localized: "\(host) is new. Its key: \(fingerprint)")
        case .authenticationFailed(let host):
            String(localized: "\(host) didn't accept the login.")
        case .unreachable(let failures):
            failures.isEmpty ? String(localized: "No address to try.")
                : String(localized: "Not reachable: \(failures.map(\.host).joined(separator: ", "))")
        case .localNetworkDenied:
            String(localized: "aOS may not use the local network. Allow it in Settings > Privacy & Security > Local Network.")
        }
    }
}

/// One open SSH connection: Citadel and SwiftNIO SSH on a Network.framework TCP connection.
final class SSHConnection: @unchecked Sendable {
    let client: SSHClient
    /// The TCP channel that carries the SSH connection.
    let channel: Channel
    /// The address that answered.
    let host: String
    /// The host key the server presented (OpenSSH line) and its fingerprint.
    let hostKey: String
    let hostKeyFingerprint: String

    private init(client: SSHClient, channel: Channel, host: String, hostKey: String) {
        self.client = client
        self.channel = channel
        self.host = host
        self.hostKey = hostKey
        hostKeyFingerprint = SSHKeyFormat.fingerprint(openSSHKey: hostKey) ?? ""
    }

    var isActive: Bool { channel.isActive }

    /// Runs `handler` once when the connection closes (from either side).
    func onClose(_ handler: @escaping @Sendable () -> Void) {
        channel.closeFuture.whenComplete { _ in handler() }
    }

    func close() async {
        try? await channel.close().get()
    }

    // MARK: Connecting

    /// Connects to the first of `hosts` that answers and logs in. Hosts start one after the other, `stagger` apart,
    /// and run in parallel after that; the first complete login wins and the others are closed.
    static func connect(hosts: [String], port: Int, login: SSHLogin, hostKey policy: HostKeyPolicy,
                        perHostTimeout: TimeInterval = 8, stagger: TimeInterval = 0.4) async throws -> SSHConnection {
        guard !hosts.isEmpty else { throw SSHConnectError.unreachable([]) }
        let race = Race(count: hosts.count)
        let tasks = hosts.enumerated().map { index, host in
            Task {
                if index > 0 { try? await Task.sleep(for: .seconds(stagger * Double(index))) }
                if race.isDecided || Task.isCancelled { race.report(.failure(host, CancellationError())); return }
                do {
                    let connection = try await connectOne(host: host, port: port, login: login, policy: policy,
                                                          timeout: perHostTimeout)
                    if !race.report(.success(connection)) { await connection.close() }
                } catch {
                    race.report(.failure(host, error))
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await race.result()
        } onCancel: {
            tasks.forEach { $0.cancel() }
            race.cancel()
        }
    }

    private static func connectOne(host: String, port: Int, login: SSHLogin, policy: HostKeyPolicy,
                                   timeout: TimeInterval) async throws -> SSHConnection {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let channel = try await NIOTSConnectionBootstrap(group: NIOTSEventLoopGroup.singleton)
            .connectTimeout(.milliseconds(Int64(timeout * 1000)))
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
            .tcpOptions(tcp)
            .channelInitializer { channel in channel.pipeline.addHandler(HoldUntilSSHStarts()) }
            .connect(host: host, port: port).get()

        let check = HostKeyCheck(host: host, policy: policy)
        let auth = LoginDelegate(username: login.username, key: try login.key?.sshPrivateKey(),
                                 password: login.password, host: host)
        let settings = SSHClientSettings(host: host, port: port,
                                         authenticationMethod: { SSHAuthenticationMethod.custom(auth) },
                                         hostKeyValidator: .custom(check))
        do {
            // Citadel builds the pipeline synchronously: that has to happen on the channel's event loop.
            let client = try await withTaskExecutorPreference(EventLoopTaskExecutor(channel.eventLoop)) {
                try await SSHClient.connect(on: channel, settings: settings)
            }
            guard let presented = check.presentedKey else { throw SSHConnectError.hostKeyMismatch(host: host, presented: "?") }
            log.info("SSH connected to \(host, privacy: .public)")
            return SSHConnection(client: client, channel: channel, host: host, hostKey: presented)
        } catch {
            try? await channel.close().get()
            // The host key check and the login know best what went wrong; NIO's error may wrap theirs.
            if let rejection = check.rejection { throw rejection }
            if let citadel = error as? SSHClientError, case .allAuthenticationOptionsFailed = citadel {
                throw SSHConnectError.authenticationFailed(host: host)
            }
            if auth.gaveUp { throw SSHConnectError.authenticationFailed(host: host) }
            throw error
        }
    }

    // MARK: Channels

    /// A command in an exec channel with stdin and stdout as byte streams (8-bit clean, no terminal).
    func exec(_ command: String) async throws -> SessionChannel {
        try await SessionChannel.open(on: channel, mode: .exec(command))
    }

    /// An interactive login shell in a pseudo terminal.
    func shell(term: String = "xterm-256color", columns: Int, rows: Int) async throws -> SessionChannel {
        try await SessionChannel.open(on: channel, mode: .shell(term: term, columns: columns, rows: rows))
    }

    /// A TCP connection from the server to `targetHost:targetPort` (as `ssh -L` does). `handler` gets the bytes as
    /// `ByteBuffer`s and may write `ByteBuffer`s back.
    func directTCPIP(to targetHost: String, port targetPort: Int,
                     handler: @escaping @Sendable () -> any ChannelHandler) async throws -> Channel {
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        return try await client.createDirectTCPIPChannel(
            using: SSHChannelType.DirectTCPIP(targetHost: targetHost, targetPort: targetPort, originatorAddress: originator)
        ) { channel in
            // Citadel calls this on the channel's event loop.
            do {
                try channel.pipeline.syncOperations.addHandler(handler())
                return channel.eventLoop.makeSucceededVoidFuture()
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }
    }
}

// MARK: - Host key and login

/// Checks the server's host key against the policy and remembers what was presented.
private final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String
    let policy: HostKeyPolicy
    private let lock = NSLock()
    private var _presented: String?
    private var _rejection: SSHConnectError?

    init(host: String, policy: HostKeyPolicy) {
        self.host = host
        self.policy = policy
    }

    var presentedKey: String? { lock.withLock { _presented } }
    var rejection: SSHConnectError? { lock.withLock { _rejection } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        let fingerprint = SSHKeyFormat.fingerprint(openSSHKey: line) ?? ""
        var rejection: SSHConnectError?
        switch policy {
        case .fingerprint(let expected):
            if !SSHKeyFormat.fingerprintsEqual(fingerprint, expected) {
                rejection = .hostKeyMismatch(host: host, presented: fingerprint)
            }
        case .pinned(let pinned):
            let pinnedFingerprint = SSHKeyFormat.fingerprint(openSSHKey: pinned) ?? ""
            if !SSHKeyFormat.fingerprintsEqual(fingerprint, pinnedFingerprint) {
                rejection = .hostKeyMismatch(host: host, presented: fingerprint)
            }
        case .askFirst:
            rejection = .unknownHostKey(host: host, key: line, fingerprint: fingerprint)
        }
        lock.withLock {
            _presented = line
            _rejection = rejection
        }
        if let rejection {
            log.notice("Host key of \(self.host, privacy: .public) not accepted: \(fingerprint, privacy: .public)")
            validationCompletePromise.fail(rejection)
        } else {
            validationCompletePromise.succeed(())
        }
    }
}

/// Offers one login: this iPhone's key if the server takes keys, otherwise the password. A second call means the
/// server said no.
private final class LoginDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let key: NIOSSHPrivateKey?
    let password: String?
    let host: String
    private let lock = NSLock()
    private var offered = false
    private var _gaveUp = false

    init(username: String, key: NIOSSHPrivateKey?, password: String?, host: String) {
        self.username = username
        self.key = key
        self.password = password
        self.host = host
    }

    var gaveUp: Bool { lock.withLock { _gaveUp } }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        let offer: NIOSSHUserAuthenticationOffer.Offer? = lock.withLock {
            defer { offered = true }
            if !offered, let key, availableMethods.contains(.publicKey) {
                return .privateKey(.init(privateKey: key))
            }
            if !offered, let password, availableMethods.contains(.password) {
                return .password(.init(password: password))
            }
            _gaveUp = true
            return nil
        }
        if let offer {
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer))
        } else {
            nextChallengePromise.fail(SSHConnectError.authenticationFailed(host: host))
        }
    }
}

// MARK: - Racing hosts

/// The first successful attempt wins; when all fail, the most telling error is thrown.
private final class Race: @unchecked Sendable {
    enum Outcome { case success(SSHConnection), failure(String, Error) }

    private let lock = NSLock()
    private let count: Int
    private var failures: [(String, Error)] = []
    private var winner: SSHConnection?
    private var waiter: CheckedContinuation<SSHConnection, Error>?
    private var finished = false

    init(count: Int) { self.count = count }

    var isDecided: Bool { lock.withLock { finished } }

    /// Returns false when the race was decided already (the caller closes its connection).
    @discardableResult
    func report(_ outcome: Outcome) -> Bool {
        let (accepted, resume): (Bool, (() -> Void)?) = lock.withLock {
            switch outcome {
            case .success(let connection):
                guard !finished else { return (false, nil) }
                finished = true
                winner = connection
                let waiter = self.waiter
                self.waiter = nil
                return (true, waiter.map { w in { w.resume(returning: connection) } })
            case .failure(let host, let error):
                guard !finished else { return (false, nil) }
                failures.append((host, error))
                guard failures.count == count else { return (true, nil) }
                finished = true
                let error = Self.summarize(failures)
                let waiter = self.waiter
                self.waiter = nil
                return (true, waiter.map { w in { w.resume(throwing: error) } })
            }
        }
        resume?()
        return accepted
    }

    func cancel() {
        let waiter: CheckedContinuation<SSHConnection, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(throwing: CancellationError())
    }

    func result() async throws -> SSHConnection {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<SSHConnection, Error>? = lock.withLock {
                if let winner { return .success(winner) }
                if finished { return .failure(failures.isEmpty ? CancellationError() : Self.summarize(failures)) }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    /// Login and host key problems say more than "not reachable"; a denied local network says the most.
    private static func summarize(_ failures: [(String, Error)]) -> Error {
        let errors = failures.map(\.1)
        if errors.contains(where: { ($0 as? SSHConnectError) == .localNetworkDenied || isLocalNetworkDenial($0) }) {
            return SSHConnectError.localNetworkDenied
        }
        for case let error as SSHConnectError in errors {
            if case .authenticationFailed = error { return error }
        }
        for case let error as SSHConnectError in errors {
            if case .unknownHostKey = error { return error }
        }
        for case let error as SSHConnectError in errors {
            if case .hostKeyMismatch = error { return error }
        }
        return SSHConnectError.unreachable(failures.map { .init(host: $0.0, reason: describe($0.1)) })
    }

    private static func isLocalNetworkDenial(_ error: Error) -> Bool {
        // Network.framework reports a blocked local network as a policy denial (ENETDOWN is not enough to tell).
        if let nw = error as? NWError, case .posix(let code) = nw { return code == .EPERM }
        return false
    }

    static func describe(_ error: Error) -> String {
        if let nw = error as? NWError {
            switch nw {
            case .posix(let code): return String(describing: code)
            case .dns(let code): return "DNS \(code)"
            default: return nw.localizedDescription
            }
        }
        if let channelError = error as? ChannelError, case .connectTimeout = channelError { return "timeout" }
        return String(describing: error)
    }
}
