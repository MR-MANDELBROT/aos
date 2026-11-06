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
        var sawDenial = false
        for host in link.hosts {
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: link.pairingPort)!)
            switch await exchange(line, with: endpoint, timeout: timeout) {
            case .answer(let data):
                return (try decode(data), host)
            case .closedWithoutAnswer:
                throw Failure.noAnswer
            case .localNetworkDenied:
                sawDenial = true
            case .unreachable:
                continue
            }
        }
        if sawDenial { throw Failure.localNetworkDenied }
        // The pairing listener is also advertised over Bonjour; the addresses in the code may have changed.
        if let endpoint = await browse(name: link.macName, timeout: 3) {
            switch await exchange(line, with: endpoint, timeout: timeout) {
            case .answer(let data): return (try decode(data), link.hosts[0])
            case .closedWithoutAnswer: throw Failure.noAnswer
            case .localNetworkDenied: throw Failure.localNetworkDenied
            case .unreachable: break
            }
        }
        throw Failure.unreachable
    }

    private static func decode(_ data: Data) throws -> PairingResponse {
        guard let response = try? JSONDecoder().decode(PairingResponse.self, from: data) else { throw Failure.invalidAnswer }
        guard response.ok else { throw Failure.refused(response.error ?? String(localized: "no reason given")) }
        return response
    }

    private enum Exchange { case answer(Data), closedWithoutAnswer, unreachable, localNetworkDenied }

    /// Connects, sends the line, reads up to the first newline.
    private static func exchange(_ line: Data, with endpoint: NWEndpoint, timeout: TimeInterval) async -> Exchange {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout.rounded(.up))
        let connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        let queue = DispatchQueue(label: "dev.marquart.annex.pairing")
        defer { connection.cancel() }

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
                case .ready:
                    connection.send(content: line, completion: .contentProcessed { error in
                        if error != nil { finish(.unreachable) } else { read() }
                    })
                case .waiting(let error), .failed(let error):
                    if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        finish(.localNetworkDenied)
                    } else {
                        log.info("Pairing host \(String(describing: endpoint), privacy: .public): \(error.localizedDescription, privacy: .public)")
                        finish(.unreachable)
                    }
                case .cancelled:
                    finish(.unreachable)
                default:
                    break
                }
            }
            connection.start(queue: queue)
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
