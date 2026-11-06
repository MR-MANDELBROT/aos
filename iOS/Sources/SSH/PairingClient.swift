import Foundation
import Network
import os

private let log = Logger(subsystem: "dev.marquart.annex.ios", category: "pairing")

/// Talks to the Mac's pairing listener: one JSON line out, one JSON line back (Docs/COMPANION.md, "Pairing").
enum PairingClient {
    enum Failure: LocalizedError, Equatable {
        /// No host of the pairing code answered on the pairing port.
        case unreachable
        case localNetworkDenied
        /// The Mac closed the connection without answering (the code expired or was used).
        case noAnswer
        case invalidAnswer
        /// The Mac said no, with its reason.
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .unreachable:
                String(localized: "The Mac didn't answer. Check that the iPhone is on the same network as the Mac and that the pairing code is still shown.")
            case .localNetworkDenied:
                String(localized: "Annex may not use the local network. Allow it in Settings > Privacy & Security > Local Network, then try again.")
            case .noAnswer:
                String(localized: "The Mac ended the pairing. Show a new pairing code on the Mac and scan it again.")
            case .invalidAnswer:
                String(localized: "The Mac's answer wasn't understood. Update Annex on the Mac and on this iPhone.")
            case .refused(let reason):
                String(localized: "The Mac refused the pairing: \(reason)")
            }
        }
    }

    /// Sends `request` to the first host of `link` that answers, then returns the Mac's answer and that host.
    static func send(_ request: PairingRequest, link: PairingLink, timeout: TimeInterval = 8) async throws
        -> (response: PairingResponse, host: String) {
        let line = try request.line()
        let port = NWEndpoint.Port(rawValue: link.pairingPort)!
        // All addresses at once (a little apart), the first that opens wins. The Mac's listener takes one pairing
        // only, so the request goes out on that one connection; the others are cancelled before sending anything.
        let endpoints = link.hosts.map { NWEndpoint.hostPort(host: NWEndpoint.Host($0), port: port) }
        var outcome = await ConnectRace.first(of: endpoints, timeout: timeout)
        var host = outcome.index.map { link.hosts[$0] } ?? link.hosts[0]
        if outcome.connection == nil, !outcome.denied,
           let endpoint = await browse(name: link.macName, timeout: 3) {
            // The pairing listener is also advertised over Bonjour; the addresses in the code may have changed.
            outcome = await ConnectRace.first(of: [endpoint], timeout: timeout)
            host = link.hosts[0]
        }
        guard let connection = outcome.connection else {
            throw outcome.denied ? Failure.localNetworkDenied : Failure.unreachable
        }
        switch await exchange(line, on: connection, timeout: timeout) {
        case .answer(let data): return (try decode(data), host)
        case .closedWithoutAnswer: throw Failure.noAnswer
        case .localNetworkDenied: throw Failure.localNetworkDenied
        case .unreachable: throw Failure.unreachable
        }
    }

    private static func decode(_ data: Data) throws -> PairingResponse {
        guard let response = try? JSONDecoder().decode(PairingResponse.self, from: data) else { throw Failure.invalidAnswer }
        guard response.ok else { throw Failure.refused(response.error ?? String(localized: "no reason given")) }
        return response
    }

    private enum Exchange { case answer(Data), closedWithoutAnswer, unreachable, localNetworkDenied }

    /// Sends the line on an open connection and reads up to the first newline.
    private static func exchange(_ line: Data, on connection: NWConnection, timeout: TimeInterval) async -> Exchange {
        defer { connection.cancel() }
        let queue = connection.queue ?? DispatchQueue(label: "dev.marquart.annex.pairing")
        return await withCheckedContinuation { (continuation: CheckedContinuation<Exchange, Never>) in
            let once = Once()
            let finish: @Sendable (Exchange) -> Void = { result in once.run { continuation.resume(returning: result) } }
            let received = Accumulator()

            @Sendable func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data { received.append(data) }
                    if let lineEnd = received.data.firstIndex(of: 0x0A) {
                        finish(.answer(received.data.prefix(upTo: lineEnd)))
                    } else if isComplete || error != nil {
                        finish(received.data.isEmpty ? .closedWithoutAnswer : .answer(received.data))
                    } else if received.data.count > 64 * 1024 {
                        finish(.answer(received.data))
                    } else {
                        read()
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled: finish(.unreachable)
                default: break
                }
            }
            connection.send(content: line, completion: .contentProcessed { error in
                if error != nil { finish(.unreachable) } else { read() }
            })
            // The Mac answers right away; a listener that keeps quiet must not keep the person waiting.
            queue.asyncAfter(deadline: .now() + timeout + 2) { finish(.unreachable) }
        }
    }

    /// Looks for the Mac's pairing listener over Bonjour (`_annex-pair._tcp`), preferring one named like the Mac.
    private static func browse(name: String, timeout: TimeInterval) async -> NWEndpoint? {
        let browser = NWBrowser(for: .bonjour(type: "_annex-pair._tcp", domain: nil), using: NWParameters())
        let queue = DispatchQueue(label: "dev.marquart.annex.pairing.browse")
        defer { browser.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<NWEndpoint?, Never>) in
            let once = Once()
            let found = EndpointList()
            browser.browseResultsChangedHandler = { results, _ in
                for result in results { found.add(result.endpoint) }
                if let exact = found.named(name) { once.run { continuation.resume(returning: exact) } }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { once.run { continuation.resume(returning: nil) } }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.run { continuation.resume(returning: found.onlyOne) }
            }
        }
    }
}

