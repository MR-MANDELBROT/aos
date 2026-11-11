import Foundation

/// The person's own Tailscale app on this Mac (the Mac App Store app, the standalone app, or Tailscale's open source
/// `tailscale` with its daemon). aOS only reads its status with `tailscale status --json`, as the person, and never
/// changes anything of it: not its settings, not its sign-in.
public enum TailscaleApp {
    /// The command line tools to ask, in order: the app's own executable (it answers commands when it gets
    /// arguments), the command Tailscale installs, Homebrew's.
    public static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    /// The first command line tool that exists.
    public static func commandLineTool(exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
        -> String? {
        candidates.first(where: exists)
    }

    /// What the Tailscale app on this Mac reports now.
    public static func read(timeout: TimeInterval = 8) async -> TailscaleAppState {
        guard let tool = commandLineTool() else { return .notInstalled }
        do {
            let result = try await Subprocess.run(tool, ["status", "--json"], environment: environment, timeout: timeout)
            return state(stdout: result.stdout, exitStatus: result.status, timedOut: result.timedOut)
        } catch {
            return .notConnected(nil)
        }
    }

    /// A small environment: the tool needs nothing of aOS's. TAILSCALE_BE_CLI: without a terminal's environment the
    /// app's binary takes itself for an app launch ("The Tailscale GUI failed to start", Tailscale 1.102).
    static var environment: [String: String] {
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TAILSCALE_BE_CLI": "1"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        return env
    }

    /// The state for what `tailscale status --json` printed. It exits with an error while the app isn't running
    /// (and prints no JSON); a JSON status says whether it is signed in and connected.
    public static func state(stdout: Data, exitStatus: Int32, timedOut: Bool) -> TailscaleAppState {
        guard !timedOut else { return .notConnected(nil) }
        // Some versions print a line (an update notice) before the JSON.
        let json = stdout.firstIndex(of: UInt8(ascii: "{")).map { stdout[$0...] } ?? stdout
        guard let status = try? TailnetStatus(json: Data(json)) else { return .notConnected(nil) }
        guard status.isRunning, status.device != nil else { return .notConnected(status.backendState) }
        return .connected(status)
    }
}
