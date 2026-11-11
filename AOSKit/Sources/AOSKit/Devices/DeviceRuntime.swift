import CryptoKit
import Foundation

/// The Python environment of the device worker (`Devices/env`): pymobiledevice3 with exactly the versions and hashes of
/// App/Resources/aos-devices-requirements.txt, on a Python that uv installs (python-build-standalone, its own OpenSSL:
/// the tunnel needs TLS-PSK). uv comes from Astral's release with a pinned checksum; nothing else of the person's
/// (Homebrew, their own Python) is used or changed.
public enum DeviceRuntime {
    public static let uvVersion = "0.12.10"
    public static let uvSHA256 = "51c6170e8e3a01cef9f33b94f582b7b81ac65046f55d40afb35f9cff5a68c179"
    public static let pythonVersion = "3.13"
    static let uvDownload = URL(string: "https://github.com/astral-sh/uv/releases/download/\(uvVersion)/uv-aarch64-apple-darwin.tar.gz")!

    public static func environment(_ paths: Paths) -> URL { paths.devices.appendingPathComponent("env", isDirectory: true) }
    public static func python(_ paths: Paths) -> URL { environment(paths).appendingPathComponent("bin/python3") }
    public static func uv(_ paths: Paths) -> URL { paths.bin.appendingPathComponent("uv") }
    static func marker(_ paths: Paths) -> URL { environment(paths).appendingPathComponent(".aos-requirements") }

    /// The requirements and the worker shipped with this version of aOS (in the app's Resources folder).
    public static func requirements(in resources: URL) -> URL { resources.appendingPathComponent("aos-devices-requirements.txt") }
    public static func worker(in resources: URL) -> URL { resources.appendingPathComponent("aos-devices-worker.py") }
    /// The setup's helper: trust, Developer Mode and the RemotePairing record on the iPhone (one JSON answer per call).
    public static func setupHelper(in resources: URL) -> URL { resources.appendingPathComponent("aos-devices-setup.py") }
    /// The app's Resources folder, seen from a program in its Contents/MacOS.
    public static func appResources(executable: URL) -> URL {
        executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
    }

    /// The environment exists and has the packages of `requirements`.
    public static func isReady(_ paths: Paths, requirements: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python(paths).path),
              let wanted = try? digest(of: requirements),
              let have = try? String(contentsOf: marker(paths), encoding: .utf8) else { return false }
        return have.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
    }

    static func digest(of file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    public enum SetupError: LocalizedError {
        case download(String)
        case checksum
        case step(String, String)

        public var errorDescription: String? {
            switch self {
            case .download(let why): return "uv could not be downloaded: \(why)"
            case .checksum: return "The downloaded uv doesn't match its checksum; nothing was installed."
            case .step(let what, let output): return "\(what) failed: \(output)"
            }
        }
    }

    /// The steps of the setup, for the app to show.
    public enum Step: Sendable {
        case downloadingUV, installingPython, creatingEnvironment, installingPackages, ready
    }

    /// Downloads uv (checked), installs Python and the packages. Takes a minute or two; downloads about 80 MB.
    public static func setUp(_ paths: Paths, requirements: URL, progress: @escaping @Sendable (Step) -> Void) async throws {
        try paths.prepare()
        progress(.downloadingUV)
        let uv = try await installUV(paths)
        let env = toolEnvironment(paths)
        progress(.installingPython)
        try await step("Installing Python", uv.path, ["python", "install", pythonVersion], env: env)
        progress(.creatingEnvironment)
        try? FileManager.default.removeItem(at: environment(paths))
        try await step("Creating the environment", uv.path,
                       ["venv", "--python", pythonVersion, "--python-preference", "only-managed", environment(paths).path],
                       env: env)
        progress(.installingPackages)
        try await step("Installing pymobiledevice3", uv.path,
                       ["pip", "install", "--python", python(paths).path, "--require-hashes", "--no-deps", "-r",
                        requirements.path], env: env)
        try await step("Checking the environment", python(paths).path,
                       ["-I", "-c", "import pymobiledevice3.remote.userspace_tunnel"], env: env)
        try digest(of: requirements).write(to: marker(paths), atomically: true, encoding: .utf8)
        progress(.ready)
    }

    /// uv's own settings only: no config files of the person's, its downloads and cache inside aOS's folder.
    static func toolEnvironment(_ paths: Paths) -> [String: String] {
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                   "UV_NO_CONFIG": "1",
                   "UV_CACHE_DIR": paths.devices.appendingPathComponent("cache").path,
                   "UV_PYTHON_INSTALL_DIR": paths.devices.appendingPathComponent("python").path,
                   "UV_PYTHON_PREFERENCE": "only-managed"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        return env
    }

    private static func step(_ what: String, _ path: String, _ args: [String], env: [String: String]) async throws {
        let result = try await Subprocess.run(path, args, environment: env, timeout: 900)
        guard result.status == 0, !result.timedOut else {
            let output = String(decoding: result.stderr + result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).suffix(600)
            throw SetupError.step(what, String(output))
        }
    }

    /// uv in `bin/uv`, downloaded once and checked against the pinned checksum (it is only ad-hoc signed).
    static func installUV(_ paths: Paths) async throws -> URL {
        let target = uv(paths)
        let stamp = target.appendingPathExtension("sha256")
        if FileManager.default.isExecutableFile(atPath: target.path),
           (try? String(contentsOf: stamp, encoding: .utf8)) == uvSHA256 {
            return target
        }
        let (file, response): (URL, URLResponse)
        do {
            (file, response) = try await URLSession.shared.download(from: uvDownload)
        } catch {
            throw SetupError.download(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SetupError.download("HTTP error") }
        guard try digest(of: file) == uvSHA256 else { throw SetupError.checksum }
        let unpack = paths.devices.appendingPathComponent("uv-unpack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unpack, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unpack) }
        let untar = try await Subprocess.run("/usr/bin/tar", ["-xzf", file.path, "-C", unpack.path], timeout: 120)
        guard untar.status == 0 else { throw SetupError.download("the archive could not be opened") }
        let binary = unpack.appendingPathComponent("uv-aarch64-apple-darwin/uv")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: binary, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        try uvSHA256.write(to: stamp, atomically: true, encoding: .utf8)
        return target
    }
}
