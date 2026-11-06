import Foundation
import SwiftUI
import Testing
import UIKit
@testable import aOS

/// Sign-ins with the person's Bitwarden logins (Docs/COMPANION.md): the Mac offers the logins that match the site,
/// by name and user name; the answer names the approved one. The iPhone never talks to Bitwarden.
struct BitwardenProtocolTests {
    private func text(_ request: CompanionRequest, id: Int) throws -> String {
        String(decoding: try request.line(id: id), as: UTF8.self)
    }

    @Test func theAnswerNamesTheLoginOnly() throws {
        #expect(try text(.signInLogin(request: "r1", host: "www.amazon.de", login: "2c1f3b9e-58a0-4b8e-9a4b-b0e1a2c3d4e5"), id: 9)
                == "{\"host\":\"www.amazon.de\",\"id\":9,\"login\":\"2c1f3b9e-58a0-4b8e-9a4b-b0e1a2c3d4e5\",\"op\":\"signin.answer\",\"request\":\"r1\"}\n")
    }

    @Test func signInEventsCarryLogins() throws {
        let line = #"{"event":"signin","request":"r7","agent":"Claude Code","host":"www.amazon.de","field":"password","purpose":"Rechnung","bitwarden":"unlocked","logins":[{"id":"a1","name":"Amazon","username":"max@marquart.dev","totp":false},{"id":"a2","name":"Amazon Business","username":"einkauf@marquart.dev","totp":true},{"name":"no id"}]}"#
        guard case .event(.signIn(let r)) = try CompanionMessage.decode(line: Data(line.utf8)) else {
            Issue.record("not a sign-in")
            return
        }
        #expect(r.bitwarden == .unlocked)
        #expect(r.logins == [BitwardenLogin(id: "a1", name: "Amazon", username: "max@marquart.dev", hasCode: false),
                             BitwardenLogin(id: "a2", name: "Amazon Business", username: "einkauf@marquart.dev", hasCode: true)])
        #expect(r.choices.map(\.id) == ["a1", "a2"])
        var code = r
        code.field = .code
        #expect(code.choices.map(\.id) == ["a2"])  // a code comes only from a login with an authenticator key
    }

    @Test func bitwardenStates() throws {
        func state(_ json: String) throws -> BitwardenState? {
            if case .event(.signIn(let r)) = try CompanionMessage.decode(line: Data(json.utf8)) { return r.bitwarden }
            return nil
        }
        #expect(try state(#"{"event":"signin","request":"r","host":"a.de","bitwarden":"locked"}"#) == .locked)
        #expect(try state(#"{"event":"signin","request":"r","host":"a.de","bitwarden":"unavailable"}"#) == .unavailable)
        // A Mac from before Bitwarden, or a state this app doesn't know: no Bitwarden, AutoFill only
        #expect(try state(#"{"event":"signin","request":"r","host":"a.de"}"#) == .off)
        #expect(try state(#"{"event":"signin","request":"r","host":"a.de","bitwarden":"sleeping"}"#) == .off)
    }

    @Test func theMockRoundTripsLogins() throws {
        let event = CompanionEvent.signIn(SignInRequest(
            id: "r", agent: "A", host: "github.com", purpose: "p", expires: nil, field: .code,
            logins: [BitwardenLogin(id: "g", name: "GitHub", username: "mr-mandelbrot", hasCode: true)], bitwarden: .unlocked))
        #expect(try CompanionMessage.decode(line: MockCompanionServer.line(for: event).dropLast()) == .event(event))
    }

    @Test func theClientSendsTheApprovedLogin() async throws {
        let server = MockCompanionServer(keepsSecrets: true)
        let client = CompanionClient(transport: server.makeTransport())
        await client.start()
        try await client.answerSignIn(request: "r1", host: "www.amazon.de", login: "a2")
        let received = try #require(server.received.last)
        #expect(received.op == "signin.answer")
        #expect(received.fields["login"] == .string("a2"))
        #expect(received.fields["password"] == nil && received.fields["username"] == nil && received.fields["totp"] == nil)
    }
}

@MainActor
struct SignInSheetTests {
    private func request(_ state: BitwardenState, logins: [BitwardenLogin] = [], field: SignInRequest.Field = .password)
        -> SignInRequest {
        SignInRequest(id: "s1", agent: "Claude Code", host: "www.amazon.de", purpose: "Rechnung",
                      expires: Date().addingTimeInterval(120), field: field, logins: logins, bitwarden: state)
    }

    private let amazon = BitwardenLogin(id: "a1", name: "Amazon", username: "max@marquart.dev", hasCode: false)

    @Test func whatTheSheetSaysAboutBitwarden() {
        #expect(SignInSheet.bitwardenNotice(for: request(.unlocked, logins: [amazon])) == nil)
        #expect(SignInSheet.bitwardenNotice(for: request(.unlocked)) == .noLogin)
        #expect(SignInSheet.bitwardenNotice(for: request(.unlocked, logins: [amazon], field: .code)) == .noLogin)
        #expect(SignInSheet.bitwardenNotice(for: request(.locked)) == .locked)
        #expect(SignInSheet.bitwardenNotice(for: request(.unavailable)) == .unavailable)
        #expect(SignInSheet.bitwardenNotice(for: request(.off)) == nil)
    }

    @Test func theSheetDrawsInEveryState() throws {
        let model = AppModel(isDemo: true)
        let cases = [request(.unlocked, logins: [amazon]), request(.unlocked), request(.locked), request(.off),
                     request(.unavailable),
                     request(.unlocked, logins: [BitwardenLogin(id: "g", name: "GitHub", username: "m", hasCode: true)],
                             field: .code)]
        for r in cases {
            let host = UIHostingController(rootView: SignInSheet(request: r).environment(model))
            host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            host.view.layoutIfNeeded()
            #expect(host.sizeThatFits(in: CGSize(width: 393, height: 852)).height > 100)
        }
    }

    @Test func approvingInTheDemoSendsTheLogin() async throws {
        // The demo's connection talks to the mock server; Face ID is skipped there.
        let model = AppModel(isDemo: true)
        let connection = try #require(model.connection)
        try await waitUntil { connection.companionState == .ready }
        try await connection.answerSignIn(request: "demo-1", host: "www.amazon.de", login: amazon.id)
    }
}
