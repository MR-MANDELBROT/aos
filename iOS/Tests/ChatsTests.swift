import Foundation
import Testing
@testable import aOS

/// The chats on the Overview: the list read leniently, signed ops with the chat's id as the signed value, what is
/// offered when, the words, and the whole round against the mock Mac.
struct ChatsTests {
    static let id = "6f1d6a0e-2b7c-4d8a-9c3e-1a2b3c4d5e01"

    func list(_ json: String) throws -> ChatList {
        ChatList(try #require(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).object))
    }

    @Test func theListIsReadLeniently() throws {
        let chats = try list("""
        {"enabled":true,"automatic":true,"terminal":false,"hours":48,"max":6,"running":1,"restart":true,"somethingNew":1,
         "list":[{"id":"a","title":"Rechnungen","folder":"~/Documents/Finanzen","origin":"app","activity":"2026-11-09T10:00:00Z",
                  "pinned":true,"skipped":false,"state":"running","since":"2026-11-09T09:00:00Z"},
                 {"id":"b","title":"Website","folder":"~/Developer/site","origin":"terminal","pinned":false,"skipped":true,
                  "reason":"skipped"},
                 {"title":"no id"}, {"id":"c"}]}
        """)
        #expect(chats.enabled && chats.canRestart)
        #expect(chats.running == 1)
        #expect(chats.chats.map(\.id) == ["a", "b", "c"], "one without an id is left out")
        #expect(chats.chats[0].isRunning)
        #expect(chats.chats[0].activity != nil)
        #expect(chats.chats[0].folderName == "Finanzen")
        #expect(chats.chats[1].skipped && chats.chats[1].reason == "skipped")
        #expect(chats.chats[2].title == "Claude Code")
        // An empty answer: nothing breaks
        #expect(ChatList([:]).chats.isEmpty)
        #expect(!ChatList([:]).enabled)
        #expect(ChatList.Chat(id: "x", title: "x", folder: "~").folderName == "~")
    }

    @Test func whatTheOpsSign() throws {
        let pin = CompanionRequest.mac(.chatsPin, value: Self.id).signatureFields(key: "k", ts: 1, nonce: "n")
        #expect(pin.op == "companion.chats.pin")
        #expect(pin.data == CompanionSignature.dataDigest(text: Self.id), "the chat's id is signed")
        let line = try #require(try JSONDecoder().decode(JSONValue.self, from: CompanionRequest.mac(.chatsRestart, value: Self.id).line(id: 3)).object)
        #expect(line["op"] == .string("chats.restart"))
        #expect(line["text"] == .string(Self.id))
        #expect(CompanionRequest.mac(.chatsList, value: nil).signatureFields(key: "k", ts: 1, nonce: "n").op == "companion.chats.list")
        #expect(MacAction.chatsSkip.changesChat && !MacAction.chatsList.changesChat && !MacAction.sleep.changesChat)
    }

    @Test func theEventIsRead() throws {
        #expect(try CompanionMessage.decode(line: Data(#"{"event":"chats"}"#.utf8)) == .event(.chats))
        #expect(try CompanionMessage.decode(line: MockCompanionServer.line(for: .chats).dropLast()) == .event(.chats))
    }

    @Test func whatIsOffered() {
        let all = Set(MacAction.allCases.map(\.rawValue))
        let list = ChatList(canRestart: true)
        let running = ChatList.Chat(id: "a", title: "a", pinned: false, state: "running")
        #expect(ChatOffer.now(running, in: list, features: all) == ChatOffer(pin: true, stop: true, restart: true))
        var pinned = running
        pinned.pinned = true
        #expect(ChatOffer.now(pinned, in: list, features: all) == ChatOffer(unpin: true, stop: true, restart: true))
        // Not kept (older): pin to keep it, or never keep it
        let older = ChatList.Chat(id: "b", title: "b", reason: "inactive")
        #expect(ChatOffer.now(older, in: list, features: all) == ChatOffer(pin: true, stop: true))
        // Stopped: only keeping it again
        let stopped = ChatList.Chat(id: "c", title: "c", skipped: true, reason: "skipped")
        #expect(ChatOffer.now(stopped, in: list, features: all) == ChatOffer(keepAgain: true))
        // Archived in the Claude app: aOS leaves it alone, pinned or not
        let archived = ChatList.Chat(id: "d", title: "d", reason: "archived")
        #expect(ChatOffer.now(archived, in: list, features: all) == ChatOffer())
        // Open in the Claude app: nothing of aOS's runs, so no restart
        let elsewhere = ChatList.Chat(id: "e", title: "e", state: "openElsewhere", note: "app")
        #expect(!ChatOffer.now(elsewhere, in: list, features: all).restart)
        // A keeper that can't restart, a Mac that doesn't know the op
        #expect(!ChatOffer.now(running, in: ChatList(canRestart: false), features: all).restart)
        #expect(!ChatOffer.now(running, in: list, features: all.subtracting(["chats.restart"])).restart)
    }

    @Test func theShortList() {
        let chats = (0..<8).map { ChatList.Chat(id: "\($0)", title: "\($0)") }
        var list = ChatList(chats: chats)
        #expect(list.shortList().map(\.id) == ["0", "1", "2", "3", "4"])
        // Pinned and running ones always, the rest fills up to five
        list.chats[0].pinned = true
        list.chats[6].state = "running"
        #expect(list.shortList().map(\.id) == ["0", "1", "2", "3", "6"])
        for i in 0..<7 { list.chats[i].state = "running" }
        #expect(list.shortList().count == 7)
    }

    @Test func inWords() {
        let list = ChatList(hours: 48, max: 6)
        func state(_ state: String?, note: String? = nil, reason: String? = nil) -> String {
            ChatsText.state(ChatList.Chat(id: "x", title: "x", state: state, note: note, reason: reason), in: list)
        }
        #expect(state("running") == String(localized: "Reachable"))
        #expect(state("openElsewhere", note: "app") == String(localized: "Open in the Claude app"))
        #expect(state("needsAttention", note: "signIn") == String(localized: "Needs a sign-in on the Mac"))
        #expect(state("starting", note: "restarting") == String(localized: "Restarting"))
        #expect(state(nil, reason: "overLimit").contains("6"))
        #expect(state(nil, reason: "inactive").contains("48"))
        #expect(state(nil) == String(localized: "Starting soon"))
        // What a newer Mac says, as it says it
        #expect(ChatsText.state(ChatList.Chat(id: "x", title: "x", state: "hibernating", detail: "Sleeping a bit"), in: list)
                == "Sleeping a bit")
        #expect(ChatsText.summary(ChatList(enabled: false)) == String(localized: "Off on the Mac"))
        #expect(ChatsText.summary(ChatList(running: 1)) == String(localized: "1 is reachable in the Claude app"))
        #expect(MacRefusal(code: "not-kept", message: "x").text != "x")
        #expect(MacRefusal(code: "keeper-old", message: "x").text != "x")
    }

