import AOSTailnet
import Foundation
import Testing
@testable import aOS

/// aOS's real Tailscale node of this app (Tailnetkit) in a whole tailnet on this Mac: Tailscale's test coordination
/// server, DERP and a "Mac" node with aOS's node code (Tailnet/cmd/aos-tailnet-testnet). The simulator shares the
/// Mac's loopback. Runs with iOS/Tools/test-tailnet.sh, which starts the tailnet and passes its admin URL
/// (AOS_TAILNET_TESTNET); without it the suite is skipped.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AOS_TAILNET_TESTNET"] != nil))
struct TailnetEndToEndTests {
    let key = DeviceKey.ephemeral()
    var admin: URL { URL(string: ProcessInfo.processInfo.environment["AOS_TAILNET_TESTNET"] ?? "http://127.0.0.1:1")! }

    struct Info: Decodable {
        var control: String
        var mac: String
        var macName: String
    }

    func call(_ method: String, _ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: admin)!)
        request.httpMethod = method
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "\(method) \(path)")
        return data
    }

    @Test func signInDialTheMacAndOnlyItsSSH() async throws {
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop() } }
        _ = try await call("POST", "/forward?port=\(server.port)")
        let info = try JSONDecoder().decode(Info.self, from: try await call("GET", "/info"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tailnet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let node = try TailnetNodeBox(directory: directory.path, hostname: "aos-test-iphone", controlURL: info.control)
        defer { node.close() }
        try node.start()

        // Not signed in: it reports a sign-in page of the coordination server; completing it, the node runs.
        var status = try TailnetStatus(json: Data(node.statusJSON().utf8))
        var completed = false
        let deadline = Date().addingTimeInterval(60)
        while !(status.isRunning && status.device != nil) {
            #expect(Date() < deadline, "the node didn't run in time (\(status.backendState))")
            if Date() >= deadline { return }
            if status.needsLogin, let url = status.authURL, !completed {
                #expect(url.hasPrefix(info.control))
                _ = try await call("POST", "/complete?url=" + (url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url))
                completed = true
            }
            try await Task.sleep(for: .milliseconds(200))
            status = try TailnetStatus(json: Data(node.statusJSON().utf8))
        }
        #expect(completed, "it asked for a sign-in")
        #expect(status.device?.hostName == "aos-test-iphone")
        #expect(status.aosDevices.map(\.hostName).contains("aos-mac"))

        // SSH to the Mac node's port 22 through the node, with the host key pinned, and the companion over it.
        let connection = try await SSHConnection.connect(
            routes: [.tailnet(info.mac)], port: 22, login: SSHLogin(username: "max", key: key),
            hostKey: .fingerprint(server.hostKeyFingerprint),
            tailnet: { host, port, timeout in try node.dial(host: host, port: port, timeout: timeout) },
            perHostTimeout: 20)
        #expect(connection.route == .tailnet(info.mac))
        let signer = CompanionSigner(phoneID: key.phoneID, key: CompanionKey.ephemeral())
        server.companion.update { $0.trustedPhone = .init(phoneID: signer.phoneID, publicKey: signer.key.publicKey) }
        let channel = try await connection.exec(CompanionCommand.serve(path: TestSSHServer.companionPath))
        let client = CompanionClient(transport: channel, signer: signer)
        await client.start()
        #expect(try await client.hello(app: "0.1.0", device: "Test").mac == "Max’s MacBook Pro")
        await client.close()
        await connection.close()

        // By its MagicDNS name too.
        let byName = try await SSHConnection.connect(
            routes: [.tailnet(TailnetStatus.trimmed(info.macName))], port: 22, login: SSHLogin(username: "max", key: key),
            hostKey: .pinned(server.hostKeyLine),
            tailnet: { host, port, timeout in try node.dial(host: host, port: port, timeout: timeout) },
            perHostTimeout: 20)
        await byName.close()

        // The Mac node offers nothing else.
        for port in [80, 443, 5900, 8080] {
            #expect(throws: (any Error).self) { _ = try node.dial(host: info.mac, port: port, timeout: 5) }
        }
    }
}

extension TailnetStatus {
    /// A MagicDNS name without its final dot.
    static func trimmed(_ name: String) -> String { name.hasSuffix(".") ? String(name.dropLast()) : name }
}
