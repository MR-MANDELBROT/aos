import Darwin
import Foundation
import Synchronization

// Freezing with the lid closed (Docs/DESIGN.md, "Staying awake, freezing and the hotspot"). With "Stay awake: also
// with the lid closed" the Mac runs on with nobody in front of it; the user's apps would keep spending battery. aOS
// stops them with SIGSTOP (windows and contents stay as they were) and continues them with SIGCONT when the lid
// opens. Ported from Cloupi's freezer (~/cloupi/mac/CloupiWake/Sources/CloupiMenuBar/Freezer.swift), with its
// safety rules: the record is on disk before the first signal, nothing is signalled without a matching start time,
// an entry leaves the record only once its process continued or is gone.

/// One process of the table (sysctl KERN_PROC_ALL).
public struct ProcessEntry: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: uid_t
    public var startSec: Int
    public var startUsec: Int
    /// p_comm: the executable's name, at most 16 characters.
    public var name: String
    /// Already stopped (by someone else, or by us).
    public var stopped: Bool

    public init(pid: Int32, ppid: Int32, uid: uid_t, startSec: Int = 0, startUsec: Int = 0, name: String,
                stopped: Bool = false) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.startSec = startSec
        self.startUsec = startUsec
        self.name = name
        self.stopped = stopped
    }
}

/// An app as NSWorkspace lists it (the app passes these in; AOSKit doesn't use AppKit).
public struct RunningAppInfo: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String
    public var name: String
    /// Activation policy regular: an app with a Dock icon.
    public var regular: Bool

    public init(pid: Int32, bundleID: String, name: String, regular: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.regular = regular
    }
}

/// What would be frozen: an app and its processes.
public struct FreezeTarget: Equatable, Sendable {
    public var app: String
    public var bundleID: String
    public var processes: [ProcessEntry]
}

/// Which apps freeze, pure (FreezePlannerTests).
public enum FreezePlanner {
    /// Never frozen: aOS itself (its VM runs in the app), Claude (the desktop app hosts Claude Code sessions), Cloupi,
    /// Finder and the system's own tools, terminals and code editors (agents and Claude Code run there, and builds the
    /// user left running), password managers, VPNs (the iPhone reaches the Mac through them), file providers (a
    /// frozen one hangs every program that opens one of its files), and tools that intercept the keyboard or mouse
    /// (frozen, input would stall when the lid opens). A "*" at the end stands for a prefix.
    public static let builtinExclude: [String] = [
        Brand.bundleIdentifierPrefix + "*", "com.anthropic.*", "de.cloupi.*",
        "com.apple.finder", "com.apple.systempreferences", "com.apple.SystemPreferences", "com.apple.ActivityMonitor",
        "com.apple.Console", "com.apple.ScreenSharing", "com.apple.ScreenContinuity", "com.apple.dt.Xcode",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "dev.warp.*",
        "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.jetbrains.*", "com.google.antigravity",
        "com.1password.*", "com.agilebits.*", "com.bitwarden.*",
        "com.tailscale.ipn.macos", "io.tailscale.ipn.macsys", "com.wireguard.macos",
        "com.microsoft.OneDrive", "com.microsoft.SharePoint-mac", "com.getdropbox.dropbox", "com.google.drivefs",
        "com.box.desktop",
        "com.apphousekitchen.aldente-pro", "com.apphousekitchen.aldente",
        "com.hegenberg.BetterTouchTool", "org.pqrs.*", "com.stairways.keyboardmaestro.*", "org.hammerspoon.Hammerspoon",
        "com.lwouis.alt-tab-macos",
    ]

    /// Processes that keep their whole app awake when they run inside it: a Claude Code session or one of aOS's own
    /// programs (aos-mcp runs under every agent that uses the workspace). They are never stopped either.
    public static let agentNames: Set<String> = ["claude", "aos-mcp", "aos-session", "aos-companion"]

    public static func matches(_ bundleID: String, _ patterns: [String]) -> Bool {
        patterns.contains { p in p.hasSuffix("*") ? bundleID.hasPrefix(String(p.dropLast())) : bundleID == p }
    }

