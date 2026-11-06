import Foundation
import Testing
@testable import Annex

/// The Mac side's additions (Docs/COMPANION.md on main, e1d6a2e and later): sign-in fields, approvals, mac
/// availability, typing into the workspace.
struct ProtocolUpdateTests {
    private func text(_ request: CompanionRequest, id: Int) throws -> String {
        String(decoding: try request.line(id: id), as: UTF8.self)
    }

    @Test func newRequestLines() throws {
        #expect(try text(.signInCode(request: "r3", totp: "123456"), id: 1)
                == "{\"id\":1,\"op\":\"signin.answer\",\"request\":\"r3\",\"totp\":\"123456\"}\n")
        #expect(try text(.approvalAnswer(request: "a1", allowed: true), id: 2)
                == "{\"allowed\":true,\"id\":2,\"op\":\"approval.answer\",\"request\":\"a1\"}\n")
        #expect(try text(.approvalAnswer(request: "a1", allowed: false), id: 3)
                == "{\"allowed\":false,\"id\":3,\"op\":\"approval.answer\",\"request\":\"a1\"}\n")
        #expect(try text(.type(text: "Grüße 😀"), id: 4) == "{\"id\":4,\"op\":\"type\",\"text\":\"Grüße 😀\"}\n")
    }

    @Test func signInFields() throws {
        func field(_ json: String) throws -> SignInRequest.Field? {
            if case .event(.signIn(let r)) = try CompanionMessage.decode(line: Data(json.utf8)) { return r.field }
            return nil
        }
        #expect(try field(#"{"event":"signin","request":"r","host":"a.de","field":"code"}"#) == .code)
        #expect(try field(#"{"event":"signin","request":"r","host":"a.de","field":"username"}"#) == .username)
        #expect(try field(#"{"event":"signin","request":"r","host":"a.de","field":"password"}"#) == .password)
        // An older Mac without the field, or a field this app doesn't know: the password, as before
        #expect(try field(#"{"event":"signin","request":"r","host":"a.de"}"#) == .password)
        #expect(try field(#"{"event":"signin","request":"r","host":"a.de","field":"pin"}"#) == .password)
    }

    @Test func approvalsAndMacEvents() throws {
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"approval","request":"a1","agent":"Codex","purpose":"Rechnungen","minutes":15,"expires":"2026-11-06T12:30:00Z"}"#.utf8))
                == .event(.approval(ApprovalRequest(id: "a1", agent: "Codex", purpose: "Rechnungen", minutes: 15,
                                                    expires: Date(timeIntervalSince1970: 1_793_968_200)))))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"approval.closed","request":"a1","result":"allowed"}"#.utf8))
                == .event(.approvalClosed(request: "a1", result: .allowed)))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"approval.closed","request":"a1","result":"declined"}"#.utf8))
                == .event(.approvalClosed(request: "a1", result: .declined)))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"mac","state":"unavailable","detail":"Annex isn't running"}"#.utf8))
                == .event(.mac(state: "unavailable", detail: "Annex isn't running")))
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"approval","agent":"x"}"#.utf8)) == .ignored)  // no id
    }

    @Test func theMockRoundTripsTheNewEvents() throws {
        let events: [CompanionEvent] = [
            .signIn(SignInRequest(id: "r", agent: "A", host: "h.de", purpose: "p", expires: nil, field: .code)),
            .approval(ApprovalRequest(id: "a", agent: "A", purpose: "p", minutes: 30, expires: nil)),
            .approvalClosed(request: "a", result: .declined),
            .mac(state: "unavailable", detail: "d"),
        ]
        for event in events {
            #expect(try CompanionMessage.decode(line: MockCompanionServer.line(for: event).dropLast()) == .event(event))
        }
    }

    @Test func clientSendsCodesApprovalsAndText() async throws {
        let server = MockCompanionServer(keepsSecrets: true)
        let client = CompanionClient(transport: server.makeTransport())
        await client.start()
        try await client.answerSignInCode(request: "r3", code: "654321")
        try await client.answerApproval(request: "a1", allowed: true)
        try await client.type("Grüße")
        let received = server.received
        #expect(received.map(\.op) == ["signin.answer", "approval.answer", "type"])
        #expect(received[0].fields["totp"] == .string("654321"))
        #expect(received[0].fields["password"] == nil && received[0].fields["username"] == nil)
        #expect(received[1].fields["allowed"] == .bool(true))
        #expect(received[2].fields["text"] == .string("Grüße"))
    }
}

@MainActor
struct ApprovalQueueTests {
    @Test func approvalsQueueWithSignIns() async throws {
        let model = AppModel(isDemo: true)
        let signIn = SignInRequest(id: "s1", agent: "Claude Code", host: "a.de", purpose: "", expires: nil)
        let approval = ApprovalRequest(id: "a1", agent: "Codex", purpose: "Rechnungen", minutes: 15, expires: nil)
        model.handle(.signIn(signIn))
        model.handle(.approval(approval))
        #expect(model.presentedQuestion == .signIn(signIn))
        #expect(model.waitingCount == 2)
        // Answered elsewhere: the sign-in closes, the approval comes up next
        model.handle(.signInClosed(request: "s1", result: .declined))
        try await Task.sleep(for: .milliseconds(2300))
        #expect(model.presentedQuestion == .approval(approval))
        model.handle(.approvalClosed(request: "a1", result: .allowed))
        #expect(model.approvalResults["a1"] == .allowed)
        #expect(model.approvals.isEmpty)
        // After a new subscribe the Mac sends the open questions again: each is shown once
        let next = ApprovalRequest(id: "a2", agent: "Codex", purpose: "", minutes: nil, expires: nil)
        model.handle(.approval(next))
        model.handle(.approval(next))
        #expect(model.approvals == [next])
    }
}
