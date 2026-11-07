import Foundation

// The terminal on the paired Mac runs in a session that outlives the connection (Docs/COMPANION.md, "Terminal
// sessions"): the phone's SSH channel runs `aos-companion term attach` in a pseudo terminal. The Mac's side tells the
// phone where the output starts with a note (`ESC ] 7730 ; <JSON> BEL`, AOSKit `TermMarker`); the phone takes the
// notes out before its terminal sees them and counts the output bytes after the start: when it attaches again it
// asks for what comes after that count, and gets exactly what it missed. Pure, tested in TerminalAttachTests.

/// A note from `term attach`.
enum TermNote: Equatable, Sendable {
    /// The output that follows starts at `from`. `reset`: the terminal starts afresh (it gets the last part of the
    /// output, after `prefix` with the modes in effect there). `new`: a session that was just started; `gone`: the
    /// one asked for had ended, this is a new one.
    case start(id: String, from: UInt64, reset: Bool, prefix: Data, new: Bool, gone: String?)
    /// The session is over for this terminal: `exited` (the shell ended), `ended` (someone ended it), `taken`
    /// (another device attached), `lost` (the session's process went away).
    case end(why: String, status: Int?)

    init?(json: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let t = o["t"] as? String else { return nil }
        switch t {
        case "start":
            guard let id = o["id"] as? String, TermAttach.isID(id), let from = (o["from"] as? NSNumber)?.uint64Value else { return nil }
            let prefix = (o["prefix"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            self = .start(id: id, from: from, reset: o["reset"] as? Bool ?? true, prefix: prefix,
                          new: o["new"] as? Bool ?? false, gone: o["gone"] as? String)
        case "end":
            self = .end(why: o["why"] as? String ?? "ended", status: (o["status"] as? NSNumber)?.intValue)
        default:
            return nil
        }
    }
}

/// Takes the notes out of the terminal's output. Notes may arrive split over several chunks.
struct TermNoteFilter: Sendable {
    enum Piece: Equatable, Sendable {
        case bytes(Data)
        case note(TermNote)
    }

    static let introducer: [UInt8] = [0x1b, 0x5d] + Array("7730;".utf8)
    /// A note longer than this isn't one (the bytes go to the terminal as they are).
    static let maxNote = 64 * 1024

    private var carry: [UInt8] = []

    mutating func feed(_ chunk: Data) -> [Piece] {
        let input = carry.isEmpty ? [UInt8](chunk) : carry + [UInt8](chunk)
        carry = []
        var pieces: [Piece] = []
        var plainStart = 0
        func plain(upTo end: Int) {
            if end > plainStart { pieces.append(.bytes(Data(input[plainStart..<end]))) }
        }
        let intro = Self.introducer
        var k = 0
        while k < input.count, let esc = input[k...].firstIndex(of: 0x1b) {
            let rest = input.count - esc
            var matched = 0
            while matched < intro.count, matched < rest, input[esc + matched] == intro[matched] { matched += 1 }
            if matched < intro.count {
                // The start of an introducer at the end of the chunk waits for the next one.
                if matched == rest {
                    plain(upTo: esc)
                    carry = Array(input[esc...])
                    return pieces
                }
                k = esc + 1
                continue
            }
            let body = esc + intro.count
            guard let bell = input[body...].firstIndex(of: 0x07) else {
                if rest > Self.maxNote {
                    k = esc + 1
                    continue
                }
                plain(upTo: esc)
                carry = Array(input[esc...])
                return pieces
            }
            if let note = TermNote(json: Data(input[body..<bell])) {
                plain(upTo: esc)
                pieces.append(.note(note))
                plainStart = bell + 1
            }
            k = bell + 1
        }
        plain(upTo: input.count)
        return pieces
    }
}

/// The commands the phone runs on the Mac (in the login shell sshd starts them with, so the path is quoted).
enum TermAttach {
    static func isID(_ text: String) -> Bool {
        text.count == 8 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// In a pseudo terminal: attach to `id` (only what came after `have`), or start a new session.
    static func attach(companion: String, id: String?, have: UInt64?) -> String {
        var command = CompanionCommand.shellQuoted(companion) + " term attach"
        if let id, isID(id) {
            command += " --id \(id)"
            if let have { command += " --have \(have)" }
        }
        return command
    }

    static func list(companion: String) -> String { CompanionCommand.shellQuoted(companion) + " term list --json" }

    static func end(companion: String, id: String) -> String? {
        guard isID(id) else { return nil }
        return CompanionCommand.shellQuoted(companion) + " term end \(id)"
    }

    /// `term list --json`: the sessions on the Mac.
    static func sessions(fromList data: Data) -> [MacTermSession]? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = o["sessions"] as? [[String: Any]] else { return nil }
        return list.compactMap(MacTermSession.init)
    }
}

/// A terminal session on the Mac, as `term list` shows it.
struct MacTermSession: Identifiable, Equatable, Sendable {
    var id: String
    var attached: Bool
    /// When the client attached, or since when none is.
    var since: Date?
    var created: Date?
    var lastOutput: Date?
    /// Who is attached ("ssh 192.168.178.31").
    var from: String?
    /// The program in the foreground and its folder.
    var command: String?
    var cwd: String?
    var title: String?

    init(id: String, attached: Bool, since: Date? = nil, created: Date? = nil, lastOutput: Date? = nil,
         from: String? = nil, command: String? = nil, cwd: String? = nil, title: String? = nil) {
        self.id = id
        self.attached = attached
        self.since = since
        self.created = created
        self.lastOutput = lastOutput
        self.from = from
        self.command = command
        self.cwd = cwd
        self.title = title
    }

    init?(_ o: [String: Any]) {
        guard let id = o["id"] as? String, TermAttach.isID(id) else { return nil }
        func date(_ key: String) -> Date? { (o[key] as? String).flatMap(ISO8601.parse) }
        self.init(id: id, attached: o["attached"] as? Bool ?? false, since: date("since"), created: date("created"),
                  lastOutput: date("lastOutput"), from: o["from"] as? String, command: o["command"] as? String,
                  cwd: o["cwd"] as? String, title: o["title"] as? String)
    }

    /// "zsh in ~/Developer/aos", from the Mac user's home folder.
    func place(home: String?) -> String {
        var folder = cwd ?? ""
        if let home, !home.isEmpty, folder == home { folder = "~" }
        else if let home, !home.isEmpty, folder.hasPrefix(home + "/") { folder = "~" + folder.dropFirst(home.count) }
        let program = command ?? "shell"
        return folder.isEmpty ? program : String(localized: "\(program) in \(folder)")
    }
}
