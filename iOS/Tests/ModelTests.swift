import Foundation
import Testing
@testable import Annex

@MainActor
struct VaultModelTests {
    private func model(_ entries: [(VaultEntry, VaultSecret)] = []) -> VaultModel {
        VaultModel(store: MemoryVaultStore(entries: entries), requiresAuthentication: false)
    }

    @Test func matchingLoginsForARequest() throws {
        let vault = model()
        try vault.save(VaultEntry(title: "Amazon", username: "max", uris: ["https://www.amazon.de/"], hasTOTP: false, hasNotes: false),
                       secret: VaultSecret(password: "a", totp: "", notes: ""))
        try vault.save(VaultEntry(title: "TUM", username: "ge12abc", uris: ["login.tum.de"], hasTOTP: false, hasNotes: false),
                       secret: VaultSecret(password: "b", totp: "", notes: ""))
        #expect(vault.logins(for: "www.amazon.de").map(\.title) == ["Amazon"])
        #expect(vault.logins(for: "amazon.de").isEmpty)  // www.amazon.de is not a parent of amazon.de
        #expect(vault.logins(for: "campus.tum.de").isEmpty)
        #expect(vault.logins(for: "login.tum.de").map(\.title) == ["TUM"])
    }

    @Test func savingSetsTheFlagsFromTheSecret() async throws {
        let vault = model()
        let entry = VaultEntry(title: "GitHub", username: "max", uris: [], hasTOTP: false, hasNotes: false)
        try vault.save(entry, secret: VaultSecret(password: "p", totp: "GEZDGNBV", notes: "  "))
        let saved = try #require(vault.entry(id: entry.id))
        #expect(saved.hasTOTP)
        #expect(!saved.hasNotes)
        #expect(try await vault.unlock(saved, reason: "test").password == "p")
        try vault.delete(saved)
        #expect(vault.entries.isEmpty)
    }

    @Test func importSkipsDuplicates() throws {
        let vault = model()
        let login = ImportedLogin(title: "Amazon", username: "Max", password: "x", uris: ["https://www.amazon.de/x"],
                                  totp: "", notes: "")
        let first = try vault.add(imported: [login, login])
        #expect(first.added == 1 && first.duplicates == 1)
        var other = login
        other.uris = ["www.amazon.de"]  // same host, other spelling
        other.username = "max"
        #expect(try vault.add(imported: [other]).duplicates == 1)
        other.username = "someone else"
        #expect(try vault.add(imported: [other]).added == 1)
        #expect(vault.entries.count == 2)
    }

    @Test func searchFindsTitlesUsersAndSites() throws {
        let vault = model([
            (VaultEntry(title: "Deutsche Bahn", username: "max@marquart.dev", uris: ["https://www.bahn.de"], hasTOTP: false, hasNotes: false),
             VaultSecret(password: "", totp: "", notes: "")),
        ])
        #expect(vault.entries(matching: "bahn").count == 1)
        #expect(vault.entries(matching: "MARQUART").count == 1)
        #expect(vault.entries(matching: "bahn.de").count == 1)
        #expect(vault.entries(matching: "amazon").isEmpty)
    }

    @Test func strongPasswords() {
        let passwords = (0..<50).map { _ in PasswordGenerator.make() }
        #expect(Set(passwords).count == 50)
        for p in passwords {
            #expect(p.count == 20)
            #expect(p.contains(where: \.isLowercase) && p.contains(where: \.isUppercase) && p.contains(where: \.isNumber))
        }
    }
}

/// The keychain wrapper against the simulator's keychain, under a service of its own.
struct KeychainTests {
    let service = "dev.marquart.annex.tests"

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

    @Test func helpRequestsOpenTheWorkspaceScreen() {
        let model = AppModel(isDemo: true)
        model.tab = .vault
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
