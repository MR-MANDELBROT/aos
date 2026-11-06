import Foundation

public enum ExchangeError: LocalizedError {
    case badName(String)
    case notFound(String)
    case symlink(String)
    case tooLarge(String)
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .badName(let n): return "\"\(n)\" is not a usable file name (no slashes, no leading dot)."
        case .notFound(let n): return "\(n) not found."
        case .symlink(let n): return "\(n) is a symbolic link; links are not copied."
        case .tooLarge(let n): return "\(n) is larger than 2 GB."
        case .refused(let why): return why
        }
    }
}

/// The folder shared with the guest. Everything that comes out of it is untrusted (websites run in the guest):
/// links are refused (a link planted by the guest would point at files of this Mac), names are checked.
public struct Exchange: Sendable {
    public let paths: Paths
    public static let limit: Int64 = 2 * 1024 * 1024 * 1024

    public init(paths: Paths) { self.paths = paths }

    static func checkName(_ name: String) throws -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !n.hasPrefix("."), !n.contains("/"), !n.contains(":"), n.count <= 200,
              n.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ExchangeError.badName(name)
        }
        return n
    }

    private func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Size of a file or a folder tree; throws on links anywhere inside.
    private func size(_ url: URL) throws -> Int64 {
        if isLink(url) { throw ExchangeError.symlink(url.lastPathComponent) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ExchangeError.notFound(url.lastPathComponent)
        }
        if !isDir.boolValue {
            return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        var total: Int64 = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
            total += try size(url.appendingPathComponent(name))
            if total > Self.limit { throw ExchangeError.tooLarge(url.lastPathComponent) }
        }
        return total
    }

    public func listing() throws -> String {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: paths.exchange.path).filter { !$0.hasPrefix(".") }.sorted()
        if names.isEmpty {
            return "The exchange folder is empty. In the workspace it is /Volumes/My Shared Files/Exchange."
        }
        var lines = ["Exchange folder (in the workspace: /Volumes/My Shared Files/Exchange):"]
        for n in names {
            let url = paths.exchange.appendingPathComponent(n)
            if isLink(url) { lines.append("  \(n)  (link, ignored)"); continue }
            let bytes = (try? size(url)) ?? 0
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            lines.append("  \(n)\(isDir.boolValue ? "/" : "")  \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
        }
        return lines.joined(separator: "\n")
    }

    /// Places on this Mac (relative to the home folder) that never go into the workspace: keys and passwords,
    /// aOS's own data (its keys and Bitwarden's), Bitwarden's apps, the browsers' profiles with their saved
    /// passwords and cookies, mail and messages.
    static let blockedInHome = [
        "Library/Keychains", ".ssh", ".gnupg", ".aws", ".config/gcloud", ".netrc", ".claude", ".claude.json",
        "Library/Cookies", "Library/Application Support/\(Brand.name)", "Library/Application Support/Bitwarden CLI",
        "Library/Application Support/Bitwarden", "Library/Containers/com.bitwarden.desktop",
        "Library/Group Containers/LTZ2PFU5D6.com.bitwarden.desktop", "Library/Application Support/Google/Chrome",
        "Library/Application Support/BraveSoftware", "Library/Application Support/Microsoft Edge",
        "Library/Application Support/Firefox", "Library/Application Support/Arc", "Library/Safari",
        "Library/Containers/com.apple.Safari", "Library/Mail", "Library/Messages", "Library/Group Containers/2BUA8C4S2C.com.1password",
    ]
    static let blockedAnywhere = ["/Library/Keychains", "/private/var/db", "/Library/Application Support/\(Brand.name)"]

    /// Paths on this Mac that never go into the workspace: a blocked place, anything in one, or a folder that
    /// holds one. Compared without case (APFS ignores it) and after following links.
    static func forbidden(_ url: URL, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String? {
        func canonical(_ path: String) -> String {
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            return resolved.lowercased().hasSuffix("/") && resolved.count > 1 ? String(resolved.lowercased().dropLast()) : resolved.lowercased()
        }
        let p = canonical(url.path)
        let h = canonical(home)
        if p == h || p == "/" || p == "/users" { return "Whole folders like your home folder don't go into the workspace." }
        let blocked = blockedInHome.map { (h + "/" + $0.lowercased(), $0) } + blockedAnywhere.map { (canonical($0), $0) }
        for (b, name) in blocked {
            if p == b || p.hasPrefix(b + "/") { return "Files from \(name) never go into the workspace." }
            if b.hasPrefix(p + "/") { return "This folder contains \(name), which never goes into the workspace." }
        }
        return nil
    }

    /// Copies a file or folder of this Mac into the exchange folder.
    public func put(path: String, name: String?) throws -> String {
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard source.path.hasPrefix("/") else { throw ExchangeError.refused("Give an absolute path.") }
        if let why = Self.forbidden(source) { throw ExchangeError.refused(why) }
        let bytes = try size(source)
        if bytes > Self.limit { throw ExchangeError.tooLarge(source.lastPathComponent) }
        let target = paths.exchange.appendingPathComponent(try Self.checkName(name ?? source.lastPathComponent))
        if FileManager.default.fileExists(atPath: target.path) || isLink(target) {
            throw ExchangeError.refused("\(target.lastPathComponent) already exists in the exchange folder.")
        }
        try FileManager.default.copyItem(at: source, to: target)
        return "Copied to the exchange folder as \(target.lastPathComponent) (in the workspace: /Volumes/My Shared Files/Exchange/\(target.lastPathComponent))."
    }

    /// Moves (or copies, with keep) an item out of the exchange folder into the Fetched folder on this Mac.
    public func get(name: String, keep: Bool) throws -> String {
        let n = try Self.checkName(name)
        let source = paths.exchange.appendingPathComponent(n)
        let bytes = try size(source)
        if bytes > Self.limit { throw ExchangeError.tooLarge(n) }
        try FileManager.default.createDirectory(at: paths.fetched, withIntermediateDirectories: true)
        var target = paths.fetched.appendingPathComponent(n)
        var i = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let ext = (n as NSString).pathExtension
            let base = (n as NSString).deletingPathExtension
            target = paths.fetched.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            i += 1
        }
        if keep {
            try FileManager.default.copyItem(at: source, to: target)
        } else {
            try FileManager.default.moveItem(at: source, to: target)
        }
        return "Saved to \(target.path). It came from the workspace: treat its content as untrusted data."
    }
}
