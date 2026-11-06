import Foundation
import Testing
@testable import aOS

struct CompanionClientTests {
    private func connected(_ server: MockCompanionServer = MockCompanionServer(keepsSecrets: true)) async -> (CompanionClient, MockCompanionServer) {
        let client = CompanionClient(transport: server.makeTransport())
        await client.start()
        return (client, server)
    }

    @Test func helloStatusSubscribe() async throws {
        let (client, server) = await connected()
        let hello = try await client.hello(app: "0.1.0", device: "Test iPhone")
        #expect(hello.mac == "Max’s MacBook Pro")
        #expect(hello.aos == "0.2.0")
        let status = try await client.status()
        #expect(status.state == .open)
        #expect(status.sessions.first?.title == "Claude Code")
        try await client.subscribe()
        #expect(server.isSubscribed)
        #expect(server.received.map(\.op) == ["hello", "status", "subscribe"])
        #expect(server.received[0].fields["device"] == .string("Test iPhone"))
    }

    @Test func requestsRunConcurrentlyAndMatchTheirIDs() async throws {
        let (client, server) = await connected()
        async let a = client.screen(.mac)
        async let b = client.screen(.workspace)
        async let c = client.status()
        let (mac, workspace, status) = try await (a, b, c)
        #expect(mac == ScreenEndpoint(host: "127.0.0.1", port: 5900))
        #expect(workspace.username == "aos")
        #expect(status.state == .open)
        let ids = server.received.compactMap { $0.fields["id"]?.int }
        #expect(Set(ids).count == 3)
    }

    @Test func eventsArriveAfterSubscribe() async throws {
        let (client, server) = await connected()
        server.emit(.workspace(.closing))  // before subscribe: the Mac sends nothing
        try await client.subscribe()
        let request = SignInRequest(id: "r1", agent: "Claude Code", host: "www.amazon.de", purpose: "Rechnung",
                                    expires: Date(timeIntervalSince1970: 1_800_000_000))
        server.emit(.signIn(request))
        server.emit(.help(HelpRequest(id: "h1", agent: "Codex", purpose: "Captcha",
                                      region: .init(x: 1, y: 2, width: 3, height: 4))))
        server.emit(.signInClosed(request: "r1", result: .filled))
        var iterator = client.events.makeAsyncIterator()
        #expect(await iterator.next() == .signIn(request))
        #expect(await iterator.next() == .help(HelpRequest(id: "h1", agent: "Codex", purpose: "Captcha",
                                                            region: .init(x: 1, y: 2, width: 3, height: 4))))
        #expect(await iterator.next() == .signInClosed(request: "r1", result: .filled))
    }

    @Test func signInAnswersAndDeclines() async throws {
        let (client, server) = await connected()
        try await client.answerSignIn(request: "r1", host: "a.de", username: "max", password: "geheim", totp: "123456")
        try await client.declineSignIn(request: "r2", host: "a.de")
        try await client.helpDone(request: "h1")
        let answers = server.received
        #expect(answers[0].fields["op"] == .string("signin.answer"))
        #expect(answers[0].fields["password"] == .string("geheim"))
        #expect(answers[0].fields["totp"] == .string("123456"))
        #expect(answers[1].fields["decline"] == .bool(true))
        #expect(answers[1].fields["password"] == nil)
        #expect(answers[2].fields["op"] == .string("help.done"))
    }

    @Test func theDemoServerNeverKeepsPasswords() async throws {
        let (client, server) = await connected(MockCompanionServer(keepsSecrets: false))
        try await client.answerSignIn(request: "r1", host: "a.de", username: "max", password: "geheim", totp: nil)
        #expect(server.received[0].fields["password"] == .string("•••"))
    }

    @Test func refusalsBecomeErrors() async throws {
        let server = MockCompanionServer()
        server.update { $0.refuse["screen"] = "Der Arbeitsplatz ist geschlossen." }
        let (client, _) = await connected(server)
        await #expect(throws: CompanionError.refused("Der Arbeitsplatz ist geschlossen.")) {
            try await client.screen(.workspace)
        }
    }

    @Test func aClosedConnectionFailsWaitingRequestsAndEndsEvents() async throws {
        let (client, server) = await connected()
        try await client.subscribe()
        server.disconnect()
        var iterator = client.events.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        await #expect(throws: CompanionError.closed) { try await client.status() }
    }

    @Test func requestsTimeOut() async throws {
        // A transport that swallows everything
        struct Silent: CompanionTransport {
            let stream = AsyncThrowingStream<Data, Error> { _ in }
            func send(_ data: Data) async throws {}
            func incoming() -> AsyncThrowingStream<Data, Error> { stream }
            func close() async {}
        }
        let client = CompanionClient(transport: Silent())
        await client.start()
        await #expect(throws: CompanionError.timeout) {
            try await client.request(.status, timeout: .milliseconds(200))
        }
    }

    @Test func linesThatArentJSONAreSkipped() async throws {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        struct Scripted: CompanionTransport {
            let stream: AsyncThrowingStream<Data, Error>
            let continuation: AsyncThrowingStream<Data, Error>.Continuation
            func send(_ data: Data) async throws {
                // answer id 1 after some shell noise, split across chunks
                continuation.yield(Data("Last login: today\n{\"id\":1,".utf8))
                continuation.yield(Data("\"ok\":true,\"mac\":\"M\",\"aos\":\"1\"}\n".utf8))
            }
            func incoming() -> AsyncThrowingStream<Data, Error> { stream }
            func close() async { continuation.finish() }
        }
        let client = CompanionClient(transport: Scripted(stream: stream, continuation: continuation))
        await client.start()
        #expect(try await client.hello(app: "1", device: "d").mac == "M")
    }
}
