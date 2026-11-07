import Foundation
import SwiftTerm
import Testing
import UIKit
@testable import aOS

/// The notes of `aos-companion term attach`, taken out of the output.
struct TermNoteFilterTests {
    private let start = TermMarkerForTests.start(id: "0123abcd", from: 42, reset: false, new: false, gone: nil)

    private func run(_ chunks: [[UInt8]]) -> [TermNoteFilter.Piece] {
        var filter = TermNoteFilter()
        var pieces: [TermNoteFilter.Piece] = []
        for chunk in chunks { pieces += filter.feed(Data(chunk)) }
        // Neighbouring bytes, joined (how they were split doesn't matter)
        var joined: [TermNoteFilter.Piece] = []
        for piece in pieces {
            if case .bytes(let b) = piece, case .bytes(let a)? = joined.last {
                joined[joined.count - 1] = .bytes(a + b)
            } else {
                joined.append(piece)
            }
        }
        return joined
    }

    @Test func aNoteIsTakenOutAndTheRestStays() {
        let bytes = Array("before\u{1b}[31m".utf8) + start + Array("after\u{1b}]0;title\u{07}".utf8)
        #expect(run([bytes]) == [
            .bytes(Data("before\u{1b}[31m".utf8)),
            .note(.start(id: "0123abcd", from: 42, reset: false, prefix: Data(), new: false, gone: nil)),
            .bytes(Data("after\u{1b}]0;title\u{07}".utf8)),
        ])
    }

    @Test func aNoteSplitAnywhereIsStillFound() {
        let bytes = Array("ab".utf8) + start + Array("cd".utf8)
        for cut in 1..<bytes.count {
            let pieces = run([Array(bytes[..<cut]), Array(bytes[cut...])])
            #expect(pieces.count == 3, "cut at \(cut)")
            #expect(pieces.first == .bytes(Data("ab".utf8)))
            #expect(pieces.last == .bytes(Data("cd".utf8)))
        }
        // Byte by byte
        #expect(run(bytes.map { [$0] }).count == 3)
    }

    @Test func somethingThatOnlyLooksLikeANoteStays() {
        let fake = Array("\u{1b}]7730;not json\u{07}x".utf8)
        #expect(run([fake]) == [.bytes(Data(fake))])
        let end = TermMarkerForTests.end("exited", status: 3)
        #expect(run([end]) == [.note(.end(why: "exited", status: 3))])
    }

    @Test func theCommands() {
        let path = "/Applications/aOS.app/Contents/MacOS/aos-companion"
        #expect(TermAttach.attach(companion: path, id: nil, have: 5) == "'\(path)' term attach")
        #expect(TermAttach.attach(companion: path, id: "0123abcd", have: nil) == "'\(path)' term attach --id 0123abcd")
        #expect(TermAttach.attach(companion: path, id: "0123abcd", have: 99) == "'\(path)' term attach --id 0123abcd --have 99")
        // Only real ids reach the command line
        #expect(TermAttach.attach(companion: path, id: "x; rm -rf ~", have: 1) == "'\(path)' term attach")
        #expect(TermAttach.end(companion: path, id: "$(reboot)") == nil)
        #expect(TermAttach.end(companion: path, id: "0123abcd") == "'\(path)' term end 0123abcd")
    }

    @Test func theListFromTheMac() throws {
        let json = #"{"sessions":[{"id":"0123abcd","attached":true,"since":"2026-11-07T10:00:00Z","from":"ssh 10.0.0.2","command":"vim","cwd":"/Users/max/Developer/aos","cols":80,"rows":24,"pid":1,"shell":2,"created":"2026-11-07T09:00:00Z"},{"id":"bad"}]}"#
        let list = try #require(TermAttach.sessions(fromList: Data(json.utf8)))
        #expect(list.map(\.id) == ["0123abcd"])
        #expect(list[0].attached)
        #expect(list[0].place(home: "/Users/max").hasSuffix("~/Developer/aos"))
        #expect(list[0].place(home: "/Users/max").hasPrefix("vim"))
    }
}