/// Opens TCP connections to several endpoints, `stagger` apart, and keeps the first one that is ready; the others
/// are cancelled without having sent anything.
private final class ConnectRace: @unchecked Sendable {
    struct Outcome {
        var connection: NWConnection?
        var index: Int?
        /// Some endpoint was refused because Annex may not use the local network.
        var denied = false
    }

    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var failures = 0
    private var denied = false
    private var finished = false
    private var continuation: CheckedContinuation<Outcome, Never>?

    static func first(of endpoints: [NWEndpoint], timeout: TimeInterval, stagger: TimeInterval = 0.3) async -> Outcome {
        guard !endpoints.isEmpty else { return Outcome() }
        let race = ConnectRace()
        let queue = DispatchQueue(label: "dev.marquart.annex.pairing.connect")
        return await withCheckedContinuation { continuation in
            race.lock.withLock { race.continuation = continuation }
            for (index, endpoint) in endpoints.enumerated() {
                let tcp = NWProtocolTCP.Options()
                tcp.connectionTimeout = Int(timeout.rounded(.up))
                let connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
                race.lock.withLock { race.connections.append(connection) }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        race.won(connection, index: index)
                    case .waiting(let error), .failed(let error):
                        let isDenied = connection.currentPath?.unsatisfiedReason == .localNetworkDenied
                        log.info("Pairing host \(String(describing: endpoint), privacy: .public): \(error.localizedDescription, privacy: .public)")
                        race.lost(connection, denied: isDenied, total: endpoints.count)
                    default:
                        break
                    }
                }
                queue.asyncAfter(deadline: .now() + stagger * Double(index)) {
                    if race.isFinished { connection.cancel() } else { connection.start(queue: queue) }
                }
            }
            queue.asyncAfter(deadline: .now() + timeout + stagger * Double(endpoints.count)) { race.timeUp() }
        }
    }

    private var isFinished: Bool { lock.withLock { finished } }

    private func won(_ connection: NWConnection, index: Int) {
        let (continuation, losers): (CheckedContinuation<Outcome, Never>?, [NWConnection]) = lock.withLock {
            guard !finished else { return (nil, []) }
            finished = true
            defer { self.continuation = nil }
            return (self.continuation, connections.filter { $0 !== connection })
        }
        guard let continuation else { connection.cancel(); return }
        // From here on the winner's state changes belong to the exchange.
        connection.stateUpdateHandler = nil
        losers.forEach { $0.cancel() }
        continuation.resume(returning: Outcome(connection: connection, index: index, denied: false))
    }

    private func lost(_ connection: NWConnection, denied isDenied: Bool, total: Int) {
        connection.stateUpdateHandler = nil
        connection.cancel()
        let continuation: CheckedContinuation<Outcome, Never>? = lock.withLock {
            failures += 1
            denied = denied || isDenied
            guard !finished, failures == total else { return nil }
            finished = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: Outcome(denied: lock.withLock { denied }))
    }

    private func timeUp() {
        let (continuation, all): (CheckedContinuation<Outcome, Never>?, [NWConnection]) = lock.withLock {
            guard !finished else { return (nil, []) }
            finished = true
            defer { self.continuation = nil }
            return (self.continuation, connections)
        }
        all.forEach { $0.cancel() }
        continuation?.resume(returning: Outcome(denied: lock.withLock { denied }))
    }
}

private final class Accumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ data: Data) { lock.withLock { buffer.append(data) } }
    var data: Data { lock.withLock { buffer } }
}

private final class EndpointList: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [NWEndpoint] = []

    func add(_ endpoint: NWEndpoint) { lock.withLock { if !endpoints.contains(endpoint) { endpoints.append(endpoint) } } }

    func named(_ name: String) -> NWEndpoint? {
        lock.withLock {
            endpoints.first { endpoint in
                if case .service(let serviceName, _, _, _) = endpoint { return serviceName == name }
                return false
            }
        }
    }

    var onlyOne: NWEndpoint? { lock.withLock { endpoints.count == 1 ? endpoints[0] : nil } }
}
