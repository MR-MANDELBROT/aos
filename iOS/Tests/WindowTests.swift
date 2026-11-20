import Foundation
import Testing
import UIKit
@testable import aOS

/// More than one window (iPad, Stage Manager): the main window is one, the others are terminal windows; one terminal of
/// the app shows a session at a time, so two of this device's own attaches never take it from each other.
@MainActor
@Suite(.serialized)
struct WindowTests {
    @Test func aWindowTerminalKeepsItsKey() {
        let mac = UUID()
        let scene = UUID().uuidString
        let target = TerminalSession.Target.window(mac: mac, scene: scene)
        #expect(TerminalSession.Target(key: target.key) == target)
        #expect(target.macID == mac)
        #expect(TerminalSession.Target(key: TerminalSession.Target.mac(mac).key) == .mac(mac))
        // Nothing but the window's name after the Mac's id
        #expect(TerminalSession.Target(key: "win-\(mac.uuidString)-a/b") == nil)
        #expect(TerminalSession.Target(key: "win-\(mac.uuidString)") == nil)
        #expect(TerminalSession.Target(key: "win-nonsense") == nil)
    }

    @Test func onlyTheFirstWindowShowsTheTabs() {
        let model = AppModel(isDemo: true)
        #expect(model.claimMainScene("a"))
        #expect(model.claimMainScene("a"), "the same window again")
        #expect(!model.claimMainScene("b"), "a second one becomes a terminal window")
        model.releaseMainScene("b")
        #expect(model.mainScene == "a")
        model.releaseMainScene("a")
        #expect(model.claimMainScene("b"))
    }

    @Test func aSessionOpenedInAnotherWindowLeavesTheFirst() throws {
        let model = AppModel(isDemo: true)
        let mac = try #require(model.activeMac)
        let main = model.terminal(for: .mac(mac.id))
        let session = "3fa9c1d2"
        main.switchTo(session: session)
        #expect(main.isActive)
        #expect(model.terminal(showing: session) === main)

        // "Open in New Window": the new window's terminal takes it, the main one lets go and says where it is
        let window = model.windowTerminal(mac: mac, scene: UUID().uuidString, initialSession: session)
        #expect(window.holderID == session)
        #expect(main.phase == .ended)
        #expect(main.endReason == .elsewhere)
        #expect(TerminalSession.storedHolderID(for: .mac(mac.id)) == nil, "not again by itself after a relaunch")

        // "Open It Here" in the main window takes it back
        main.takeOver()
        #expect(main.isActive)
        #expect(window.phase == .ended)
        #expect(window.endReason == .elsewhere)

        // A window that closes lets go of its terminal
        model.closeTerminalWindow(window.id)
        #expect(model.terminals[window.id] == nil)
        main.disconnect()
        UserDefaults.standard.removeObject(forKey: "terminal.session.\(main.id.key)")
    }
}
