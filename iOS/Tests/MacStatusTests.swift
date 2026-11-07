import CryptoKit
import Foundation
import Testing
@testable import aOS

/// The Overview's ops: signed like every request, the parameter in the signed text, the status read leniently.
struct MacStatusTests {
    @Test func whatTheOpsSign() {
        let sleep = CompanionRequest.mac(.sleep, value: nil).signatureFields(key: "k", ts: 1, nonce: "n")
        #expect(sleep.op == "companion.mac.sleep")
        #expect(sleep.data == CompanionSignature.dataDigest())
        let awake = CompanionRequest.mac(.stayAwake, value: "lidClosed").signatureFields(key: "k", ts: 1, nonce: "n")
        #expect(awake.op == "companion.mac.stay-awake")
        #expect(awake.data == CompanionSignature.dataDigest(text: "lidClosed"))
        #expect(CompanionRequest.mac(.workspaceStart, value: nil).op == "workspace.start")
    }

    @Test func theLineCarriesTheValueAsText() throws {
        let line = try CompanionRequest.mac(.stayAwake, value: "off").line(id: 4)
        let object = try #require(try JSONDecoder().decode(JSONValue.self, from: line).object)
        #expect(object["op"] == .string("mac.stay-awake"))
        #expect(object["text"] == .string("off"))
        let plain = try #require(try JSONDecoder().decode(JSONValue.self, from: CompanionRequest.mac(.sleep, value: nil).line(id: 5)).object)
        #expect(plain["text"] == nil)
    }

