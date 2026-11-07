import Foundation
@testable import aOS

/// The Mac's terminal sessions as the test SSH server plays them (`aos-companion term attach|list|end`, AOSKit
/// TermHolder): each session keeps all its output with offsets, one channel at a time is attached, a channel that
/// attaches with `--have N` gets what came after N, one without gets everything afresh. Typed input comes back as
/// output (an echo); "exit\r" ends the shell, "drop\r" drops the connection (the channel closes without a word, as when
/// the network goes) and the session writes "while away" meanwhile.
final class FakeTermSessions: @unchecked Sendable {
    struct Attached {
        let id = UUID()
        let write: @Sendable (Data) -> Void
        let close: @Sendable (_ status: Int?) -> Void
    }

    private final class Session {
        let id: String
        var output: [UInt8] = []
        var attached: Attached?
        init(id: String) { self.id = id }
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var counter = 0
    /// What the phone asked for, in order ("attach new", "attach 0000aa01 have 12", "list", "end 0000aa01").
    private(set) var requests: [String] = []

    var log: [String] { lock.withLock { requests } }

    /// Handles an exec command of the companion's `term`; false if it isn't one.
    func handle(command: String, companion: String, attached: Attached) -> Bool {
        let prefix = CompanionCommand.shellQuoted(companion) + " term "
        guard command.hasPrefix(prefix) else { return false }
        let words = command.dropFirst(prefix.count).split(separator: " ").map(String.init)
        switch words.first {
        case "attach":
            func value(_ name: String) -> String? {
                guard let k = words.firstIndex(of: name), k + 1 < words.count else { return nil }
                return words[k + 1]
            }
            attach(id: value("--id"), have: value("--have").flatMap { UInt64($0) }, to: attached)
        case "list":
            lock.withLock { requests.append("list") }
            let list = lock.withLock { sessions.values.map { ["id": $0.id, "attached": $0.attached != nil, "command": "zsh",
                                                               "cwd": "/Users/max"] as [String: Any] } }
            let data = (try? JSONSerialization.data(withJSONObject: ["sessions": list])) ?? Data()
            attached.write(data + Data([0x0a]))
            attached.close(0)
        case "end":
            let id = words.count > 1 ? words[1] : ""
            lock.withLock { requests.append("end \(id)") }
            let session = lock.withLock { sessions.removeValue(forKey: id) }
            if let other = session?.attached {
                other.write(Data(TermMarkerForTests.end("ended")))
                other.close(0)
            }
            attached.write(Data((session == nil ? "{\"ok\":false,\"gone\":true}\n" : "{\"ok\":true}\n").utf8))
            attached.close(0)
        default:
            attached.close(2)
        }
        return true
    }

    private func attach(id: String?, have: UInt64?, to channel: Attached) {
        let (session, isNew, gone, previous): (Session, Bool, String?, Attached?) = lock.withLock {
            if let id, let existing = sessions[id] {
                requests.append("attach \(id)\(have.map { " have \($0)" } ?? "")")
                let previous = existing.attached
                existing.attached = channel
                return (existing, false, nil, previous)
            }
            counter += 1
            let session = Session(id: String(format: "0000aa%02x", counter))
            session.output = Array("Welcome to the held shell\r\n$ ".utf8)
            session.attached = channel
            sessions[session.id] = session
            requests.append("attach new")
            return (session, true, id, nil)
        }
        if let previous {
            previous.write(Data(TermMarkerForTests.end("taken")))
            previous.close(0)
        }
        let (from, rest): (UInt64, [UInt8]) = lock.withLock {
            let from = (!isNew && have != nil && have! <= UInt64(session.output.count)) ? have! : 0
            return (from, Array(session.output[Int(from)...]))
        }
        channel.write(Data(TermMarkerForTests.start(id: session.id, from: from, reset: from == 0, new: isNew, gone: gone)))
        if !rest.isEmpty { channel.write(Data(rest)) }
    }

    /// Typed bytes from an attached channel.
    func input(_ data: Data, from channel: Attached) {
        let text = String(decoding: data, as: UTF8.self)
        let session: Session? = lock.withLock { sessions.values.first { $0.attached?.id == channel.id } }
        guard let session else { return }
        if text.contains("drop\r") {
            lock.withLock {
                session.attached = nil
                session.output += Array("drop\r\nwhile away\r\n$ ".utf8)
            }
            channel.close(nil)
            return
        }
        if text.contains("exit\r") {
            lock.withLock { _ = sessions.removeValue(forKey: session.id) }
            channel.write(Data(TermMarkerForTests.end("exited", status: 0)))
            channel.close(0)
            return
        }
        let echo = Array(data)
        lock.withLock { session.output += echo }
        channel.write(data)
    }
}

/// The notes as AOSKit's TermMarker writes them.
enum TermMarkerForTests {
    static func start(id: String, from: UInt64, reset: Bool, new: Bool, gone: String?) -> [UInt8] {
        var o: [String: Any] = ["t": "start", "id": id, "from": from, "reset": reset, "prefix": "", "new": new,
                                "created": "2026-11-07T10:00:00Z"]
        if let gone { o["gone"] = gone }
        return wrap(o)
    }

    static func end(_ why: String, status: Int? = nil) -> [UInt8] {
        var o: [String: Any] = ["t": "end", "why": why]
        if let status { o["status"] = status }
        return wrap(o)
    }

    static func wrap(_ o: [String: Any]) -> [UInt8] {
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        return [0x1b, 0x5d] + Array("7730;".utf8) + Array(data) + [0x07]
    }
}
