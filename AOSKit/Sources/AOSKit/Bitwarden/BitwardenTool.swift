import Darwin
import Foundation
import Security

/// Bitwarden's command line tool on this Mac: Bitwarden's own build, either the user's (found on the PATH) or
/// downloaded by aOS from Bitwarden into ~/Library/Application Support/aOS/bin. aOS never ships it and never links
/// it. Whatever aOS runs is checked first: a Developer ID signature of Bitwarden Inc (team LTZ2PFU5D6), strictly
/// validated by macOS's code signing for every architecture in the file.
public enum BitwardenTool {
    /// Bitwarden Inc's Apple team: its Developer ID signs the command line tool (and the desktop app).
    public static let teamIdentifier = "LTZ2PFU5D6"
    /// Bitwarden's official download link for the macOS command line tool (bitwarden.com/help/cli). It points to the
    /// newest release on GitHub.
    public static let downloadLink = URL(string: "https://vault.bitwarden.com/download/?app=cli&platform=macos")!
    /// Larger downloads are refused (the tool is about 45 MB).
    static let maximumDownload = 300 * 1024 * 1024

    public struct Located: Equatable, Sendable {
        public var path: String
        /// aOS downloaded it into its own folder; otherwise it is the user's own `bw`.
        public var downloaded: Bool
    }

    /// Where aOS keeps the tool it downloaded.
    public static func installedPath(_ paths: Paths) -> String { paths.bin.appendingPathComponent("bw").path }

    /// The tool to use, checked: the user's own `bw` if it is Bitwarden's signed build, else the one aOS downloaded.
    /// nil when there is none (yet). Hashes the file (about 100 MB): call it off the main thread.
    public static func locate(_ paths: Paths) -> Located? {
        for candidate in userCandidates() {
            guard let real = resolved(candidate), verify(real) == nil else { continue }
            return Located(path: real, downloaded: false)
        }
        let own = installedPath(paths)
        if FileManager.default.isExecutableFile(atPath: own), verify(own) == nil {
            return Located(path: own, downloaded: true)
        }
        return nil
    }

