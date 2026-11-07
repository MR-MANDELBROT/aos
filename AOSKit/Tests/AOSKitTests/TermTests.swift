@testable import AOSKit
import Darwin
import XCTest

/// The terminal state a fresh terminal needs to continue a stream.
final class TermModesTests: XCTestCase {
    private func modes(_ text: String) -> TermModes {
        var m = TermModes()
        m.feed(Array(text.utf8))
        return m
    }

    func testPrivateModesOnAndOff() {
        var m = modes("\u{1b}[?1049h\u{1b}[?1h\u{1b}[?2004h\u{1b}[?25l")
        XCTAssertTrue(m.alternateScreen)
        XCTAssertTrue(m.applicationCursor)
        XCTAssertTrue(m.bracketedPaste)
        XCTAssertFalse(m.cursorVisible)
        m.feed(Array("\u{1b}[?1049l\u{1b}[?1;2004l\u{1b}[?25h".utf8))
        XCTAssertFalse(m.alternateScreen)
        XCTAssertFalse(m.applicationCursor)
        XCTAssertFalse(m.bracketedPaste)
        XCTAssertTrue(m.cursorVisible)
    }

    func testMouseKeypadCursorStyleAndKeyboardProtocol() {
        var m = modes("\u{1b}[?1002h\u{1b}[?1006h\u{1b}=\u{1b}[5 q\u{1b}[>3u")
        XCTAssertEqual(m.mouseTracking, 1002)
        XCTAssertEqual(m.mouseEncoding, 1006)
        XCTAssertTrue(m.keypadApplication)
        XCTAssertEqual(m.cursorStyle, 5)
        XCTAssertEqual(m.keyboardFlags, 3)
        // The alternate screen has its own keyboard stack
        m.feed(Array("\u{1b}[?1049h".utf8))
        XCTAssertEqual(m.keyboardFlags, 0)
        m.feed(Array("\u{1b}[>1u\u{1b}[=4;2u".utf8))
        XCTAssertEqual(m.keyboardFlags, 5)
        m.feed(Array("\u{1b}[<u\u{1b}[?1049l\u{1b}[<u\u{1b}[?1002l\u{1b}>\u{1b}[0 q".utf8))
        XCTAssertEqual(m.keyboardFlags, 0)
        XCTAssertNil(m.mouseTracking)
        XCTAssertFalse(m.keypadApplication)
        XCTAssertNil(m.cursorStyle)
    }

    func testSafePoints() {
        var m = TermModes()
        XCTAssertTrue(m.isSafePoint)
        m.feed(Array("\u{1b}[3".utf8))
        XCTAssertFalse(m.isSafePoint, "inside a CSI sequence")
        m.feed(Array("1m".utf8))
        XCTAssertTrue(m.isSafePoint)
        m.feed([0xc3])
        XCTAssertFalse(m.isSafePoint, "inside a UTF-8 character")
        m.feed([0xa4])
        XCTAssertTrue(m.isSafePoint)
        m.feed(Array("\u{1b}]0;Tit".utf8))
        XCTAssertFalse(m.isSafePoint, "inside an OSC string")
        m.feed(Array("le\u{07}".utf8))
        XCTAssertTrue(m.isSafePoint)
        XCTAssertEqual(m.title, "Title")
        m.feed(Array("\u{1b}]2;Other\u{1b}\\".utf8))
        XCTAssertEqual(m.title, "Other")
        // A cancelled sequence and an escape inside a CSI sequence
        m.feed(Array("\u{1b}[12\u{18}x\u{1b}[?10\u{1b}[?1h".utf8))
        XCTAssertTrue(m.isSafePoint)
        XCTAssertTrue(m.applicationCursor)
    }

    func testResetForgetsTheModesNotTheTitle() {
        let m = modes("\u{1b}]0;keep\u{07}\u{1b}[?1049h\u{1b}[?1h\u{1b}c")
        XCTAssertFalse(m.alternateScreen)
        XCTAssertFalse(m.applicationCursor)
        XCTAssertEqual(m.title, "keep")
    }

