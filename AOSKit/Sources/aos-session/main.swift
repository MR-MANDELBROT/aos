import AOSKit
import Foundation

// Keeps the Claude Code session running, the conversations the user wants reachable, and Claude Code's server mode
// for new chats from the Claude app (started by launchd as a LaunchAgent of the app, see App/LaunchAgents).
// SIGTERM ends them too.
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
let keeper = SessionKeeper(paths: paths)
keeper.log = supervisor.log
let remote = RemoteServer(paths: paths)
remote.log = supervisor.log
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler {
    supervisor.stop()
    keeper.stopAll()
    remote.stop()
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
}
term.resume()
// With the lid closed aOS freezes other apps (SIGSTOP). Should aOS end without continuing them (a crash, a kill),
// they would stay stopped: every 15 s a record whose owner process is gone gets thawed here.
let frozenRecord = FrozenRecord.url(paths)
let thawWatch = DispatchSource.makeTimerSource(queue: .main)
thawWatch.schedule(deadline: .now() + 3, repeating: 15, leeway: .seconds(2))
thawWatch.setEventHandler { Freezer.thawOrphans(recordURL: frozenRecord, log: supervisor.log) }
thawWatch.resume()
supervisor.run()
keeper.run()
remote.run()
dispatchMain()
