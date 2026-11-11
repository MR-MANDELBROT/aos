import AOSKit
import Darwin
import Foundation

// Keeps the device worker running: it holds a tunnel to the person's iPhone and installs apps through it (started by
// launchd as a LaunchAgent of the app, see App/LaunchAgents and Docs/DESIGN.md, "Installing apps on the iPhone").
// The worker survives updates of aOS while its tunnel holds; this program does too (a new version of it starts at the
// next login or when the person turns the feature off and on).
let paths = Paths.default
try? paths.prepare()
let logURL = paths.logs.appendingPathComponent("devices.log")
if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 2_000_000 {
    try? FileManager.default.removeItem(at: logURL.appendingPathExtension("old"))
    try? FileManager.default.moveItem(at: logURL, to: logURL.appendingPathExtension("old"))
}
freopen(logURL.path, "a", stderr)
setvbuf(stderr, nil, _IOLBF, 0)
let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
let resources = ProcessInfo.processInfo.environment["AOS_DEVICES_RESOURCES"].map { URL(fileURLWithPath: $0) }
    ?? DeviceRuntime.appResources(executable: executable)
let supervisor = DeviceWorkerSupervisor(paths: paths, resources: resources)
supervisor.log = { line in
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) aos-devices: \(line)\n".utf8))
}
supervisor.log("started, resources \(resources.path)")
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { supervisor.stop { exit(0) } }
term.resume()
supervisor.run()
dispatchMain()