    @Test func theRoundWithTheMac() async throws {
        let signer = CompanionSigner(phoneID: "4853150ceae1", key: CompanionKey.ephemeral())
        let server = MockCompanionServer(keepsSecrets: true)
        let publicKey = signer.key.publicKey
        server.update { $0.trustedPhone = .init(phoneID: signer.phoneID, publicKey: publicKey) }
        let client = CompanionClient(transport: server.makeTransport(), signer: signer)
        await client.start()
        #expect(try await client.hello(app: "1", device: "d").features.contains("chats.list"))

        let first = try #require(try await client.mac(.chatsList).chats)
        #expect(first.chats.first?.pinned == true, "pinned first")
        let unpinned = first.chats.filter { !$0.pinned }.compactMap(\.activity)
        #expect(unpinned == unpinned.sorted(by: >), "then by last use")
        let older = try #require(first.chats.first { $0.reason == "inactive" })

        // Pin an older one: it is kept, and the answer carries the status too
        let pinned = try await client.mac(.chatsPin, value: older.id)
        #expect(server.received.last?.fields["text"] == .string(older.id))
        let now = try #require(pinned.chats?.chats.first { $0.id == older.id })
        #expect(now.pinned && now.state == "starting")
        #expect(pinned.status != nil)
        #expect(pinned.chats?.chats.prefix(2).allSatisfy(\.pinned) == true)

        // Stop it, keep it again
        let stopped = try #require(try await client.mac(.chatsSkip, value: older.id).chats?.chats.first { $0.id == older.id })
        #expect(stopped.skipped && stopped.state == nil && !stopped.pinned)
        let again = try #require(try await client.mac(.chatsUnskip, value: older.id).chats?.chats.first { $0.id == older.id })
        #expect(!again.skipped)

        // Restart one that runs; one that doesn't is refused with the Mac's reason
        let running = try #require(first.chats.first { $0.state == "running" })
        let restarted = try #require(try await client.mac(.chatsRestart, value: running.id).chats?.chats.first { $0.id == running.id })
        #expect(restarted.state == "starting" && restarted.note == "restarting")
        await #expect(throws: MacRefusal.self) { _ = try await client.mac(.chatsRestart, value: stopped.id) }
        server.update { $0.chatsRestart = false }
        do {
            _ = try await client.mac(.chatsRestart, value: running.id)
            Issue.record("an older keeper can't restart")
        } catch let refusal as MacRefusal {
            #expect(refusal.code == "keeper-old")
        }
        // Not a chat of this Mac
        await #expect(throws: MacRefusal.self) { _ = try await client.mac(.chatsPin, value: "nonsense") }

        // An older Mac: no chats
        server.update { $0.oldMac = true }
        let old = CompanionClient(transport: server.makeTransport(), signer: signer)
        await old.start()
        #expect(!(try await old.hello(app: "1", device: "d").features.contains("chats.list")))
    }
}