    func testPrefixPutsAFreshTerminalIntoTheModes() {
        let m = modes("\u{1b}[?1049h\u{1b}[?1h\u{1b}[?2004h\u{1b}[?1000h\u{1b}[?1006h\u{1b}[>1u\u{1b}[?25l")
        XCTAssertEqual(String(decoding: m.prefix, as: UTF8.self),
                       "\u{1b}[?1049h\u{1b}[?1h\u{1b}[?2004h\u{1b}[?1000h\u{1b}[?1006h\u{1b}[>1u\u{1b}[?25l")
        // Replaying the prefix gives the same modes.
        var fresh = TermModes()
        fresh.feed(m.prefix)
        XCTAssertEqual(fresh.alternateScreen, m.alternateScreen)
        XCTAssertEqual(fresh.keyboardFlags, m.keyboardFlags)
        XCTAssertEqual(fresh.mouseTracking, m.mouseTracking)
        XCTAssertTrue(TermModes().prefix.isEmpty)
    }
}

/// The output a session keeps, with offsets.
final class TermRingTests: XCTestCase {
    func testOffsetsSurviveTheRingRunningOver() {
        var ring = TermRing(capacity: 16)
        ring.append(Array("0123456789".utf8))
        XCTAssertEqual(ring.start, 0)
        XCTAssertEqual(ring.end, 10)
        ring.append(Array("abcdefghij".utf8))
        XCTAssertEqual(ring.start, 4)
        XCTAssertEqual(ring.end, 20)
        XCTAssertEqual(String(decoding: ring.bytes(from: 4), as: UTF8.self), "456789abcdefghij")
        XCTAssertEqual(String(decoding: ring.bytes(from: 15, limit: 3), as: UTF8.self), "fgh")
        // A chunk bigger than the ring keeps its end
        ring.append(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8))
        XCTAssertEqual(ring.end, 46)
        XCTAssertEqual(ring.start, 30)
        XCTAssertEqual(String(decoding: ring.bytes(from: 0), as: UTF8.self), "KLMNOPQRSTUVWXYZ")
        XCTAssertTrue(ring.bytes(from: 46).isEmpty)
    }

    func testTheStateAtTheStartFollowsWhatWasDropped() {
        var ring = TermRing(capacity: 32)
        ring.append(Array("\u{1b}[?1049hvim screen".utf8))
        XCTAssertFalse(ring.modesAtStart.alternateScreen)
        ring.append(Array(repeating: UInt8(ascii: "x"), count: 30))
        XCTAssertTrue(ring.modesAtStart.alternateScreen, "the switch to the alternate screen left the ring")
        XCTAssertTrue(ring.modesAtEnd.alternateScreen)
    }

    func testAClientThatHasTheStartGetsExactlyTheRest() {
        var ring = TermRing(capacity: 64)
        ring.append(Array("hello\r\n".utf8))
        XCTAssertEqual(ring.replay(have: 7), TermReplay(from: 7, reset: false, prefix: []))
        XCTAssertEqual(ring.replay(have: 3), TermReplay(from: 3, reset: false, prefix: []))
        XCTAssertEqual(ring.replay(have: 0), TermReplay(from: 0, reset: false, prefix: []))
    }

    func testAClientWithNothingStartsAfreshAfterALineBreak() {
        var ring = TermRing(capacity: 1024)
        ring.append(Array("first line\r\nsecond\u{1b}[31m line\r\nthird".utf8))
        // Budget ends inside "first line": the replay starts at the next line.
        let plan = ring.replay(have: nil, budget: 30)
        XCTAssertTrue(plan.reset)
        XCTAssertEqual(String(decoding: ring.bytes(from: plan.from), as: UTF8.self), "second\u{1b}[31m line\r\nthird")
        // Too much missed (have is before the start): the same.
        var small = TermRing(capacity: 16)
        small.append(Array("0123456789abcdefghij".utf8))
        XCTAssertTrue(small.replay(have: 2).reset)
        XCTAssertTrue(small.replay(have: 99).reset)
    }

    func testAFreshStartNeverBeginsInsideASequence() {
        var ring = TermRing(capacity: 1024)
        let text = "\u{1b}[?1049h" + String(repeating: "\u{1b}[38;5;123mX", count: 20)
        ring.append(Array(text.utf8))
        // A budget that ends in the middle of a color sequence, no line breaks: the next safe point.
        let plan = ring.replay(have: nil, budget: 100)
        let rest = ring.bytes(from: plan.from)
        XCTAssertTrue(rest.starts(with: Array("\u{1b}[38".utf8)) || rest.starts(with: [UInt8(ascii: "X")]))
        XCTAssertEqual(String(decoding: plan.prefix, as: UTF8.self), "\u{1b}[?1049h")
    }
}

