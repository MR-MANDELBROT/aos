import CryptoKit
import Foundation
import Testing
@testable import aOS

struct CompanionProtocolTests {
    private func text(_ request: CompanionRequest, id: Int) throws -> String {
        String(decoding: try request.line(id: id), as: UTF8.self)
    }

    @Test func requestLines() throws {
        #expect(try text(.hello(app: "0.1.0", device: "Max\u{2019}s iPhone"), id: 1)
                == "{\"app\":\"0.1.0\",\"device\":\"Max\u{2019}s iPhone\",\"id\":1,\"op\":\"hello\"}\n")
        #expect(try text(.status, id: 2) == "{\"id\":2,\"op\":\"status\"}\n")
        #expect(try text(.subscribe, id: 3) == "{\"id\":3,\"op\":\"subscribe\"}\n")
        #expect(try text(.screen(target: .workspace), id: 4) == "{\"id\":4,\"op\":\"screen\",\"target\":\"workspace\"}\n")
        #expect(try text(.signInAnswer(request: "r1", host: "github.com", username: "max", password: "p\"w/\n", totp: "123456"), id: 5)
                == "{\"host\":\"github.com\",\"id\":5,\"op\":\"signin.answer\",\"password\":\"p\\\"w/\\n\",\"request\":\"r1\",\"totp\":\"123456\",\"username\":\"max\"}\n")
        #expect(try text(.signInAnswer(request: "r1", host: "github.com", username: "max", password: "pw", totp: nil), id: 6)
                == "{\"host\":\"github.com\",\"id\":6,\"op\":\"signin.answer\",\"password\":\"pw\",\"request\":\"r1\",\"username\":\"max\"}\n")
        #expect(try text(.signInDecline(request: "r1", host: "github.com"), id: 7)
                == "{\"decline\":true,\"host\":\"github.com\",\"id\":7,\"op\":\"signin.answer\",\"request\":\"r1\"}\n")
        #expect(try text(.helpDone(request: "h1"), id: 8) == "{\"id\":8,\"op\":\"help.done\",\"request\":\"h1\"}\n")
    }

    @Test func everyRequestIsExactlyOneLine() throws {
        let line = try CompanionRequest.signInAnswer(request: "r", host: "h", username: "a\nb", password: "c\r\nd", totp: nil).line(id: 1)
        #expect(line.filter { $0 == 0x0A }.count == 1)
        #expect(line.last == 0x0A)
    }

    @Test func responses() throws {
        let hello = try CompanionMessage.decode(line: Data(#"{"id":1,"ok":true,"mac":"Max’s MacBook","aos":"0.2.0"}"#.utf8))
        guard case .response(let r) = hello else { Issue.record("not a response"); return }
        #expect(r.id == 1 && r.ok)
        #expect(HelloResult(r) == HelloResult(CompanionResponse(id: 1, ok: true, body: ["mac": .string("Max’s MacBook"), "aos": .string("0.2.0")])))
        #expect(HelloResult(r).mac == "Max’s MacBook")

        let status = try CompanionMessage.decode(line: Data(#"{"id":2,"ok":true,"workspace":{"state":"open","purpose":"Rechnung laden","until":"2026-11-06T12:30:00Z"},"sessions":[{"title":"Claude Code","state":"running"}]}"#.utf8))
        guard case .response(let s) = status else { Issue.record("not a response"); return }
        let ws = WorkspaceStatus(s)
        #expect(ws.state == .open)
        #expect(ws.purpose == "Rechnung laden")
        #expect(ws.until == Date(timeIntervalSince1970: 1_793_968_200))
        #expect(ws.sessions.map(\.title) == ["Claude Code"])

        let screen = try CompanionMessage.decode(line: Data(#"{"id":4,"ok":true,"host":"192.168.64.5","port":5900,"username":"aos","password":"secret"}"#.utf8))
        guard case .response(let sc) = screen else { Issue.record("not a response"); return }
        #expect(ScreenEndpoint(sc) == ScreenEndpoint(host: "192.168.64.5", port: 5900, username: "aos", password: "secret"))

        let failed = try CompanionMessage.decode(line: Data(#"{"id":9,"ok":false,"error":"no such request"}"#.utf8))
        #expect(failed == .response(CompanionResponse(id: 9, ok: false, error: "no such request",
                                                      body: ["id": .number(9), "ok": .bool(false), "error": .string("no such request")])))
    }

    @Test func events() throws {
        let signIn = try CompanionMessage.decode(line: Data(#"{"event":"signin","request":"r7","agent":"Claude Code","host":"www.amazon.de","purpose":"Rechnung herunterladen","expires":"2026-11-06T12:00:00.250Z"}"#.utf8))
        #expect(signIn == .event(.signIn(SignInRequest(id: "r7", agent: "Claude Code", host: "www.amazon.de",
                                                       purpose: "Rechnung herunterladen",
                                                       expires: Date(timeIntervalSince1970: 1_793_966_400.25)))))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"signin.closed","request":"r7","result":"filled"}"#.utf8))
                == .event(.signInClosed(request: "r7", result: .filled)))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"signin.closed","request":"r7","result":"exploded"}"#.utf8))
                == .event(.signInClosed(request: "r7", result: .unknown)))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"help","request":"h1","agent":"Codex","purpose":"Captcha","region":{"x":100,"y":200,"w":300,"h":150}}"#.utf8))
                == .event(.help(HelpRequest(id: "h1", agent: "Codex", purpose: "Captcha",
                                            region: .init(x: 100, y: 200, width: 300, height: 150)))))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"help","request":"h2","agent":"Codex","purpose":"x","region":{"x":0,"y":0,"w":0,"h":0}}"#.utf8))
                == .event(.help(HelpRequest(id: "h2", agent: "Codex", purpose: "x", region: nil))))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"help.closed","request":"h1"}"#.utf8)) == .event(.helpClosed(request: "h1")))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"workspace","state":"starting"}"#.utf8)) == .event(.workspace(.starting)))
    }

    @Test func unknownOrBrokenLines() throws {
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"future.thing","x":1}"#.utf8)) == .ignored)
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"signin","request":"r"}"#.utf8)) == .ignored)  // no host
        #expect(throws: CompanionMessage.DecodeError.notJSON) { try CompanionMessage.decode(line: Data("hello".utf8)) }
        #expect(throws: CompanionMessage.DecodeError.notAnObject) { try CompanionMessage.decode(line: Data("[1]".utf8)) }
    }

    @Test func lineSplitter() throws {
        var splitter = LineSplitter(limit: 16)
        #expect(try splitter.append(Data("{\"a\":".utf8)) == [])
        #expect(try splitter.append(Data("1}\r\n{\"b\":2}\n{".utf8)) == [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
        #expect(try splitter.append(Data("}\n".utf8)) == [Data("{}".utf8)])
        #expect(throws: LineSplitter.LineTooLong.self) { try splitter.append(Data(repeating: 0x41, count: 17)) }
    }
}

