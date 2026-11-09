import Foundation
import Testing
@testable import aOS

/// The chats on their page: the list read leniently, signed ops with the chat's id as the signed value, what is offered
/// when (and what an older Mac gets instead), the words, and the whole round against the mock Mac.
struct ChatsTests {
    typealias Chat = ChatList.Chat
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
        #expect(chats.chats.map(\.id) == ["a", "b", "c"], "one without an id is left out, the order is the Mac's")
        #expect(chats.chats[0].isRunning && chats.chats[0].isReachable)
        #expect(chats.chats[0].activity != nil)
        #expect(chats.chats[0].folderName == "Finanzen")
        #expect(chats.chats[1].skipped && chats.chats[1].reason == "skipped")
        #expect(chats.chats[2].title == "Claude Code")
        #expect(chats.reachable == 1)
        // An empty answer: nothing breaks
        #expect(ChatList([:]).chats.isEmpty)
        #expect(!ChatList([:]).enabled)
        #expect(Chat(id: "x", title: "x", folder: "~").folderName == "~")
    }

    @Test func reachableKeptAndIdle() {
        // Reachable: running, starting, open elsewhere
        for state in ["running", "starting", "openElsewhere"] {
            #expect(Chat(id: "x", title: "x", state: state).isReachable, "\(state)")
        }
        for state in ["waitingForNetwork", "needsAttention", "failed", "folderMissing"] {
            #expect(!Chat(id: "x", title: "x", state: state).isReachable, "\(state)")
        }
        #expect(ChatList(chats: [Chat(id: "a", title: "a", state: "running"), Chat(id: "b", title: "b", state: "openElsewhere"),
                                 Chat(id: "c", title: "c", state: "starting"), Chat(id: "d", title: "d", reason: "inactive")])
                    .reachable == 3)
        // Kept: the keeper has it, it's pinned, or the rules keep it (no reason)
        #expect(Chat(id: "x", title: "x").isKept)
        #expect(Chat(id: "x", title: "x", pinned: true, reason: "overLimit").isKept)
        #expect(!Chat(id: "x", title: "x", reason: "inactive").isKept)
        #expect(!Chat(id: "x", title: "x", skipped: true, reason: "skipped").isKept)
        // Idle: nothing runs it (a state the phone doesn't know might)
        #expect(Chat(id: "x", title: "x", reason: "inactive").isIdle)
        #expect(Chat(id: "x", title: "x", state: "failed").isIdle)
        #expect(!Chat(id: "x", title: "x", state: "needsAttention").isIdle)
        #expect(!Chat(id: "x", title: "x", state: "openElsewhere").isIdle)
        #expect(!Chat(id: "x", title: "x", state: "hibernating").isIdle)
    }

    @Test func whatTheOpsSign() throws {
        for action in [MacAction.chatsStart, .chatsStop, .chatsDelete, .chatsPin] {
            let fields = CompanionRequest.mac(action, value: Self.id).signatureFields(key: "k", ts: 1, nonce: "n")
            #expect(fields.op == "companion." + action.rawValue)
            #expect(fields.data == CompanionSignature.dataDigest(text: Self.id), "the chat's id is signed")
            #expect(action.changesChat)
        }
        #expect(MacAction.chatsStart.rawValue == "chats.start")
        #expect(MacAction.chatsStop.rawValue == "chats.stop")
        #expect(MacAction.chatsDelete.rawValue == "chats.delete")
        let line = try #require(try JSONDecoder().decode(JSONValue.self, from: CompanionRequest.mac(.chatsDelete, value: Self.id).line(id: 3)).object)
        #expect(line["op"] == .string("chats.delete"))
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
        func offer(_ chat: Chat, in list: ChatList = ChatList(canRestart: true), features: Set<String>? = nil) -> ChatOffer {
            ChatOffer.now(chat, in: list, features: features ?? all)
        }
        // Running: Stop and Restart; no Start (it's reachable), no Delete (it runs)
        let running = Chat(id: "a", title: "a", pinned: true, state: "running")
        #expect(offer(running) == ChatOffer(stop: .chatsStop, restart: true))
        // Open in the Claude app: reachable, nothing of aOS's runs (no Restart), still open (no Delete)
        let elsewhere = Chat(id: "e", title: "e", state: "openElsewhere", note: "app")
        #expect(offer(elsewhere) == ChatOffer(stop: .chatsStop))
        // Not kept (older): Start or Delete, nothing to stop
        let older = Chat(id: "b", title: "b", reason: "inactive")
        #expect(offer(older) == ChatOffer(start: .chatsStart, delete: true))
        // Stopped: Start again, or Delete
        let stopped = Chat(id: "c", title: "c", skipped: true, reason: "skipped")
        #expect(offer(stopped) == ChatOffer(start: .chatsStart, delete: true))
        // Kept by the rules, the keeper hasn't started it yet: Start now, Stop, Delete
        let soon = Chat(id: "f", title: "f")
        #expect(offer(soon) == ChatOffer(start: .chatsStart, stop: .chatsStop, delete: true))
        // Failed: Restart instead of Start; nothing runs, so Delete
        let failed = Chat(id: "g", title: "g", pinned: true, state: "failed")
        #expect(offer(failed) == ChatOffer(stop: .chatsStop, restart: true, delete: true))
        // Needs a sign-in: its copy runs on the Mac
        let attention = Chat(id: "h", title: "h", state: "needsAttention", note: "signIn")
        #expect(offer(attention) == ChatOffer(stop: .chatsStop, restart: true))
        // Its folder is gone: nothing to start
        #expect(offer(Chat(id: "m", title: "m", state: "folderMissing")) == ChatOffer(stop: .chatsStop, delete: true))
        // Archived in the Claude app: aOS leaves it alone, only Delete
        #expect(offer(Chat(id: "d", title: "d", reason: "archived")) == ChatOffer(delete: true))
        // aOS's own session: never deleted from here
        #expect(offer(Chat(id: "o", title: "o", reason: "ownSession")).isEmpty)
        // A state the phone doesn't know counts as running
        #expect(!offer(Chat(id: "x", title: "x", state: "hibernating")).delete)
        // Keeping off on the Mac: nothing to start
        #expect(offer(older, in: ChatList(enabled: false)).start == nil)
        // A keeper that can't restart: the failed one gets Start instead
        #expect(!offer(running, in: ChatList(canRestart: false)).restart)
        #expect(offer(failed, in: ChatList(canRestart: false)).start == .chatsStart)
        #expect(!offer(running, features: all.subtracting(["chats.restart"])).restart)
        // A Mac from before chats.start, chats.stop and chats.delete: Start pins, Stop skips, no Delete
        let olderMac = all.subtracting(["chats.start", "chats.stop", "chats.delete"])
        #expect(offer(stopped, features: olderMac) == ChatOffer(start: .chatsPin))
        #expect(offer(running, features: olderMac) == ChatOffer(stop: .chatsSkip, restart: true))
        #expect(offer(soon, features: olderMac) == ChatOffer(start: .chatsPin, stop: .chatsSkip))
        // A Mac without the ops at all: nothing
        #expect(offer(soon, features: ["chats.list"]).isEmpty)
    }

    @Test func whatAsksFirst() {
        let chat = Chat(id: "a", title: "Rechnungen")
        #expect(ChatQuestion(.start(.chatsStart), chat: chat) == nil, "Start doesn't ask")
        #expect(ChatQuestion(.stop(.chatsSkip), chat: chat)?.action == .chatsSkip)
        #expect(ChatQuestion(.restart, chat: chat)?.action == .chatsRestart)
        let delete = ChatQuestion(.delete, chat: chat)
        #expect(delete?.action == .chatsDelete)
        #expect(delete?.title.contains("Rechnungen") == true)
        #expect(delete?.message == ChatsText.deleteMessage)
    }

    @Test func inWords() {
        let list = ChatList(hours: 48, max: 6)
        func state(_ state: String?, note: String? = nil, reason: String? = nil) -> String {
            ChatsText.state(Chat(id: "x", title: "x", state: state, note: note, reason: reason), in: list)
        }
        #expect(state("running") == String(localized: "Reachable"))
        #expect(state("openElsewhere", note: "app") == String(localized: "Open in the Claude app"))
        #expect(state("needsAttention", note: "signIn") == String(localized: "Needs a sign-in on the Mac"))
        #expect(state("starting", note: "restarting") == String(localized: "Restarting"))
        #expect(state(nil, reason: "overLimit").contains("6"))
        #expect(state(nil, reason: "inactive").contains("48"))
        #expect(state(nil) == String(localized: "Starting soon"))
        // What a newer Mac says, as it says it
        #expect(ChatsText.state(Chat(id: "x", title: "x", state: "hibernating", detail: "Sleeping a bit"), in: list)
                == "Sleeping a bit")
        // The count above the list: running, starting and open elsewhere
        let two = ChatList(chats: [Chat(id: "a", title: "a", state: "running"),
                                   Chat(id: "b", title: "b", state: "openElsewhere"),
                                   Chat(id: "c", title: "c", reason: "inactive")])
        #expect(ChatsText.summary(ChatList(enabled: false)) == String(localized: "Off on the Mac"))
        #expect(ChatsText.summary(two) == String(localized: "\(2) are reachable in the Claude app"))
        #expect(ChatsText.summary(ChatList(running: 1)) == String(localized: "None is reachable in the Claude app right now"),
                "the list counts, not the keeper's number")
        #expect(MacRefusal(code: "not-kept", message: "x").text != "x")
        #expect(MacRefusal(code: "keeper-old", message: "x").text != "x")
        #expect(MacRefusal(code: "chat-running", message: "x").text == String(localized: "Stop it first, or close it in the Claude app."))
        #expect(MacRefusal(code: "not-found", message: "x").text != "x")
    }

    @Test func theOverviewRow() {
        let two = ChatList(chats: [Chat(id: "a", title: "a", state: "running"),
                                   Chat(id: "b", title: "b", state: "starting")])
        let on = MacStatus.NewChats(enabled: true, state: "running")
        #expect(ChatsText.overview(two, newChats: on, kept: 5)
                == String(localized: "\(2) reachable in the Claude app") + "\n"
                    + String(localized: "New chats from the Claude app are on"), "the list's count wins over the status's")
        #expect(ChatsText.overview(nil, newChats: nil, kept: 1) == String(localized: "1 reachable in the Claude app"))
        #expect(ChatsText.overview(ChatList(), newChats: .init(enabled: false), kept: nil)
                == String(localized: "None reachable in the Claude app right now") + "\n"
                    + String(localized: "New chats from the Claude app are off"))
        #expect(ChatsText.overview(ChatList(enabled: false), newChats: nil, kept: nil)
                == String(localized: "Keeping chats reachable is off on the Mac"))
        #expect(ChatsText.newChatsShort(.init(enabled: true, state: "needsLogin"))
                == String(localized: "New chats need a sign-in to Claude Code on the Mac"))
        // The sign-in help under the row still comes for new chats that need it
        #expect(AOSCard.needsSignIn(MacStatus(newChats: .init(enabled: true, state: "needsLogin"))))
    }

    @Test func theMacsOrder() {
        let now = Date()
        let chats = MockCompanionServer.ordered([
            Chat(id: "old", title: "", activity: now.addingTimeInterval(-900), reason: "inactive"),
            Chat(id: "pinned", title: "", activity: now.addingTimeInterval(-3600), pinned: true, state: "failed"),
            Chat(id: "new", title: "", activity: now.addingTimeInterval(-60), reason: "overLimit"),
            Chat(id: "elsewhere", title: "", activity: now.addingTimeInterval(-7200), state: "openElsewhere"),
            Chat(id: "running", title: "", activity: now.addingTimeInterval(-300), state: "running"),
        ])
        #expect(chats.map(\.id) == ["running", "elsewhere", "pinned", "new", "old"],
                "reachable first, then pinned, then by the person's last activity")
    }

    @Test func theRoundWithTheMac() async throws {
        let signer = CompanionSigner(phoneID: "4853150ceae1", key: CompanionKey.ephemeral())
        let server = MockCompanionServer(keepsSecrets: true)
        let publicKey = signer.key.publicKey
        server.update { $0.trustedPhone = .init(phoneID: signer.phoneID, publicKey: publicKey) }
        let client = CompanionClient(transport: server.makeTransport(), signer: signer)
        await client.start()
        let features = try await client.hello(app: "1", device: "d").features
        #expect(features.isSuperset(of: ["chats.list", "chats.start", "chats.stop", "chats.delete"]))

        let first = try #require(try await client.mac(.chatsList).chats)
        let reachable = first.chats.prefix { $0.isReachable }
        #expect(reachable.count == first.reachable, "reachable first")
        let rest = first.chats.dropFirst(reachable.count)
        let pinned = rest.prefix { $0.pinned }
        let unpinned = rest.dropFirst(pinned.count)
        #expect(unpinned.allSatisfy { !$0.pinned }, "then pinned")
        let used = unpinned.compactMap(\.activity)
        #expect(used == used.sorted(by: >), "then by last use")
        let older = try #require(first.chats.first { $0.reason == "inactive" })

        // Start an older one: pinned, started, among the reachable ones; the answer carries the status too
        let started = try await client.mac(.chatsStart, value: older.id)
        #expect(server.received.last?.op == "chats.start")
        #expect(server.received.last?.fields["text"] == .string(older.id))
        let now = try #require(started.chats?.chats.first { $0.id == older.id })
        #expect(now.pinned && now.state == "starting" && !now.skipped)
        #expect(started.status != nil)
        #expect(started.chats?.chats.prefix(while: \.isReachable).contains { $0.id == older.id } == true)

        // A chat that runs can't be deleted: the Mac's reason, in the phone's words
        do {
            _ = try await client.mac(.chatsDelete, value: older.id)
            Issue.record("a running chat is refused")
        } catch let refusal as MacRefusal {
            #expect(refusal.code == "chat-running")
            #expect(refusal.text == String(localized: "Stop it first, or close it in the Claude app."))
        }

        // Stop it: unpinned and skipped, nothing runs; then it can go
        let stopped = try #require(try await client.mac(.chatsStop, value: older.id).chats?.chats.first { $0.id == older.id })
        #expect(stopped.skipped && stopped.state == nil && !stopped.pinned)
        let afterDelete = try #require(try await client.mac(.chatsDelete, value: older.id).chats)
        #expect(!afterDelete.chats.contains { $0.id == older.id })
        do {
            _ = try await client.mac(.chatsDelete, value: older.id)
            Issue.record("a deleted chat is gone")
        } catch let refusal as MacRefusal {
            #expect(refusal.code == "not-found")
        }

        // Restart one that runs; one that doesn't is refused with the Mac's reason
        let running = try #require(first.chats.first { $0.state == "running" })
        let restarted = try #require(try await client.mac(.chatsRestart, value: running.id).chats?.chats.first { $0.id == running.id })
        #expect(restarted.state == "starting" && restarted.note == "restarting")
        let idle = try #require(afterDelete.chats.first { $0.state == nil })
        await #expect(throws: MacRefusal.self) { _ = try await client.mac(.chatsRestart, value: idle.id) }
        server.update { $0.chatsRestart = false }
        do {
            _ = try await client.mac(.chatsRestart, value: running.id)
            Issue.record("an older keeper can't restart")
        } catch let refusal as MacRefusal {
            #expect(refusal.code == "keeper-old")
        }
        // Not a chat of this Mac
        await #expect(throws: MacRefusal.self) { _ = try await client.mac(.chatsStart, value: "nonsense") }

        // A Mac from before start, stop and delete: it lists them not, refuses them, and pins and skips as before
        server.update { $0.chatsStartStop = false }
        let before = CompanionClient(transport: server.makeTransport(), signer: signer)
        await before.start()
        let oldFeatures = try await before.hello(app: "1", device: "d").features
        #expect(oldFeatures.contains("chats.pin") && oldFeatures.contains("chats.skip"))
        #expect(!oldFeatures.contains("chats.start") && !oldFeatures.contains("chats.delete"))
        await #expect(throws: (any Error).self) { _ = try await before.mac(.chatsStart, value: idle.id) }
        let pinnedAgain = try #require(try await before.mac(.chatsPin, value: idle.id).chats?.chats.first { $0.id == idle.id })
        #expect(pinnedAgain.pinned && pinnedAgain.state == "starting")

        // An older Mac still: no chats
        server.update { $0.oldMac = true }
        let old = CompanionClient(transport: server.makeTransport(), signer: signer)
        await old.start()
        #expect(!(try await old.hello(app: "1", device: "d").features.contains("chats.list")))
    }

    /// The app against the mock Mac: a start shows at once, the keeper's event a moment later shows it running; a
    /// delete takes it off the list.
    @MainActor
    @Test func thePageFollowsTheMac() async throws {
        let server = MockCompanionServer()
        server.update { $0.chatsStep = .milliseconds(300) }
        let connection = MacConnection(mac: Demo.content().mac, key: DeviceKey.ephemeral(), signer: nil,
                                       deviceName: "Test iPhone")
        connection.startDemo(server)
        try await waitUntil { connection.companionState == .ready }
        #expect(connection.chatsSupported)
        await connection.refreshChats()
        let list = try #require(connection.chats)
        let older = try #require(list.chats.first { $0.reason == "inactive" })
        let offer = ChatOffer.now(older, in: list, features: connection.hello?.features ?? [])
        #expect(offer.start == .chatsStart && offer.delete)

        try await connection.perform(.chatsStart, value: older.id)
        #expect(connection.chats?.chats.first { $0.id == older.id }?.state == "starting")
        try await waitUntil { connection.chats?.chats.first { $0.id == older.id }?.state == "running" }

        try await connection.perform(.chatsStop, value: older.id)
        #expect(connection.chats?.chats.first { $0.id == older.id }?.skipped == true)
        try await connection.perform(.chatsDelete, value: older.id)
        #expect(connection.chats?.chats.contains { $0.id == older.id } == false)
        connection.stop()
    }
}
