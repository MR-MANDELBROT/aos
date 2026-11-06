import Foundation
import Testing
@testable import aOS

/// The keychain wrapper against the simulator's keychain, under a service of its own.
struct KeychainTests {
    let service = "dev.marquart.aos.tests"

    @Test func roundTrip() throws {
        defer { Keychain.deleteAll(service: service) }
        try Keychain.setJSON(["a", "b"], service: service, account: "list", protection: .afterFirstUnlock)
        try Keychain.set(Data("secret".utf8), service: service, account: "s", protection: .userPresence)
        #expect(try Keychain.getJSON([String].self, service: service, account: "list") == ["a", "b"])
        #expect(Set(try Keychain.accounts(service: service)) == ["list", "s"])
        // Replacing works for items behind user presence too (delete and add, no prompt)
        try Keychain.set(Data("new".utf8), service: service, account: "s", protection: .userPresence)
        try Keychain.delete(service: service, account: "list")
        #expect(try Keychain.get(service: service, account: "list") == nil)
        #expect(try Keychain.accounts(service: service) == ["s"])
    }
}

@MainActor
struct RequestQueueTests {
    private func request(_ id: String) -> SignInRequest {
        SignInRequest(id: id, agent: "Claude Code", host: "www.amazon.de", purpose: "x", expires: Date().addingTimeInterval(300))
    }

    @Test func laterKeepsARequestWaitingWithoutPoppingUpAgain() async throws {
        let model = AppModel(isDemo: true)
        model.handle(.signIn(request("r1")))
        #expect(model.presentedSignIn?.id == "r1")
        model.closeQuestionSheet()  // "Later"
        try await Task.sleep(for: .milliseconds(700))
        #expect(model.presentedSignIn == nil)
        #expect(model.signIns.map(\.id) == ["r1"])

        // A new request comes up, the one put off doesn't
        model.handle(.signIn(request("r2")))
        #expect(model.presentedSignIn?.id == "r2")
        model.handle(.signIn(request("r2")))  // the same event twice: once
        #expect(model.signIns.map(\.id) == ["r1", "r2"])

        // The Mac closes r2: the sheet shows the result, then closes; r1 stays put off
        model.handle(.signInClosed(request: "r2", result: .filled))
        #expect(model.signInResults["r2"] == .filled)
        try await Task.sleep(for: .milliseconds(2300))
        #expect(model.presentedSignIn == nil)
        #expect(model.signIns.map(\.id) == ["r1"])
    }

    @Test func aRequestThatComesAgainIsUpdatedNotShownAgain() async throws {
        let model = AppModel(isDemo: true)
        var locked = request("r1")
        locked.bitwarden = .locked
        model.handle(.signIn(locked))
        #expect(model.presentedSignIn?.bitwarden == .locked)
        model.closeQuestionSheet()  // "Later"
        try await Task.sleep(for: .milliseconds(600))
        // Bitwarden was unlocked on the Mac: the same request comes with its logins
        var unlocked = locked
        unlocked.bitwarden = .unlocked
        unlocked.logins = [BitwardenLogin(id: "b1", name: "Amazon", username: "max", hasCode: false)]
        model.handle(.signIn(unlocked))
        #expect(model.signIns == [unlocked])
        #expect(model.presentedSignIn == nil)  // still put off
        model.present(.signIn(unlocked))
        model.handle(.signIn(locked))  // and back: the open sheet follows
        #expect(model.presentedSignIn == locked)
    }

    @Test func helpRequestsOpenTheWorkspaceScreen() {
        let model = AppModel(isDemo: true)
        model.tab = .terminal
        model.screenTarget = .mac
        let help = HelpRequest(id: "h1", agent: "Codex", purpose: "Captcha", region: nil)
        model.handle(.help(help))
        #expect(model.tab == .screen)
        #expect(model.screenTarget == .workspace)
        #expect(model.activeHelp == help)
        model.handle(.helpClosed(request: "h1"))
        #expect(model.activeHelp == nil)
        #expect(model.helpRequests.isEmpty)
    }
}