struct KeyInputTests {
    @Test func asciiTextWithShift() {
        let steps = KeyInput.steps(for: "Hi!\n")
        #expect(steps == [.keys([
            RemoteKeyStroke(0x48),  // H, shift
            RemoteKeyStroke(0x69),  // i
            RemoteKeyStroke(0x21),  // !, shift
            RemoteKeyStroke(0xff0d),  // return
        ])])
        guard case .keys(let strokes) = steps.first else { return }
        #expect(strokes.map(\.shift) == [true, false, true, false])
    }

    @Test func symbolsThatNeedShiftOnUS() {
        let shifted = "~!@#$%^&*()_+{}|:\"<>?ABCZ"
        let plain = "`1234567890-=[]\\;',./abcz "
        for c in shifted { #expect(RemoteKeyStroke(UInt32(c.asciiValue!)).shift, "\(c)") }
        for c in plain { #expect(!RemoteKeyStroke(UInt32(c.asciiValue!)).shift, "\(c)") }
    }

    @Test func charactersWithoutKeysymArePasted() {
        #expect(KeyInput.steps(for: "Grüße €") == [
            .keys([RemoteKeyStroke(0x47), RemoteKeyStroke(0x72)]),
            .paste("üß"),
            .keys([RemoteKeyStroke(0x65), RemoteKeyStroke(0x20)]),
            .paste("€"),
        ])
    }

    @Test func smartPunctuationFallsBackToASCII() {
        #expect(KeyInput.steps(for: "\u{201E}a\u{201C} \u{2013} it\u{2019}s") == KeyInput.steps(for: "\"a\" - it's"))
    }

    @Test func tabsAndLineBreaks() {
        #expect(KeyInput.steps(for: "\t\r") == [.keys([RemoteKeyStroke(0xff09), RemoteKeyStroke(0xff0d)])])
    }
}

