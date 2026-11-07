import CryptoKit
import Foundation
import Testing
@testable import aOS

/// A companion transport in between: what a program standing in for `aos-companion` on the Mac could do to the lines.
final class InterceptingTransport: CompanionTransport, @unchecked Sendable {
    private let inner: CompanionTransport
    private let outgoing: @Sendable (Data) -> Data
    private let incomingLine: @Sendable (Data) -> Data
    private let lock = NSLock()
    private var seen: [Data] = []

    init(_ inner: CompanionTransport, outgoing: @escaping @Sendable (Data) -> Data = { $0 },
         incoming: @escaping @Sendable (Data) -> Data = { $0 }) {
        self.inner = inner
        self.outgoing = outgoing
        incomingLine = incoming
    }

    /// Everything the Mac answered, as it came.
    var answers: [String] { lock.withLock { seen.map { String(decoding: $0, as: UTF8.self) } } }

    func send(_ data: Data) async throws { try await inner.send(outgoing(data)) }

    func incoming() -> AsyncThrowingStream<Data, Error> {
        let source = inner.incoming()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in source {
                        self.lock.withLock { self.seen.append(chunk) }
                        continuation.yield(self.incomingLine(chunk))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func close() async { await inner.close() }

    /// A JSON line changed as an object (the mock writes one whole line per chunk).
    static func edit(_ line: Data, _ change: (inout [String: JSONValue]) -> Void) -> Data {
        guard var object = try? JSONDecoder().decode(JSONValue.self, from: line).object else { return line }
        change(&object)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(JSONValue.object(object))) ?? line) + Data([0x0A])
    }
}

/// The workspace's screen login comes sealed to a one-time key the request signs (Docs/COMPANION.md, "The
/// workspace's screen login").
struct SealedScreenLoginTests {
    /// The public key of the private key 01..20 (also the signing vector's key).
    static let phoneKey = "BFFcPW6545a5BNP+yn9U/c0MwemXvzddylFa0KbDtANfRTa+OlDzGPv5pUdZAqIhUCvvDVfgjFOyzApW8X2fk1Q="