    /// Every descendant of the roots (not the roots), breadth first over ppid.
    public static func descendants(of roots: [Int32], parent: [Int32: Int32]) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for (pid, ppid) in parent where pid != ppid { children[ppid, default: []].append(pid) }
        var out: [Int32] = []
        var seen = Set(roots)
        var queue = roots
        while !queue.isEmpty {
            let p = queue.removeFirst()
            for c in (children[p] ?? []).sorted() where !seen.contains(c) {
                seen.insert(c)
                out.append(c)
                queue.append(c)
            }
        }
        return out
    }

    /// The apps to freeze now. `responsible`: for a process launchd adopted (ppid 1), the app macOS holds
    /// responsible for it (iTerm2's session servers, Safari's web content): they belong to that app's tree.
    /// `isAgent` decides for one process whether it is an agent (by default its name is in `agentNames`).
    public static func plan(apps: [RunningAppInfo], table: [Int32: ProcessEntry], uid: uid_t, me: Int32,
                            exclude: [String] = [], responsible: [Int32: [Int32]] = [:],
                            isAgent: (ProcessEntry) -> Bool = { agentNames.contains($0.name) }) -> [FreezeTarget] {
        let parent = table.mapValues(\.ppid)
        let patterns = builtinExclude + exclude
        var result: [FreezeTarget] = []
        for app in apps where app.regular && !matches(app.bundleID, patterns) {
            let root = app.pid
            guard root > 1, root != me, let rootEntry = table[root], rootEntry.uid == uid else { continue }
            var pids = [root] + descendants(of: [root], parent: parent)
            for r in responsible[root] ?? [] where !pids.contains(r) {
                pids.append(r)
                pids.append(contentsOf: descendants(of: [r], parent: parent).filter { !pids.contains($0) })
            }
            let entries = pids.compactMap { table[$0] }.filter { $0.uid == uid && $0.pid != me }
            // A conversation or an agent runs inside (a terminal tab, an editor's terminal): the app stays awake.
            if entries.contains(where: isAgent) { continue }
            let procs = entries.filter { !$0.stopped }
            if !procs.isEmpty { result.append(FreezeTarget(app: app.name, bundleID: app.bundleID, processes: procs)) }
        }
        return result
    }
}

/// A frozen process. The start time keeps a reused pid of another process from being touched.
public struct FrozenProcess: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startSec: Int
    public var startUsec: Int
    public var name: String
    public var app: String

    public init(_ p: ProcessEntry, app: String) {
        pid = p.pid
        startSec = p.startSec
        startUsec = p.startUsec
        name = p.name
        self.app = app
    }

    public var key: String { "\(pid):\(startSec):\(startUsec)" }
}

/// A process by pid and start time.
public struct ProcessIdentity: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startSec: Int
    public var startUsec: Int

    public init(pid: Int32, startSec: Int, startUsec: Int) {
        self.pid = pid
        self.startSec = startSec
        self.startUsec = startUsec
    }

    public static var current: ProcessIdentity? {
        guard let s = ProcessTable.startTime(getpid()) else { return nil }
        return ProcessIdentity(pid: getpid(), startSec: s.sec, startUsec: s.usec)
    }

    /// The same process still runs (same pid and start time).
    public var isAlive: Bool {
        guard let s = ProcessTable.startTime(pid) else { return false }
        return s.sec == startSec && s.usec == startUsec
    }
}

/// run/frozen.json: who froze what. Written before the first signal; aos-session and the app's next start thaw
/// everything in it when its owner is gone.
public struct FrozenRecord: Codable, Equatable, Sendable {
    public var owner: ProcessIdentity?
    public var processes: [FrozenProcess]

    public init(owner: ProcessIdentity?, processes: [FrozenProcess]) {
        self.owner = owner
        self.processes = processes
    }

    public static func url(_ paths: Paths) -> URL { paths.run.appendingPathComponent("frozen.json") }

    public static func read(_ url: URL) -> FrozenRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FrozenRecord.self, from: data)
    }

    /// Writes atomically (0600); an empty record removes the file. False on an error.
    @discardableResult
    public func write(_ url: URL) -> Bool {
        do {
            if processes.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                return true
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = url.appendingPathExtension("tmp")
            try JSONEncoder().encode(self).write(to: tmp, options: .atomic)
            chmod(tmp.path, 0o600)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            return false
        }
    }

    /// The entries that stay after a thaw: only those whose process (same start time) still exists and didn't
    /// take SIGCONT. Without a process table everything stays (the next try comes soon).
    public static func remainingAfterThaw(_ list: [FrozenProcess], table: [Int32: ProcessEntry]?,
                                          cont: (Int32) -> Bool) -> [FrozenProcess] {
        guard let table else { return list }
        return list.filter { p in
            guard let e = table[p.pid], e.startSec == p.startSec, e.startUsec == p.startUsec else { return false }
            return !cont(p.pid)
        }
    }
}