    @Test func theStatusIsReadLeniently() throws {
        let json = """
        {"power":{"source":"battery","battery":7,"charging":false,"minutes":95,"lid":"closed","thermal":"serious"},
         "awake":{"setting":"lidClosed","holding":true,"lidClosedMode":true,"blocker":"lowBattery","helper":"enabled","otherService":false},
         "workspace":{"state":"running","setupComplete":true},
         "session":{"enabled":true,"state":"needsLogin","since":"2026-11-07T10:00:00Z"},
         "newChats":{"enabled":false},"kept":{"enabled":true,"running":3},
         "bitwarden":{"state":"unlocked","until":"2026-11-07T18:00:00Z"},"somethingNew":{"x":1}}
        """
        let object = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).object)
        let status = MacStatus(object)
        #expect(status.power?.battery == 7)
        #expect(status.power?.lid == "closed")
        #expect(status.awake?.setting == .lidClosed)
        #expect(status.awake?.lidClosedMode == true)
        #expect(status.workspace?.state == "running")
        #expect(status.session?.state == "needsLogin")
        #expect(status.newChats?.enabled == false)
        #expect(status.kept == 3)
        #expect(status.bitwarden?.state == "unlocked")
        #expect(status.bitwarden?.until != nil)
        // In words
        let power = try #require(status.power)
        #expect(MacStatusText.batterySymbol(power) == "battery.0percent")
        #expect(MacStatusText.batteryDetail(power).contains("1:35"))
        #expect(MacStatusText.thermalDetail(power) != nil)
        #expect(MacStatusText.awakeDetail(try #require(status.awake)).contains("10"))
        // An older Mac: nothing breaks
        #expect(MacStatus([:]) == MacStatus())
    }

    @Test func theDisplayAndWhatToOffer() throws {
        func status(_ json: String) throws -> MacStatus {
            MacStatus(try #require(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).object))
        }
        let all = Set(MacAction.allCases.map(\.rawValue))
        let on = try status(#"{"display":{"state":"on","external":1}}"#)
        #expect(on.display == MacStatus.Display(state: "on", external: 1))
        #expect(MacOffer.now(on, features: all, sleeping: false) == MacOffer(sleep: true, displayOff: true, displayOn: false))
        #expect(MacStatusText.displayDetail(try #require(on.display)) != nil, "with a monitor")
        let off = try status(#"{"display":{"state":"off","external":0}}"#)
        #expect(MacOffer.now(off, features: all, sleeping: false) == MacOffer(sleep: true, displayOff: false, displayOn: true))
        // An aOS that can't turn it on: nothing for the display.
        #expect(MacOffer.now(off, features: ["mac.status", "mac.sleep"], sleeping: false) == MacOffer(sleep: true))
        let none = try status(#"{"display":{"state":"none","external":0}}"#)
        #expect(MacOffer.now(none, features: all, sleeping: false) == MacOffer(sleep: true))
        #expect(MacStatusText.displayDetail(try #require(none.display))?.contains("lid") == true)
        // Sleeping: nothing at all. An older aOS without the display: Sleep and Display Off, as before.
        #expect(MacOffer.now(on, features: all, sleeping: true) == MacOffer())
        #expect(MacOffer.now(MacStatus(), features: [], sleeping: false) == MacOffer(sleep: true, displayOff: true))
    }

    @Test func aSignInOnTheMacIsAskedFor() {
        #expect(AOSCard.needsSignIn(MacStatus(session: .init(enabled: true, state: "needsLogin"))))
        #expect(AOSCard.needsSignIn(MacStatus(newChats: .init(enabled: true, state: "needsLogin"))))
        #expect(!AOSCard.needsSignIn(MacStatus(session: .init(enabled: false, state: "needsLogin"))))
        #expect(!AOSCard.needsSignIn(MacStatus(session: .init(enabled: true, state: "running"))))
        #expect(!AOSCard.needsSignIn(nil))
    }

    @Test func refusalsAreWordedHere() {
        #expect(MacRefusal(code: "sleep-disabled", message: "x").text.contains("pmset disablesleep"))
        #expect(MacRefusal(code: "unheard-of", message: "As the Mac says").text == "As the Mac says")
    }

    @Test func signedActionsAgainstTheMock() async throws {
        let signer = CompanionSigner(phoneID: "4853150ceae1", key: CompanionKey.ephemeral())
        let server = MockCompanionServer(keepsSecrets: true)
        let publicKey = signer.key.publicKey
        server.update { $0.trustedPhone = .init(phoneID: signer.phoneID, publicKey: publicKey) }
        let client = CompanionClient(transport: server.makeTransport(), signer: signer)
        await client.start()

        let status = try #require(try await client.mac(.status).status)
        #expect(status.awake?.setting == .lidClosed)
        let changed = try #require(try await client.mac(.stayAwake, value: "lidOpen").status)
        #expect(changed.awake?.setting == .lidOpen)
        #expect(server.received.last?.fields["text"] == .string("lidOpen"))
        let sleep = try await client.mac(.sleep)
        #expect(sleep.sleepsIn == 1.5)
        let dark = try #require(try await client.mac(.displayOff).status)
        #expect(dark.display?.state == "off")
        let lit = try #require(try await client.mac(.displayOn).status)
        #expect(lit.display?.state == "on")
        // A refusal with its code
        server.update {
            $0.refuse["workspace.start"] = "The workspace isn't set up yet."
            $0.refuseCode["workspace.start"] = "not-set-up"
        }
        await #expect(throws: MacRefusal(code: "not-set-up", message: "The workspace isn't set up yet.")) {
            _ = try await client.mac(.workspaceStart)
        }
        // Unsigned: the Mac wants this iPhone paired again
        let unsigned = CompanionClient(transport: server.makeTransport())
        await unsigned.start()
        await #expect(throws: CompanionError.pairAgain) { _ = try await unsigned.mac(.status) }
    }

    @Test func helloSaysWhatTheMacOffers() async throws {
        let server = MockCompanionServer(keepsSecrets: true)
        let client = CompanionClient(transport: server.makeTransport())
        await client.start()
        #expect(try await client.hello(app: "1", device: "d").features.contains("mac.status"))
        server.update { $0.oldMac = true }
        let old = CompanionClient(transport: server.makeTransport())
        await old.start()
        #expect(try await old.hello(app: "1", device: "d").features.isEmpty)
    }
}
