import AnnexKit
import Foundation

// Keeps the Claude Code session running (started by launchd as a LaunchAgent of the app, see
// App/LaunchAgents). SIGTERM ends the session too.
let paths = Paths.default
try? paths.prepare()
// Log to Logs/session.log (kept short: the old log moves aside when it passes 2 MB).
let logURL = paths.logs.appendingPathComponent("session.log")
if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 2_000_000 {
    try? FileManager.default.removeItem(at: logURL.appendingPathExtension("old"))
    try? FileManager.default.moveItem(at: logURL, to: logURL.appendingPathExtension("old"))
}
freopen(logURL.path, "a", stderr)
setvbuf(stderr, nil, _IOLBF, 0)
let supervisor = SessionSupervisor(paths: paths)
supervisor.log = { line in
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(line)\n".utf8))
}
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler {
    supervisor.stop()
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
}
term.resume()
supervisor.run()
dispatchMain()