/// Frames between client and holder.
final class TermFrameTests: XCTestCase {
    func testFramesRoundTripAcrossChunks() throws {
        let frames: [TermFrame] = [.hello(TermJSON.encode(TermHello(op: .attach, have: 42, cols: 80, rows: 24))),
                                   .input(Array("ls\r".utf8)), .size(cols: 300, rows: 2), .detach,
                                   .output(Array(repeating: 7, count: 70000)), .end(Data("{}".utf8))]
        let bytes = frames.flatMap(\.encoded)
        var reader = TermFrameReader()
        var got: [TermFrame] = []
        var k = 0
        while k < bytes.count {
            let n = min(1000, bytes.count - k)
            reader.append(bytes[k..<(k + n)])
            k += n
            while let frame = try reader.next() { got.append(frame) }
        }
        XCTAssertEqual(got, frames)
        let hello = try XCTUnwrap({ if case .hello(let d) = got[0] { return TermJSON.decode(TermHello.self, d) }; return nil }())
        XCTAssertEqual(hello.have, 42)
    }

    func testUnknownOrOversizedFramesAreRefused() {
        var reader = TermFrameReader()
        reader.append([0x5a, 0, 0, 0, 0])
        XCTAssertThrowsError(try reader.next())
        var big = TermFrameReader()
        big.append([0x49, 0x7f, 0, 0, 0])
        XCTAssertThrowsError(try big.next())
    }

    func testTheMarkerIsAnOSCSequenceWithJSON() throws {
        let start = TermStart(session: "0123abcd", from: 99, reset: true, prefix: Array("\u{1b}[?1h".utf8), created: Date())
        let marker = TermMarker.start(start, new: false, gone: "deadbeef")
        XCTAssertTrue(marker.starts(with: [0x1b, 0x5d] + Array("7730;".utf8)))
        XCTAssertEqual(marker.last, 0x07)
        XCTAssertFalse(marker.dropFirst(2).dropLast().contains(0x1b), "no escape inside")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(marker.dropFirst(7).dropLast())) as? [String: Any])
        XCTAssertEqual(json["t"] as? String, "start")
        XCTAssertEqual(json["id"] as? String, "0123abcd")
        XCTAssertEqual(json["from"] as? Int, 99)
        XCTAssertEqual(json["reset"] as? Bool, true)
        XCTAssertEqual(json["gone"] as? String, "deadbeef")
        XCTAssertEqual(Data(base64Encoded: json["prefix"] as? String ?? ""), Data("\u{1b}[?1h".utf8))
    }
}

// MARK: - Sessions

/// A folder for sessions whose socket paths stay well under the 104 bytes of a Unix socket address.
private func shortTempDir() throws -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("aosterm-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// A client speaking frames, for the holder tests.
private final class FrameClient {
    let fd: Int32
    var reader = TermFrameReader()
    var output: [UInt8] = []
    var starts: [TermStart] = []
    var ends: [TermEnd] = []
    var replies: [Data] = []

    init(dir: URL, id: String) throws {
        fd = try TermSocket.connect(TermPlace.socket(dir, id).path)
    }

    deinit { close(fd) }

    func send(_ frame: TermFrame) { TermSocket.writeAll(fd, frame.encoded) }

    /// Reads until `condition` holds or the time is up.
    @discardableResult
    func read(until condition: (FrameClient) -> Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !condition(self) {
            guard Date() < deadline else { return false }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 100) > 0 else { continue }
            let n = Darwin.read(fd, &buffer, buffer.count)
            guard n > 0 else { return condition(self) }
            reader.append(buffer[0..<n])
            while let frame = try? reader.next() {
                switch frame {
                case .start(let d): if let s = TermJSON.decode(TermStart.self, d) { starts.append(s) }
                case .output(let b): output += b
                case .end(let d): if let e = TermJSON.decode(TermEnd.self, d) { ends.append(e) }
                case .reply(let d): replies.append(d)
                default: break
                }
            }
        }
        return true
    }

    var text: String { String(decoding: output, as: UTF8.self) }
}