/// The kernel's process table.
public enum ProcessTable {
    /// Every process (sysctl). nil on an error (never silently empty, or entries of the record would be lost).
    public static func snapshot() -> [Int32: ProcessEntry]? {
        let stride = MemoryLayout<kinfo_proc>.stride
        for attempt in 0..<4 {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64 * (attempt + 1))
            size = procs.count * stride
            if sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            var out: [Int32: ProcessEntry] = [:]
            for i in 0..<(size / stride) {
                var p = procs[i]
                let name = withUnsafePointer(to: &p.kp_proc.p_comm) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
                }
                let st = p.kp_proc.p_un.__p_starttime
                out[p.kp_proc.p_pid] = ProcessEntry(pid: p.kp_proc.p_pid, ppid: p.kp_eproc.e_ppid,
                                                    uid: p.kp_eproc.e_ucred.cr_uid, startSec: Int(st.tv_sec),
                                                    startUsec: Int(st.tv_usec), name: name,
                                                    stopped: p.kp_proc.p_stat == SSTOP)
            }
            return out
        }
        return nil
    }

    /// A process's start time, straight from the kernel.
    public static func startTime(_ pid: Int32) -> (sec: Int, usec: Int)? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard n == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return (Int(info.pbi_start_tvsec), Int(info.pbi_start_tvusec))
    }

    /// The process macOS holds responsible for `pid` (how Safari's web content or iTerm2's session servers belong to
    /// their app). A private libsystem function; without it, only ppid counts.
    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    private static let responsibleFunction: ResponsibleFunction? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    /// Processes adopted by launchd, grouped by the app responsible for them.
    public static func responsibleMap(_ table: [Int32: ProcessEntry], uid: uid_t) -> [Int32: [Int32]] {
        guard let f = responsibleFunction else { return [:] }
        var out: [Int32: [Int32]] = [:]
        for (pid, e) in table where e.uid == uid && e.ppid == 1 {
            let r = f(pid)
            if r > 0, r != pid { out[r, default: []].append(pid) }
        }
        return out
    }

    /// The program's arguments (KERN_PROCARGS2), without the executable path; nil when unreadable.
    public static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// An agent process: by name, or a Node.js process running Claude Code (installed with npm, it runs as "node").
    public static func isAgent(_ e: ProcessEntry) -> Bool {
        if FreezePlanner.agentNames.contains(e.name) { return true }
        guard e.name == "node" else { return false }
        return arguments(of: e.pid)?.contains { $0.contains("claude-code") || $0.hasSuffix("/claude") } ?? false
    }
}

/// Freezes and thaws, keeping the record. Use from one thread (the app's main thread).
public final class Freezer {
    public let recordURL: URL
    public private(set) var frozen: [FrozenProcess] = []
    public var log: (String) -> Void = { _ in }

    public init(recordURL: URL) {
        self.recordURL = recordURL
    }

    /// The apps frozen right now, by name.
    public var frozenApps: [String] { Array(Set(frozen.map(\.app))).sorted() }

    /// Takes over entries of the record that aren't in memory (an earlier run that ended without thawing).
    @discardableResult
    public func adoptRecord() -> Int {
        guard let record = FrozenRecord.read(recordURL) else { return 0 }
        let known = Set(frozen.map(\.key))
        let extra = record.processes.filter { !known.contains($0.key) }
        frozen.append(contentsOf: extra)
        return extra.count
    }

    /// Freezes the targets' processes that aren't frozen yet. The record is written before any signal; if it can't
    /// be written, nothing freezes. Returns the number of processes stopped.
    @discardableResult
    public func freeze(_ targets: [FreezeTarget]) -> Int {
        let known = Set(frozen.map(\.key))
        var added: [FrozenProcess] = []
        for t in targets {
            for p in t.processes where !p.stopped {
                let f = FrozenProcess(p, app: t.app)
                if !known.contains(f.key) && !added.contains(where: { $0.key == f.key }) { added.append(f) }
            }
        }
        guard !added.isEmpty else { return 0 }
        guard persist(frozen + added) else {
            log("freezer: the record can't be written, nothing frozen")
            return 0
        }
        frozen.append(contentsOf: added)
        var stopped = 0
        var dropped = Set<String>()
        for p in added {
            guard kill(p.pid, SIGSTOP) == 0 else { dropped.insert(p.key); continue }
            // Was it really that process? (A pid can be reused between the table and the signal.)
            if let s = ProcessTable.startTime(p.pid), s.sec == p.startSec, s.usec == p.startUsec {
                stopped += 1
            } else {
                kill(p.pid, SIGCONT)
                dropped.insert(p.key)
            }
        }
        if !dropped.isEmpty {
            frozen.removeAll { dropped.contains($0.key) }
            persist(frozen)
        }
        let apps = Array(Set(added.filter { !dropped.contains($0.key) }.map(\.app))).sorted()
        if stopped > 0 { log("froze \(apps.count) apps, \(stopped) processes (\(apps.joined(separator: ", ")))") }
        return stopped
    }