/// The key bar's row: the arrows in the middle at the start, every key at least 46 pt.
struct KeyBarLayoutTests {
    @Test func theArrowsSitInTheMiddle() {
        for width: CGFloat in [359, 370, 386, 424, 600, 744, 840] {
            for arrows in TerminalArrowKeys.allCases {
                let layout = KeyBarLayout(width: width, arrows: arrows)
                #expect(abs(layout.centerMidX - width / 2) < 0.01, "\(arrows) at \(width)")
                #expect(layout.keyWidth >= KeyBarLayout.minimumKey - 0.01, "\(arrows) at \(width)")
                #expect(layout.leading >= (arrows == .pad ? 1 : 0))
            }
        }
        // An iPhone 17 Pro upright (the bar is 386 pt wide): Esc, Control and Tab left of the pad
        #expect(KeyBarLayout(width: 386, arrows: .pad).leading == 3)
        #expect(KeyBarLayout(width: 386, arrows: .fourKeys).leading == 2)
    }

    @Test func swipesSidewaysAreArrowsAndUpOrDownOnlyAsFlicksAtTheEnd() {
        func decide(_ dx: CGFloat, _ dy: CGFloat, speed: CGFloat = 200, after: TimeInterval = 0.05, atEnd: Bool = true)
            -> TerminalSwipe.Decision? {
            TerminalSwipe.decide(translation: CGSize(width: dx, height: dy), velocity: CGPoint(x: 0, y: speed),
                                 elapsed: after, atEnd: atEnd)
        }
        #expect(decide(4, 3) == nil, "inside the dead zone")
        #expect(decide(14, 2) == .arrows)
        #expect(decide(-14, 5) == .arrows)
        #expect(decide(14, 2, atEnd: false) == .arrows, "sideways also when scrolled back")
        #expect(decide(2, -14) == .scroll, "a slow drag up or down scrolls")
        #expect(decide(2, -14, speed: -900) == .arrows, "a quick flick at the end is ↑")
        #expect(decide(2, 14, speed: 900, atEnd: false) == .scroll, "scrolled back: flicks scroll")
        #expect(decide(14, 0, after: 0.6) == TerminalSwipe.Decision.none, "a resting finger is a long press")
        #expect(decide(1, 1, after: 0.6) == TerminalSwipe.Decision.none)
    }
}

/// The key bar as a view: one scrolling row, the arrows in the middle of the screen at its start.
@MainActor
struct KeyBarViewTests {
    private func lay(_ bar: TerminalKeyBar, width: CGFloat) {
        bar.frame = CGRect(x: 0, y: 0, width: width, height: TerminalKeyBar.height)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        // The row is built once the scroll area inside the panel has its width.
        bar.layoutIfNeeded()
    }