/// Signed requests (Docs/COMPANION.md, "Signed requests"): the text the iPhone signs is the one the Mac rebuilds.
struct SignedRequestTests {
    /// The same reference vector as the Mac's tests (AOSKit CompanionSignatureTests.testReferenceVector).
    @Test func referenceVector() throws {
        let request = CompanionRequest.signInLogin(request: "r1", host: "github.com",
                                                   login: "2c1f3b9e-58a0-4b8e-9a4b-b0e1a2c3d4e5")
        let fields = request.signatureFields(key: "4853150ceae1", ts: 1_793_966_400, nonce: "AAECAwQFBgcICQoLDA0ODw")
        let message = try #require(CompanionSignature.message(fields))
        #expect(String(decoding: message, as: UTF8.self) == """
            aos-companion-v1
            op=signin.answer
            key=4853150ceae1
            ts=1793966400
            nonce=AAECAwQFBgcICQoLDA0ODw
            request=r1
            decision=login
            login=2c1f3b9e-58a0-4b8e-9a4b-b0e1a2c3d4e5
            host=github.com
            target=
            data=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """)
        // Signed once with the private key 01 02 ... 20 on the Mac side; valid here too
        let publicKey = try P256.Signing.PublicKey(x963Representation: try #require(Data(base64Encoded:
            "BFFcPW6545a5BNP+yn9U/c0MwemXvzddylFa0KbDtANfRTa+OlDzGPv5pUdZAqIhUCvvDVfgjFOyzApW8X2fk1Q=")))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(Data(base64Encoded:
            "GFcC/pLIqdTnqSkGq/dgSPzvKwrS+An71RilVLIyBblhUdc88QPnXNY4gvOfxo7ZfiDf4tRnBoFjdtXUhA3AWg==")))
        #expect(publicKey.isValidSignature(signature, for: message))
    }

    @Test func dataDigestsLikeTheMac() {
        #expect(CompanionSignature.dataDigest(username: "max", password: "geheim")
                == "7f8b51cc0836cd46dc9b0f4cf097aab22db8990f183b3d9b5a0ecf48ab1a6c1f")
        #expect(CompanionSignature.dataDigest(text: "Grüße 😀")
                == "5ea585c8aefd5374907cd0e73a2ce0bdf2218de624576cad57ae294e322d69f7")
    }

    @Test func whatEachRequestSigns() {
        func fields(_ r: CompanionRequest) -> CompanionSignature.Fields { r.signatureFields(key: "k", ts: 1, nonce: "n") }
        #expect(fields(.status).op == "companion.status")
        #expect(fields(.screen(target: .workspace)).target == "workspace")
        #expect(fields(.signInDecline(request: "r", host: "a.de")).decision == "decline")
        #expect(fields(.signInCode(request: "r", host: "a.de", totp: "123456")).data
                == CompanionSignature.dataDigest(totp: "123456"))
        // An empty code doesn't go out, so it isn't signed either
        #expect(fields(.signInAnswer(request: "r", host: "a.de", username: "u", password: "p", totp: "")).data
                == CompanionSignature.dataDigest(username: "u", password: "p"))
        #expect(fields(.approvalAnswer(request: "a", allowed: false)).decision == "deny")
        #expect(fields(.type(text: "x")).op == "companion.type")
    }

    @Test func signedLinesCheckOutTheWayTheMacReadsThem() throws {
        let signer = CompanionSigner(phoneID: "4853150ceae1", key: CompanionKey.ephemeral())
        let requests: [CompanionRequest] = [
            .hello(app: "1", device: "d"), .status, .subscribe, .screen(target: .mac), .screen(target: .workspace),
            .signInLogin(request: "r", host: "a.de", login: "l"),
            .signInAnswer(request: "r", host: "a.de", username: "max", password: "p\"w ü", totp: "123456"),
            .signInAnswer(request: "r", host: "a.de", username: "max", password: "pw", totp: ""),
            .signInDecline(request: "r", host: "a.de"), .signInCode(request: "r", host: "a.de", totp: "000111"),
            .helpDone(request: "h"), .approvalAnswer(request: "a", allowed: true), .type(text: "Grüße 😀"),
        ]
        let key = try P256.Signing.PublicKey(x963Representation: signer.key.publicKey)
        for request in requests {
            let line = try request.line(id: 1, auth: try signer.auth(for: request))
            let object = try #require(try JSONDecoder().decode(JSONValue.self, from: line).object)
            let auth = try #require(CompanionAuth(object["auth"]))
            #expect(auth.key == "4853150ceae1")
            let rebuilt = MockCompanionServer.signatureFields(op: request.op, object: object, auth: auth)
            let message = try #require(CompanionSignature.message(rebuilt))
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(Data(base64Encoded: auth.sig)))
            #expect(key.isValidSignature(signature, for: message), "\(request.op)")
        }
    }

    @Test func theMacRefusesWhatIsntSignedByItsPhone() async throws {
        let signer = CompanionSigner(phoneID: "4853150ceae1", key: CompanionKey.ephemeral())
        let server = MockCompanionServer(keepsSecrets: true)
        server.update { $0.trustedPhone = .init(phoneID: signer.phoneID, publicKey: signer.key.publicKey) }
        // Signed: fine
        let signed = CompanionClient(transport: server.makeTransport(), signer: signer)
        await signed.start()
        try await signed.subscribe()
        try await signed.answerSignIn(request: "r1", host: "a.de", login: "l1")
        #expect(server.isSubscribed)
        // Unsigned (an iPhone paired before signing keys) or another key: "Pair again"
        let unsigned = CompanionClient(transport: server.makeTransport())
        await unsigned.start()
        await #expect(throws: CompanionError.pairAgain) { try await unsigned.status() }
        let stranger = CompanionClient(transport: server.makeTransport(),
                                       signer: CompanionSigner(phoneID: "000000000000", key: CompanionKey.ephemeral()))
        await stranger.start()
        await #expect(throws: CompanionError.pairAgain) { try await stranger.helpDone(request: "h1") }
        #expect(CompanionError.pairAgain.errorDescription == String(localized: "Pair again to keep approving from this iPhone."))
        // The right id with a key the Mac doesn't have: refused, but not "pair again"
        let impostor = CompanionClient(transport: server.makeTransport(),
                                       signer: CompanionSigner(phoneID: signer.phoneID, key: CompanionKey.ephemeral()))
        await impostor.start()
        await #expect(throws: CompanionError.self) { try await impostor.answerApproval(request: "a1", allowed: true) }
    }

    @Test func aChangedLineIsRefused() throws {
        let signer = CompanionSigner(phoneID: "4853150ceae1", key: CompanionKey.ephemeral())
        let server = MockCompanionServer(keepsSecrets: true)
        server.update { $0.trustedPhone = .init(phoneID: signer.phoneID, publicKey: signer.key.publicKey) }
        let request = CompanionRequest.signInLogin(request: "r1", host: "a.de", login: "l1")
        let line = try request.line(id: 1, auth: try signer.auth(for: request))
        // On its way the login is swapped
        let changed = Data(String(decoding: line, as: UTF8.self).replacingOccurrences(of: "\"l1\"", with: "\"l2\"").utf8)
        let answer = try #require(server.handle(line: changed))
        #expect(String(decoding: answer, as: UTF8.self).contains("\"code\":\"invalid\""))
        // The original goes through once, not twice
        #expect(String(decoding: try #require(server.handle(line: line)), as: UTF8.self).contains("\"ok\":true"))
        #expect(String(decoding: try #require(server.handle(line: line)), as: UTF8.self).contains("\"ok\":false"))
    }

    @Test func theSubscriptionEndedEvent() throws {
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"subscription","state":"ended"}"#.utf8))
                == .event(.subscriptionEnded))
        #expect(try CompanionMessage.decode(line: MockCompanionServer.line(for: .subscriptionEnded).dropLast())
                == .event(.subscriptionEnded))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"subscription","state":"other"}"#.utf8)) == .ignored)
    }
}