final class TermHolderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try shortTempDir()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A holder with /bin/sh in a thread of the test (HOME is the test folder: no profile of the user is read).
    private func startHolder(id: String = TermPlace.newID()) -> (TermHolder, String, XCTestExpectation) {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = dir.path
        env["PS1"] = "$ "
        env["ENV"] = nil
        let holder = TermHolder(config: .init(dir: dir, id: id, shell: "/bin/sh", argv0: "sh", environment: env,
                                              home: dir.path, cols: 80, rows: 24))
        let done = expectation(description: "holder ended")
        Thread.detachNewThread {
            _ = try? holder.run()
            done.fulfill()
        }
        let path = TermPlace.socket(dir, id).path
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: path) { usleep(10_000) }
        return (holder, id, done)
    }

    private func attach(_ id: String, have: UInt64? = nil, cols: UInt16 = 80, rows: UInt16 = 24,
                        client: String? = nil) throws -> FrameClient {
        let c = try FrameClient(dir: dir, id: id)
        c.send(.hello(TermJSON.encode(TermHello(op: .attach, have: have, cols: cols, rows: rows, from: "test",
                                                client: client))))
        XCTAssertTrue(c.read(until: { !$0.starts.isEmpty }))
        return c
    }

    func testAttachTypeDetachAndComeBackForWhatWasMissed() throws {
        let (holder, id, done) = startHolder()
        let first = try attach(id)
        XCTAssertEqual(first.starts.first?.from, 0)
        first.send(.input(Array("echo one-$((40+2))\n".utf8)))
        XCTAssertTrue(first.read(until: { $0.text.contains("one-42") }))
        let seen = first.starts[0].from + UInt64(first.output.count)
        first.send(.detach)

        // Output while nobody is attached stays in the ring.
        let helper = try FrameClient(dir: dir, id: id)
        helper.send(.hello(TermJSON.encode(TermHello(op: .info))))
        XCTAssertTrue(helper.read(until: { !$0.replies.isEmpty }))
        let info = try XCTUnwrap(TermJSON.decode(TermInfo.self, helper.replies[0]))
        XCTAssertEqual(info.id, id)
        XCTAssertFalse(info.attached)

        let second = try attach(id, have: seen)
        XCTAssertEqual(second.starts.first?.reset, false)
        XCTAssertEqual(second.starts.first?.from, seen)
        second.send(.input(Array("echo two\n".utf8)))
        XCTAssertTrue(second.read(until: { $0.text.contains("two\r\n") }))
        XCTAssertFalse(second.text.contains("one-42"), "only what came after")

        // Ending: the client hears why, the socket goes.
        holder.requestEnd()
        XCTAssertTrue(second.read(until: { !$0.ends.isEmpty }))
        XCTAssertEqual(second.ends.first?.reason, .ended)
        wait(for: [done], timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TermPlace.socket(dir, id).path))
    }

    func testANewClientTakesTheSessionOver() throws {
        let (_, id, done) = startHolder()
        let first = try attach(id)
        let second = try attach(id, have: nil)
        XCTAssertTrue(first.read(until: { !$0.ends.isEmpty }))
        XCTAssertEqual(first.ends.first?.reason, .taken)
        XCTAssertEqual(second.starts.first?.reset, true, "nothing to continue from: afresh")
        second.send(.input(Array("exit 7\n".utf8)))
        XCTAssertTrue(second.read(until: { !$0.ends.isEmpty }))
        XCTAssertEqual(second.ends.first, TermEnd(reason: .exited, status: 7))
        wait(for: [done], timeout: 10)
    }

    func testTheSameDeviceReplacesItsOldConnectionAndAnotherTakesItOver() throws {
        let (holder, id, done) = startHolder()
        let phone = try attach(id, client: "phone-1")
        XCTAssertEqual(TermClient.list(dir: dir).first?.client, "phone-1")
        // The same phone again (its old connection lingers after a network change): replaced, not taken.
        let again = try attach(id, client: "phone-1")
        XCTAssertTrue(phone.read(until: { !$0.ends.isEmpty }))
        XCTAssertEqual(phone.ends.first?.reason, .replaced)
        // Another device takes it over, and so does a client that doesn't say which device it is.
        let other = try attach(id, client: "ipad-2")
        XCTAssertTrue(again.read(until: { !$0.ends.isEmpty }))
        XCTAssertEqual(again.ends.first?.reason, .taken)
        XCTAssertEqual(TermClient.list(dir: dir).first?.client, "ipad-2")
        let anonymous = try attach(id)
        XCTAssertTrue(other.read(until: { !$0.ends.isEmpty }))
        XCTAssertEqual(other.ends.first?.reason, .taken)
        XCTAssertNil(TermClient.list(dir: dir).first?.client)
        // Two clients without an id are never the same device.
        let second = try attach(id)
        XCTAssertTrue(anonymous.read(until: { !$0.ends.isEmpty }))
        XCTAssertEqual(anonymous.ends.first?.reason, .taken)
        withExtendedLifetime(second) {}
        holder.requestEnd()
        wait(for: [done], timeout: 10)
    }

    func testDeviceIDs() {
        XCTAssertTrue(TermHello.isClientID("6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        XCTAssertTrue(TermHello.isClientID("phone_1.a"))
        XCTAssertFalse(TermHello.isClientID(""))
        XCTAssertFalse(TermHello.isClientID("two words"))
        XCTAssertFalse(TermHello.isClientID("a;rm"))
        XCTAssertFalse(TermHello.isClientID(String(repeating: "a", count: 65)))
        XCTAssertFalse(TermHello.isClientID("ä"))
    }

    func testTheShellSeesTheClientsSize() throws {
        let (holder, id, done) = startHolder()
        let c = try attach(id, cols: 100, rows: 30)
        c.send(.input(Array("stty size\n".utf8)))
        XCTAssertTrue(c.read(until: { $0.text.contains("30 100") }))
        c.send(.size(cols: 52, rows: 19))
        c.send(.input(Array("stty size\n".utf8)))
        XCTAssertTrue(c.read(until: { $0.text.contains("19 52") }))
        holder.requestEnd()
        wait(for: [done], timeout: 10)
    }

    func testListAndEndFromOutside() throws {
        let (_, id, done) = startHolder()
        let c = try attach(id)
        let list = TermClient.list(dir: dir)
        XCTAssertEqual(list.map(\.id), [id])
        XCTAssertEqual(list.first?.attached, true)
        XCTAssertEqual(list.first?.from, "test")
        XCTAssertNotNil(list.first?.command)
        // A socket nobody answers on is cleaned up
        FileManager.default.createFile(atPath: TermPlace.socket(dir, "0badc0de").path, contents: nil)
        XCTAssertEqual(TermClient.list(dir: dir).map(\.id), [id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: TermPlace.socket(dir, "0badc0de").path))

        XCTAssertTrue(TermClient.end(dir: dir, id: id))
        XCTAssertTrue(c.read(until: { !$0.ends.isEmpty }))
        XCTAssertEqual(c.ends.first?.reason, .ended)
        wait(for: [done], timeout: 10)
        XCTAssertFalse(TermClient.end(dir: dir, id: id), "already gone")
        XCTAssertTrue(TermClient.list(dir: dir).isEmpty)
    }
}

/// The real `aos-companion term` in a pseudo terminal, as the iPhone's SSH channel runs it.
final class TermEndToEndTests: XCTestCase {
    private var dir: URL!
    private var companion: String!

    override func setUpWithError() throws {
        let built = Bundle(for: TermEndToEndTests.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("aos-companion").path
        guard FileManager.default.isExecutableFile(atPath: built) else {
            throw XCTSkip("aos-companion isn't built next to the tests (swift build --build-tests)")
        }
        companion = built
        dir = try shortTempDir()
    }

    override func tearDownWithError() throws {
        if let dir {
            for s in TermClient.list(dir: dir) { TermClient.end(dir: dir, id: s.id) }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// A client process with a pseudo terminal of its own (its controlling terminal: resizing reaches it).
    private final class Terminal {
        let pid: pid_t
        let master: Int32
        var bytes: [UInt8] = []

        init(_ arguments: [String], env: [String: String], cols: UInt16 = 80, rows: UInt16 = 24) throws {
            let argv = arguments.map { strdup($0) } + [nil]
            let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer {
                argv.forEach { free($0) }
                envp.forEach { free($0) }
            }
            var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
            var fd: Int32 = -1
            let child = forkpty(&fd, nil, nil, &size)
            if child == 0 {
                execve(argv[0], argv, envp)
                _exit(127)
            }
            guard child > 0 else { throw XCTSkip("no pseudo terminal") }
            pid = child
            master = fd
        }

        func type(_ text: String) {
            _ = Array(text.utf8).withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
        }

        func resize(cols: UInt16, rows: UInt16) {
            TermSocket.setWindowSize(master, cols: cols, rows: rows)
        }

        var text: String { String(decoding: bytes, as: UTF8.self) }

        @discardableResult
        func read(until condition: (String) -> Bool, timeout: TimeInterval = 15) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            var buffer = [UInt8](repeating: 0, count: 65536)
            while !condition(text) {
                guard Date() < deadline else { return false }
                var p = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 100) > 0 else { continue }
                let n = Darwin.read(master, &buffer, buffer.count)
                guard n > 0 else { return condition(text) }
                bytes += buffer[0..<n]
            }
            return true
        }

        /// The JSON of each of the client's markers.
        var markers: [[String: Any]] {
            var found: [[String: Any]] = []
            var rest = bytes[...]
            while let start = rest.firstRange(of: TermMarker.introducer) {
                let after = rest[start.upperBound...]
                guard let bell = after.firstIndex(of: 0x07) else { break }
                if let o = try? JSONSerialization.jsonObject(with: Data(after[..<bell])) as? [String: Any] { found.append(o) }
                rest = rest[(bell + 1)...]
            }
            return found
        }

        /// Closes the terminal, as a dropped SSH connection does; the client exits.
        func hangUp() -> Int32 {
            close(master)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        }

        func waitForExit() -> Int32 {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            close(master)
            return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        }
    }

    private var env: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["AOS_TERM_SHELL"] = "/bin/sh"
        env["HOME"] = dir.path
        env["PS1"] = "$ "
        env["ENV"] = nil
        env["TERM"] = "xterm-256color"
        return env
    }

    func testASessionOutlivesItsTerminalAndComesBackWithWhatWasMissed() throws {
        let first = try Terminal([companion, "term", "attach", "--dir", dir.path], env: env)
        XCTAssertTrue(first.read(until: { $0.contains("$ ") }), first.text)
        let start = try XCTUnwrap(first.markers.first)
        XCTAssertEqual(start["t"] as? String, "start")
        XCTAssertEqual(start["new"] as? Bool, true)
        let id = try XCTUnwrap(start["id"] as? String)
        first.type("echo first-$((6*7))\r")
        XCTAssertTrue(first.read(until: { $0.contains("first-42") }))
        // What the phone counts: every byte after the start marker, without markers.
        let markerEnd = first.bytes.firstRange(of: [0x07])!.upperBound
        let seen = UInt64(first.bytes.count - markerEnd) + UInt64(start["from"] as? Int ?? 0)
        // The connection drops (once the shell has the command); the shell keeps running and writes on.
        first.type("sleep 1; echo while-$((1+1))-away\r")
        XCTAssertTrue(first.read(until: { $0.contains("while-$((1+1))-away") }))
        XCTAssertEqual(first.hangUp(), 0)
        Thread.sleep(forTimeInterval: 1.6)
        XCTAssertEqual(TermClient.list(dir: dir).first?.attached, false)

        let second = try Terminal([companion, "term", "attach", "--dir", dir.path, "--id", id, "--have", String(seen)], env: env)
        XCTAssertTrue(second.read(until: { $0.contains("while-2-away") }), second.text)
        let again = try XCTUnwrap(second.markers.first)
        XCTAssertEqual(again["id"] as? String, id)
        XCTAssertEqual(again["reset"] as? Bool, false)
        XCTAssertEqual(again["new"] as? Bool, false)
        XCTAssertFalse(second.text.contains("first-42"), "only what was missed")

        // Resizing the client's terminal reaches the shell.
        second.resize(cols: 61, rows: 17)
        Thread.sleep(forTimeInterval: 0.3)
        second.type("stty size\r")
        XCTAssertTrue(second.read(until: { $0.contains("17 61") }), second.text)

        // The shell ends: the client says so and exits 0; the session is gone.
        second.type("exit\r")
        XCTAssertTrue(second.read(until: { $0.contains("\"t\":\"end\"") }))
        XCTAssertEqual(second.markers.last?["why"] as? String, "exited")
        XCTAssertEqual(second.waitForExit(), 0)
        for _ in 0..<50 where !TermClient.list(dir: dir).isEmpty { usleep(50_000) }
        XCTAssertTrue(TermClient.list(dir: dir).isEmpty)
    }

    func testTheSamePhoneAttachingAgainReplacesItsOldConnection() throws {
        let first = try Terminal([companion, "term", "attach", "--dir", dir.path, "--client", "phone-1"], env: env)
        XCTAssertTrue(first.read(until: { $0.contains("$ ") }), first.text)
        let id = try XCTUnwrap(first.markers.first?["id"] as? String)
        let list = try Subprocess.runBlocking(companion, ["term", "list", "--json", "--dir", dir.path], timeout: 10)
        XCTAssertTrue(String(decoding: list.stdout, as: UTF8.self).contains("\"client\":\"phone-1\""))

        let second = try Terminal([companion, "term", "attach", "--dir", dir.path, "--id", id, "--client", "phone-1"],
                                  env: env)
        XCTAssertTrue(second.read(until: { $0.contains("\"t\":\"start\"") }), second.text)
        XCTAssertTrue(first.read(until: { $0.contains("\"t\":\"end\"") }), first.text)
        XCTAssertEqual(first.markers.last?["why"] as? String, "replaced")
        XCTAssertEqual(first.waitForExit(), TermClient.Exit.replaced.rawValue)
        second.type("exit\r")
        XCTAssertTrue(second.read(until: { $0.contains("\"why\":\"exited\"") }), second.text)
        XCTAssertEqual(second.waitForExit(), 0)
    }

    func testAGoneSessionIsReplacedAndTheTerminalIsTold() throws {
        let t = try Terminal([companion, "term", "attach", "--dir", dir.path, "--id", "0badc0de", "--have", "500"], env: env)
        XCTAssertTrue(t.read(until: { $0.contains("$ ") }), t.text)
        let start = try XCTUnwrap(t.markers.first)
        XCTAssertEqual(start["gone"] as? String, "0badc0de")
        XCTAssertEqual(start["new"] as? Bool, true)
        XCTAssertEqual(start["from"] as? Int, 0)
        let id = try XCTUnwrap(start["id"] as? String)
        XCTAssertNotEqual(id, "0badc0de")

        // Taken over by a second terminal; then ended from outside.
        let other = try Terminal([companion, "term", "attach", "--dir", dir.path, "--id", id], env: env)
        XCTAssertTrue(other.read(until: { $0.contains("\"t\":\"start\"") }))
        XCTAssertTrue(t.read(until: { $0.contains("\"t\":\"end\"") }))
        XCTAssertEqual(t.markers.last?["why"] as? String, "taken")
        XCTAssertEqual(t.waitForExit(), TermClient.Exit.taken.rawValue)

        let end = try Subprocess.runBlocking(companion, ["term", "end", id, "--dir", dir.path], timeout: 10)
        XCTAssertEqual(String(decoding: end.stdout, as: UTF8.self), "{\"ok\":true}\n")
        XCTAssertTrue(other.read(until: { $0.contains("\"why\":\"ended\"") }))
        XCTAssertEqual(other.waitForExit(), 0)
        let list = try Subprocess.runBlocking(companion, ["term", "list", "--json", "--dir", dir.path], timeout: 10)
        XCTAssertEqual(String(decoding: list.stdout, as: UTF8.self), "{\"sessions\":[]}\n")
    }
}