    /// Continues everything in memory and in the record. Returns the number of processes continued.
    @discardableResult
    public func thawAll(reason: String) -> Int {
        adoptRecord()
        guard !frozen.isEmpty else { return 0 }
        let table = ProcessTable.snapshot()
        var continued = 0
        let before = frozen.count
        let remaining = FrozenRecord.remainingAfterThaw(frozen, table: table) { pid in
            let ok = kill(pid, SIGCONT) == 0
            if ok { continued += 1 }
            return ok
        }
        frozen = remaining
        persist(frozen)
        // Retried every tick while something is left: say so only when something changed.
        if continued > 0 || remaining.count != before {
            log("thawed (\(reason)): \(continued) processes" + (remaining.isEmpty ? "" : ", \(remaining.count) left for the next try"))
        }
        return continued
    }

    @discardableResult
    private func persist(_ list: [FrozenProcess]) -> Bool {
        let ok = FrozenRecord(owner: ProcessIdentity.current, processes: list).write(recordURL)
        FreezerCrashGuard.update(list.map(\.pid))
        return ok
    }

    /// For aos-session (and anyone else): thaws a record whose owner is gone (aOS crashed or was killed) and removes
    /// it. Returns the number of processes continued; nil when there was nothing to do.
    @discardableResult
    public static func thawOrphans(recordURL: URL, log: (String) -> Void = { _ in }) -> Int? {
        guard let record = FrozenRecord.read(recordURL), !record.processes.isEmpty else { return nil }
        if let owner = record.owner, owner.isAlive { return nil }
        let table = ProcessTable.snapshot()
        var continued = 0
        let remaining = FrozenRecord.remainingAfterThaw(record.processes, table: table) { pid in
            let ok = kill(pid, SIGCONT) == 0
            if ok { continued += 1 }
            return ok
        }
        FrozenRecord(owner: nil, processes: remaining).write(recordURL)
        log("thawed \(continued) processes that aOS had frozen (aOS is no longer running)")
        return continued
    }
}

/// The last line of defense: if aOS crashes while apps are frozen, a signal handler continues them before the
/// process dies. It only calls kill(2), which is safe in a signal handler, on a fixed buffer of pids. Sending SIGCONT
/// to a pid that was reused in the meantime does nothing to a running process.
public enum FreezerCrashGuard {
    private static let capacity = 4096
    private static let pids: UnsafeMutablePointer<pid_t> = {
        let p = UnsafeMutablePointer<pid_t>.allocate(capacity: capacity)
        p.initialize(repeating: 0, count: capacity)
        return p
    }()
    /// How many entries of `pids` are valid (lock-free, so the signal handler may read it).
    private static let count = Atomic<Int>(0)
    private static let installed = Atomic<Bool>(false)

    /// The pids that are frozen now (call from the thread that freezes).
    public static func update(_ list: [pid_t]) {
        count.store(0, ordering: .sequentiallyConsistent)
        let n = min(list.count, capacity)
        for i in 0..<n { pids[i] = list[i] }
        count.store(n, ordering: .sequentiallyConsistent)
    }

    /// Installs the handler for the crash signals (once).
    public static func install() {
        guard !installed.exchange(true, ordering: .sequentiallyConsistent) else { return }
        // Initialized here, not lazily inside a signal handler.
        _ = pids
        _ = count.load(ordering: .relaxed)
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP, SIGSYS] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { sig in
                FreezerCrashGuard.continueAll()
                // SA_RESETHAND restored the default action: the fault happens again and ends the process as before.
                _ = sig
            }
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_RESETHAND
            sigaction(sig, &action, nil)
        }
    }

    private static func continueAll() {
        let n = count.load(ordering: .sequentiallyConsistent)
        for i in 0..<min(n, capacity) where pids[i] > 1 { kill(pids[i], SIGCONT) }
    }
}