    @Test func theMacsReferenceVectorOpens() throws {
        // Sealed on the Mac side (AOSKit `ScreenSealTests`, computed with Python's cryptography too) for the phone key
        // 01..20 by the Mac key 21..40, phone 4853150ceae1, nonce 00..0f, GCM nonce 00..0b
        let phone = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(1...32))
        #expect(phone.publicKey.x963Representation.base64EncodedString() == Self.phoneKey)
        let sealed = ScreenSeal.Sealed(
            key: try #require(Data(base64Encoded: "BB8UAUa/sbJR+E9N2+DUzc/Xev2YSpUg41eUAh+DErue7JlaCLH6dwTfPcwLUKlmUmP7dxH5X5+KRJxQluR8iSs=")),
            box: try #require(Data(base64Encoded: "AAECAwQFBgcICQoL+APgE8Y8TlMJetK2W7N66yDO8c6j1i8jHiJdq6KMhUBWtWhTFg==")))
        let plaintext = try ScreenSeal.open(sealed, with: phone, op: "companion.screen", phone: "4853150ceae1",
                                            nonce: "AAECAwQFBgcICQoLDA0ODw")
        #expect(String(decoding: plaintext, as: UTF8.self) == #"{"password":"geheim"}"#)
        // One bit off anywhere, or another request's nonce: it doesn't open
        var changed = sealed
        changed.box[changed.box.count - 1] ^= 0x01
        #expect(throws: ScreenSeal.Failure.broken) {
            try ScreenSeal.open(changed, with: phone, op: "companion.screen", phone: "4853150ceae1", nonce: "AAECAwQFBgcICQoLDA0ODw")
        }
        #expect(throws: ScreenSeal.Failure.broken) {
            try ScreenSeal.open(sealed, with: phone, op: "companion.screen", phone: "4853150ceae1", nonce: "BBECAwQFBgcICQoLDA0ODw")
        }
    }

    @Test func theReplyKeyIsSigned() throws {
        // The same digest the Mac's tests check (Python: sha256(b"reply:88:" + key + b"\n"))
        #expect(CompanionSignature.dataDigest(reply: Self.phoneKey)
                == "2c4f2b4babd1464127bd60006cf4448888d07a7b0aaff3dff22f2b97e76f0562")
        let fields = CompanionRequest.screen(target: .workspace, reply: Self.phoneKey).signatureFields(key: "k", ts: 1, nonce: "n")
        #expect(fields.data == "2c4f2b4babd1464127bd60006cf4448888d07a7b0aaff3dff22f2b97e76f0562")
        #expect(fields.target == "workspace")
        // The Mac's own screen signs what it always signed
        #expect(CompanionRequest.screen(target: .mac).signatureFields(key: "k", ts: 1, nonce: "n").data
                == CompanionSignature.dataDigest())
        let line = String(decoding: try CompanionRequest.screen(target: .workspace, reply: "K").line(id: 4), as: UTF8.self)
        #expect(line == "{\"id\":4,\"op\":\"screen\",\"reply\":\"K\",\"target\":\"workspace\"}\n")
    }

    private let login = ScreenEndpoint(host: "192.168.64.5", port: 5900, username: "aos", password: "geheim")

    private func signedMock() -> (MockCompanionServer, CompanionSigner) {
        let signer = CompanionSigner(phoneID: "4853150ceae1", key: CompanionKey.ephemeral())
        let server = MockCompanionServer(keepsSecrets: true)
        let login = self.login
        server.update {
            $0.trustedPhone = .init(phoneID: signer.phoneID, publicKey: signer.key.publicKey)
            $0.screens[.workspace] = login
        }
        return (server, signer)
    }

    @Test func roundTrip() async throws {
        let (server, signer) = signedMock()
        let transport = InterceptingTransport(server.makeTransport())
        let client = CompanionClient(transport: transport, signer: signer)
        await client.start()
        #expect(try await client.workspaceLogin() == login)
        // Out: a one-time key, signed. Back: only ciphertext.
        let sent = try #require(server.received.last)
        #expect(sent.op == "screen")
        #expect(sent.fields["target"] == .string("workspace"))
        #expect(sent.fields["reply"]?.string?.count == 88)
        let answer = try #require(transport.answers.last)
        #expect(answer.contains("\"sealed\""))
        #expect(!answer.contains("geheim") && !answer.contains("192.168.64.5") && !answer.contains("username"))
        // `screen(.workspace)` is the same, with a new key and a new box each time
        #expect(try await client.screen(.workspace) == login)
        let keys = server.received.filter { $0.op == "screen" }.compactMap { $0.fields["reply"]?.string }
        #expect(keys.count == 2 && Set(keys).count == 2)
        // The Mac's own screen stays as it was (no login, no key)
        #expect(try await client.screen(.mac) == ScreenEndpoint(host: "127.0.0.1", port: 5900))
        #expect(server.received.last?.fields["reply"] == nil)
    }

    @Test func aSwappedKeyFailsTheSignature() async throws {
        let (server, signer) = signedMock()
        // On the way to the Mac, the reply key is replaced with one the relay holds
        let theirs = P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString()
        let transport = InterceptingTransport(server.makeTransport(), outgoing: { line in
            InterceptingTransport.edit(line) { if $0["reply"] != nil { $0["reply"] = .string(theirs) } }
        })
        let client = CompanionClient(transport: transport, signer: signer)
        await client.start()
        await #expect(throws: CompanionError.self) { try await client.workspaceLogin() }
        #expect(transport.answers.last?.contains("\"code\":\"invalid\"") == true)
        #expect(transport.answers.allSatisfy { !$0.contains("sealed") })
    }

    @Test func aTamperedBoxDoesntOpen() async throws {
        let (server, signer) = signedMock()
        let transport = InterceptingTransport(server.makeTransport(), incoming: { line in
            InterceptingTransport.edit(line) { object in
                guard var sealed = object["sealed"]?.object,
                      var box = sealed["box"]?.string.flatMap({ Data(base64Encoded: $0) }) else { return }
                box[box.count - 1] ^= 0x01
                sealed["box"] = .string(box.base64EncodedString())
                object["sealed"] = .object(sealed)
            }
        })
        let client = CompanionClient(transport: transport, signer: signer)
        await client.start()
        await #expect(throws: CompanionError.invalidAnswer) { try await client.workspaceLogin() }
    }

    @Test func noPlaintextLoginIsTaken() async throws {
        // An answer with the login in plaintext (an older Mac, or someone answering in its place): refused
        let (server, signer) = signedMock()
        let transport = InterceptingTransport(server.makeTransport(), incoming: { line in
            InterceptingTransport.edit(line) { object in
                guard object["sealed"] != nil else { return }
                object["sealed"] = nil
                object["host"] = .string("192.168.64.5")
                object["port"] = .number(5900)
                object["username"] = .string("aos")
                object["password"] = .string("geheim")
            }
        })
        let client = CompanionClient(transport: transport, signer: signer)
        await client.start()
        await #expect(throws: CompanionError.updateMac) { try await client.workspaceLogin() }
        #expect(CompanionError.updateMac.errorDescription
                == String(localized: "Update aOS on the Mac to see the workspace from this iPhone."))
    }

    @Test func aReplayFails() throws {
        let (server, signer) = signedMock()
        let oneTime = P256.KeyAgreement.PrivateKey()
        let request = CompanionRequest.screen(target: .workspace, reply: oneTime.publicKey.x963Representation.base64EncodedString())
        let auth = try signer.auth(for: request)
        let line = try request.line(id: 1, auth: auth)
        let first = try #require(server.handle(line: line))
        #expect(String(decoding: first, as: UTF8.self).contains("\"sealed\""))
        // The same signed request again: refused
        let again = String(decoding: try #require(server.handle(line: line)), as: UTF8.self)
        #expect(again.contains("\"ok\":false") && again.contains("sent before"))
        // The first answer opens for its own request only
        guard case .response(let response) = try CompanionMessage.decode(line: first.dropLast()) else {
            Issue.record("not a response")
            return
        }
        #expect(try ScreenSeal.login(in: response, with: oneTime, op: "companion.screen", auth: auth) == login)
        let other = try signer.auth(for: request)
        #expect(throws: CompanionError.invalidAnswer) {
            try ScreenSeal.login(in: response, with: oneTime, op: "companion.screen", auth: other)
        }
        #expect(throws: CompanionError.invalidAnswer) {
            try ScreenSeal.login(in: response, with: P256.KeyAgreement.PrivateKey(), op: "companion.screen", auth: auth)
        }
    }
}