    private func controls(in view: UIView) -> [UIView] {
        var found: [UIView] = []
        func walk(_ v: UIView) {
            if v.accessibilityIdentifier != nil, v is UIControl || v.accessibilityIdentifier == "paste" { found.append(v) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    @Test func thePadOrTheFourArrowsAreInTheMiddle() throws {
        let view = AOSTerminalView(fontSize: 13)
        let bar = view.keyBar
        for width: CGFloat in [390, 402, 440, 874] {
            for arrows in TerminalArrowKeys.allCases {
                bar.arrows = arrows
                lay(bar, width: width)
                let all = controls(in: bar)
                let ids = Set(all.compactMap(\.accessibilityIdentifier))
                for name in ["escape", "ctrl", "alt", "tab", "tab+1", "paste", "function(12)", "text(\"|\")", "text(\"~\")"] {
                    #expect(ids.contains(name), "\(name) at \(width) pt, \(arrows)")
                }
                let center: CGFloat
                switch arrows {
                case .pad:
                    let pad = try #require(all.first { $0.accessibilityIdentifier == "arrowPad" })
                    #expect(!ids.contains("up"), "no extra arrows beside the pad")
                    center = pad.convert(pad.bounds, to: bar).midX
                case .fourKeys:
                    let left = try #require(all.first { $0.accessibilityIdentifier == "left" })
                    let down = try #require(all.first { $0.accessibilityIdentifier == "down" })
                    #expect(!ids.contains("arrowPad"))
                    center = (left.convert(left.bounds, to: bar).minX + down.convert(down.bounds, to: bar).maxX) / 2
                }
                #expect(abs(center - width / 2) < 1, "\(arrows) at \(width) pt: \(center)")
                // Every key big enough
                for control in all where control.accessibilityIdentifier != "arrowPad" {
                    #expect(control.bounds.width >= 45.9 && control.bounds.height >= 44, "\(control.accessibilityIdentifier ?? "")")
                }
            }
        }
    }

    @Test func theRowSnapsToWholeKeys() {
        let edges: [CGFloat] = [0, 50, 100, 160, 210]
        #expect(TerminalKeyBar.snapped(70, edges: edges, maxOffset: 300) == 50)
        #expect(TerminalKeyBar.snapped(140, edges: edges, maxOffset: 300) == 160)
        #expect(TerminalKeyBar.snapped(280, edges: edges, maxOffset: 300) == 300, "the end of the row")
        #expect(TerminalKeyBar.snapped(140, edges: edges, maxOffset: 0) == 0)
    }
}

/// The Mac's terminal against the test SSH server's sessions: attaching, dropping and coming back for what was missed,
/// ending.
@MainActor
@Suite(.serialized)
struct HeldTerminalTests {
    let key = DeviceKey.ephemeral()

    private func connectedMac(_ server: TestSSHServer) async throws -> MacConnection {
        let mac = PairedMac(name: "Test Mac", hosts: ["127.0.0.1"], sshPort: UInt16(server.port), user: "max",
                            hostKey: server.hostKeyLine, hostKeyFingerprint: server.hostKeyFingerprint,
                            companionPath: TestSSHServer.companionPath, lastHost: "127.0.0.1")
        let connection = MacConnection(mac: mac, key: key, signer: nil, deviceName: "Test iPhone")
        connection.start()
        try await waitUntil { connection.ssh?.isActive == true }
        return connection
    }

    @Test func attachDropComeBackAndEnd() async throws {
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop() } }
        let connection = try await connectedMac(server)
        defer { connection.stop() }
        let target = TerminalSession.Target.mac(UUID())
        UserDefaults.standard.removeObject(forKey: "terminal.session.\(target.key)")
        let session = TerminalSession(id: target, title: "Test Mac")
        session.macConnection = { connection }
        await session.connect(mac: connection)
        try await waitUntil { session.phase == .connected }
        #expect(server.terms.log == ["attach new"])
        let id = try #require(session.holderID)
        try await waitUntil { session.view.screenText().contains("Welcome to the held shell") }

        session.view.send(Array("hi there".utf8))
        try await waitUntil { session.view.screenText().contains("hi there") }

        // The connection drops: the terminal says so, attaches again by itself and gets only what it missed.
        session.view.send(Array("drop\r".utf8))
        try await waitUntil { server.terms.log.count == 2 }
        let seen = UInt64("Welcome to the held shell\r\n$ hi there".utf8.count)
        #expect(server.terms.log.last == "attach \(id) have \(seen)")
        try await waitUntil { session.phase == .connected && session.view.screenText().contains("while away") }
        #expect(session.view.screenText().contains("hi there"), "nothing was cleared")
        #expect(session.view.screenText().components(separatedBy: "Welcome").count == 2, "nothing came twice")

        // Ending: the Mac ends the session, the terminal says why and forgets it.
        await session.endSession()
        try await waitUntil { session.phase == .ended }
        #expect(session.endReason == .ended)
        #expect(session.holderID == nil)
        #expect(server.terms.log.contains("end \(id)"))
    }

    @Test func aRelaunchStartsAfreshInTheSameSession() async throws {
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop() } }
        let connection = try await connectedMac(server)
        defer { connection.stop() }
        let target = TerminalSession.Target.mac(UUID())
        UserDefaults.standard.removeObject(forKey: "terminal.session.\(target.key)")
        let first = TerminalSession(id: target, title: "Test Mac")
        first.macConnection = { connection }
        await first.connect(mac: connection)
        try await waitUntil { first.phase == .connected }
        first.view.send(Array("remember me".utf8))
        try await waitUntil { first.view.screenText().contains("remember me") }
        let id = try #require(first.holderID)
        first.disconnect()
        #expect(first.phase == .detached)

        // The app was closed: a new terminal knows the session and gets its screen back.
        let second = TerminalSession(id: target, title: "Test Mac")
        #expect(second.holderID == id)
        second.macConnection = { connection }
        await second.connect(mac: connection)
        try await waitUntil { second.phase == .connected && second.view.screenText().contains("remember me") }
        #expect(server.terms.log.last == "attach \(id)")

        // Typing "exit": the shell ended, the next connect starts a new one.
        second.view.send(Array("exit\r".utf8))
        try await waitUntil { second.phase == .ended }
        #expect(second.endReason == .exited)
        #expect(second.holderID == nil)
    }
}
