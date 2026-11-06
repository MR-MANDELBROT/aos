import Foundation

/// Where the app runs from. aOS registers its programs by path (the MCP tool with the agents, aos-companion with
/// the paired iPhones, the background session as a login item), so it has to live in an Applications folder: not on
/// the disk image it came on, not in Downloads, not in the read-only copy Gatekeeper runs a quarantined app from.
public enum AppLocation {
    /// In /Applications or ~/Applications (or a folder below them), and not translocated.
    public static func isStable(_ app: URL) -> Bool {
        guard !isTranslocated(app) else { return false }
        let path = app.resolvingSymlinksInPath().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// A development build (run from Xcode's build folder): never moved.
    public static func isDevelopmentBuild(_ app: URL) -> Bool {
        app.path.contains("/DerivedData/") || app.path.contains("/Build/Products/")
            || ProcessInfo.processInfo.environment["AOS_STAY"] != nil
    }

    public static func isTranslocated(_ app: URL) -> Bool { app.path.contains("/AppTranslocation/") }

    /// The original place of a translocated app (Gatekeeper's SecTranslocate, loaded at run time).
    public static func originalURL(_ app: URL) -> URL {
        guard isTranslocated(app),
              let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return app }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let original = unsafeBitCast(symbol, to: Original.self)
        guard let url = original(app as CFURL, nil)?.takeRetainedValue() else { return app }
        return url as URL
    }

    /// Where the app goes: /Applications when this account may write there, otherwise ~/Applications.
    public static func destinationFolder() -> URL {
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: system.path) { return system }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    }

    public struct Move: Sendable {
        /// The app in its new place.
        public var app: URL
        /// The disk image the app came on (to eject after the relaunch), if any.
        public var diskImage: URL?
    }

    public enum MoveError: LocalizedError {
        case copy(String)
        public var errorDescription: String? {
            switch self { case .copy(let s): return "aOS could not be copied to the Applications folder: \(s)" }
        }
    }

    /// Copies the running app into the Applications folder. An older copy there goes to the Trash first. The copy
    /// loses its quarantine flag (the user already opened this app; with the flag, Gatekeeper would run the copy from
    /// a random place again). The original goes to the Trash, unless it is on a read-only volume such as the disk
    /// image.
    public static func moveToApplications(_ running: URL = Bundle.main.bundleURL) throws -> Move {
        let fm = FileManager.default
        let source = originalURL(running)
        let folder = destinationFolder()
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: target.path) {
            do { try fm.trashItem(at: target, resultingItemURL: nil) } catch {
                throw MoveError.copy("the older copy could not be moved to the Trash (\(error.localizedDescription))")
            }
        }
        let copy = try Subprocess.runBlocking("/usr/bin/ditto", [source.path, target.path], timeout: 300)
        guard copy.status == 0 else {
            let why = String(decoding: copy.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MoveError.copy(why.isEmpty ? "ditto ended with status \(copy.status)" : why)
        }
        _ = try? Subprocess.runBlocking("/usr/bin/xattr", ["-d", "-r", "com.apple.quarantine", target.path], timeout: 60)

        let values = try? source.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeURLKey])
        let readOnly = values?.volumeIsReadOnly ?? false
        var diskImage: URL?
        if readOnly, let volume = values?.volume, volume.path.hasPrefix("/Volumes/") {
            diskImage = volume
        } else if !readOnly {
            try? fm.trashItem(at: source, resultingItemURL: nil)
        }
        return Move(app: target, diskImage: diskImage)
    }

    /// Opens the moved app once this process has ended, then ejects the disk image it came on.
    public static func relaunch(_ move: Move) {
        var script = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\""
        var args = ["/bin/sh", "-c", "", "aos-relaunch", String(getpid()), move.app.path]
        if let image = move.diskImage {
            script += "; /bin/sleep 2; /usr/bin/hdiutil detach \"$3\" -quiet"
            args.append(image.path)
        }
        args[2] = script
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