    /// `bw` in the usual places of a Mac (the app doesn't get the user's shell PATH).
    static func userCandidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin"]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && $0.hasPrefix("/") && seen.insert($0).inserted }
            .map { "\($0)/bw" }
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The file a path stands for (links resolved), if it is a regular file.
    static func resolved(_ path: String) -> String? {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var info = stat()
        guard lstat(real, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return real
    }

    // MARK: Signature

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var checked: [String: (stamp: String, problem: String?)] = [:]

    /// nil when `path` is a program signed with Bitwarden Inc's Developer ID (team `team`) whose signature holds
    /// for all of it; otherwise why not. The result is kept while the file stays the same: inode, size, change
    /// time and status change time. The latter can't be set back by a program (any write or `touch` moves it), so
    /// an edit in place that restores size and change time is checked again.
    public static func verify(_ path: String, team: String = teamIdentifier) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return "not a file" }
        let stamp = "\(team) \(info.st_dev) \(info.st_ino) \(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
            + " \(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
        if let hit = cacheLock.withLock({ checked[path] }), hit.stamp == stamp { return hit.problem }
        let problem = checkSignature(path, requirement: developerIDRequirement(team: team))
        cacheLock.withLock { checked[path] = (stamp, problem) }
        return problem
    }

    /// Apple's rule for a Developer ID application signature of one team.
    static func developerIDRequirement(team: String) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Checks the code signature of a file against a requirement: nil when it holds.
    static func checkSignature(_ path: String, requirement text: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return "no code signature" }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return "bad requirement"
        }
        var error: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        if status == errSecSuccess { return nil }
        error?.release()
        switch status {
        case errSecCSUnsigned: return "not signed"
        case errSecCSReqFailed: return "not signed by Bitwarden"
        default: return "signature not valid (\(status))"
        }
    }

    // MARK: Download

    public enum InstallError: LocalizedError {
        case noRelease(String)
        case download(String)
        case notBitwarden(String)

        public var errorDescription: String? {
            switch self {
            case .noRelease(let detail): return "Bitwarden's download link didn't lead to a release (\(detail))."
            case .download(let detail): return "Bitwarden's command line tool could not be downloaded (\(detail))."
            case .notBitwarden(let detail): return "The download isn't Bitwarden's signed command line tool (\(detail)); it was deleted."
            }
        }
    }

    /// Downloads Bitwarden's newest command line tool for macOS (the Apple silicon build where there is one),
    /// checks its signature and puts it into aOS's folder. Nothing that fails the check stays on disk.
    /// `shared`: for aOS's helper (root): folder and tool executable for everyone (0755, owned by root, so only root
    /// can change them), because `bw` then runs as the helper's hidden user.
    public static func install(_ paths: Paths, shared: Bool = false) async throws -> Located {
        let mode: Int = shared ? 0o755 : 0o700
        let candidates = try await releaseDownloads()
        let fm = FileManager.default
        try fm.createDirectory(at: paths.bin, withIntermediateDirectories: true, attributes: [.posixPermissions: mode])
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: paths.bin.path)
        let work = paths.bin.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        var lastError: Error = InstallError.noRelease("no file")
        for url in candidates {
            do {
                let zip = try await download(url, into: work)
                let folder = work.appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let unzip = try await Subprocess.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path], timeout: 180)
                guard unzip.status == 0 else { throw InstallError.download("the archive could not be opened") }
                let tool = folder.appendingPathComponent("bw")
                guard resolved(tool.path) == tool.path else { throw InstallError.download("no bw in the archive") }
                if let problem = verify(tool.path) { throw InstallError.notBitwarden(problem) }
                // Into place in one step (rename in the same folder), executable for the user only.
                let target = URL(fileURLWithPath: installedPath(paths))
                let staged = paths.bin.appendingPathComponent(".bw-\(UUID().uuidString)")
                try fm.moveItem(at: tool, to: staged)
                try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: staged.path)
                guard rename(staged.path, target.path) == 0 else {
                    try? fm.removeItem(at: staged)
                    throw InstallError.download("could not put it in place (\(String(cString: strerror(errno))))")
                }
                if let problem = verify(target.path) {
                    try? fm.removeItem(at: target)
                    throw InstallError.notBitwarden(problem)
                }
                return Located(path: target.path, downloaded: true)
            } catch let error as InstallError {
                if case .notBitwarden = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// The files to try, best first: Bitwarden's link names the newest release's Intel build
    /// (`.../cli-v<version>/bw-macos-<version>.zip`); the same release has `bw-macos-arm64-<version>.zip`.
    static func releaseDownloads() async throws -> [URL] {
        var url = downloadLink
        for _ in 0..<5 {
            guard let next = try await redirect(from: url) else { throw InstallError.noRelease("no redirect") }
            guard next.scheme?.lowercased() == "https", let host = next.host?.lowercased() else {
                throw InstallError.noRelease("not https")
            }
            if host == "github.com" { return try downloads(forRelease: next) }
            guard host == "bitwarden.com" || host.hasSuffix(".bitwarden.com") else {
                throw InstallError.noRelease("unexpected host \(host)")
            }
            url = next
        }
        throw InstallError.noRelease("too many redirects")
    }

    /// The release's builds for this Mac, from the release file Bitwarden's link names.
    static func downloads(forRelease url: URL, arm64: Bool = isAppleSilicon) throws -> [URL] {
        let pattern = #"^/bitwarden/clients/releases/download/cli-v([0-9]+\.[0-9]+\.[0-9]+)/bw-macos-([0-9]+\.[0-9]+\.[0-9]+)\.zip$"#
        guard url.host?.lowercased() == "github.com", let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: url.path, range: NSRange(url.path.startIndex..., in: url.path)),
              let tag = Range(match.range(at: 1), in: url.path), let file = Range(match.range(at: 2), in: url.path),
              url.path[tag] == url.path[file] else {
            throw InstallError.noRelease("unexpected file \(url.path.prefix(120))")
        }
        let version = String(url.path[tag])
        let base = "https://github.com/bitwarden/clients/releases/download/cli-v\(version)/"
        var list: [URL] = []
        if arm64 { list.append(URL(string: base + "bw-macos-arm64-\(version).zip")!) }
        list.append(URL(string: base + "bw-macos-\(version).zip")!)
        return list
    }

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Where a link points, without following it.
    private static func redirect(from url: URL) async throws -> URL? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request, delegate: NoRedirects())
        } catch {
            throw InstallError.noRelease(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location") else { return nil }
        return URL(string: location, relativeTo: url)?.absoluteURL
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// Downloads one file over https (GitHub hands release files out from its own storage hosts).
    private static func download(_ url: URL, into folder: URL) async throws -> URL {
        let (file, response): (URL, URLResponse)
        do {
            (file, response) = try await URLSession.shared.download(from: url)
        } catch {
            throw InstallError.download(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw InstallError.download("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(url.lastPathComponent)")
        }
        if let final = http.url?.host?.lowercased(), final != "github.com", !final.hasSuffix(".githubusercontent.com") {
            throw InstallError.download("unexpected host \(final)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size > 0, size <= maximumDownload else { throw InstallError.download("unexpected size \(size)") }
        let zip = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: zip)
        return zip
    }
}
