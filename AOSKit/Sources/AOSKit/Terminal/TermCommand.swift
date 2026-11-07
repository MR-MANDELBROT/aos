import Darwin
import Foundation

/// `aos-companion term ...`: the terminal sessions on the command line (the iPhone runs `term attach` in its SSH
/// channel with a pseudo terminal, `term list --json` and `term end <id>` in exec channels).
///
///     term attach [--id ID] [--have OFFSET]   attach to a session (a new one without --id, or if ID is gone)
///     term list [--json]                      the sessions on this Mac
///     term end ID                             end a session (its shell gets SIGHUP)
///     term hold --id ID --cols C --rows R     (internal) hold a session; `attach` starts it
///
/// `--dir DIR` (or AOS_TERM_DIR) puts the sessions elsewhere (tests); AOS_TERM_SHELL picks another shell.
public enum TermCommand {
    public static let usage = """
        usage: aos-companion term attach [--id ID] [--have OFFSET]
               aos-companion term list [--json]
               aos-companion term end ID
        """

    public static func run(_ arguments: [String]) -> Int32 {
        var args = Array(arguments)
        guard let verb = args.first else { return fail(usage) }
        args.removeFirst()
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var positional: [String] = []
        var k = 0
        while k < args.count {
            let a = args[k]
            if ["--dir", "--id", "--have", "--cols", "--rows"].contains(a), k + 1 < args.count {
                options[String(a.dropFirst(2))] = args[k + 1]
                k += 2
            } else if a.hasPrefix("--") {
                flags.insert(String(a.dropFirst(2)))
                k += 1
            } else {
                positional.append(a)
                k += 1
            }
        }
        let dir = options["dir"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? TermPlace.directory()
        switch verb {
        case "attach":
            let have = options["have"].flatMap { UInt64($0) }
            return TermClient.attach(dir: dir, id: options["id"], have: have, holder: executable)
        case "list":
            let sessions = TermClient.list(dir: dir)
            if flags.contains("json") {
                let data = TermJSON.encode(["sessions": sessions])
                FileHandle.standardOutput.write(data + Data([0x0a]))
            } else if sessions.isEmpty {
                print("No terminal sessions.")
            } else {
                for s in sessions {
                    let state = s.attached ? "attached\(s.from.map { " (\($0))" } ?? "")" : "detached"
                    let place = s.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
                    print("\(s.id)  \(state)  \(s.command ?? "?")  \(place)")
                }
            }
            return 0
        case "end":
            guard let id = positional.first ?? options["id"], TermPlace.isID(id) else { return fail(usage) }
            let ended = TermClient.end(dir: dir, id: id)
            FileHandle.standardOutput.write(Data((ended ? "{\"ok\":true}\n" : "{\"ok\":false,\"gone\":true}\n").utf8))
            return 0
        case "hold":
            guard let id = options["id"], TermPlace.isID(id) else { return fail(usage) }
            let cols = options["cols"].flatMap { UInt16($0) } ?? 80
            let rows = options["rows"].flatMap { UInt16($0) } ?? 24
            return hold(dir: dir, id: id, cols: cols, rows: rows)
        default:
            return fail(usage)
        }
    }

    private static func fail(_ text: String) -> Int32 {
        FileHandle.standardError.write(Data((text + "\n").utf8))
        return 2
    }

    /// This program, to start a holder with.
    static var executable: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    // MARK: hold

    nonisolated(unsafe) private static var endFD: Int32 = -1

    static func hold(dir: URL, id: String, cols: UInt16, rows: UInt16) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        let env = shellEnvironment()
        let shell = env["AOS_TERM_SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? loginShell()
        let home = env["HOME"] ?? NSHomeDirectory()
        let holder = TermHolder(config: .init(dir: dir, id: id, shell: shell, environment: env, home: home,
                                              cols: cols, rows: rows))
        let logURL = dir.appendingPathComponent("holder.log")
        holder.log = { line in appendLog(logURL, line) }
        // SIGTERM ends the session like `term end`.
        endFD = holder.controlWriteFD
        signal(SIGTERM) { _ in
            var byte: UInt8 = 1
            _ = write(TermCommand.endFD, &byte, 1)
        }
        _ = chdir("/")
        do {
            return try holder.run()
        } catch {
            appendLog(logURL, "session \(id): \(error.localizedDescription)")
            return 1
        }
    }

    /// The user's login shell (what sshd would start), else zsh.
    static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell.map({ String(cString: $0) }),
           !shell.isEmpty, FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    /// The environment the shell starts with: this process's (sshd's for the phone), with UTF-8 text if nothing
    /// says otherwise (an SSH session from the phone brings no locale; umlauts would break).
    static func shellEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let locale = ["LC_ALL", "LC_CTYPE", "LANG"].compactMap { env[$0] }.first { !$0.isEmpty }
        if locale == nil {
            let preferred = Locale.current.identifier.split(separator: "@").first.map(String.init) ?? "en_US"
            let candidate = "\(preferred).UTF-8"
            env["LANG"] = FileManager.default.fileExists(atPath: "/usr/share/locale/\(candidate)") ? candidate : "en_US.UTF-8"
        }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["USER"] == nil { env["USER"] = NSUserName() }
        if env["LOGNAME"] == nil { env["LOGNAME"] = NSUserName() }
        return env
    }

    /// Events only (never terminal content); the log moves aside past 256 KB.
    static func appendLog(_ url: URL, _ line: String) {
        let fm = FileManager.default
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > 256 * 1024 {
            try? fm.removeItem(at: url.appendingPathExtension("old"))
            try? fm.moveItem(at: url, to: url.appendingPathExtension("old"))
        }
        let text = "\(ISO8601DateFormatter().string(from: Date())) [\(getpid())] \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
}
