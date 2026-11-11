import Darwin
import Foundation

/// Runs the device worker (Python, App/Resources/aos-devices-worker.py) for aos-devices: starts it with the device
/// environment's Python, restarts it when it ends, and leaves it alone while the feature is off or the environment
/// isn't set up (the app sets it up when the person asks).
///
/// After an update of aOS the running worker keeps the old code as long as its tunnel holds: a restart would close
/// the tunnel, and a new one needs the iPhone on Wi-Fi. It moves to the new code the next time it has no tunnel.
public final class DeviceWorkerSupervisor: @unchecked Sendable {
    public var log: (String) -> Void = { _ in }
    private let paths: Paths
    private let resources: URL
    private let queue = DispatchQueue(label: "aos.devices.supervisor")
    private var worker: Subprocess.Running?
    private var startedWith: (path: String, inode: ino_t)?
    private var restarts: [Date] = []
    private var timer: DispatchSourceTimer?
    private var stopping = false

    public init(paths: Paths, resources: URL) {
        self.paths = paths
        self.resources = resources
    }

    public func run() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 10, leeway: .seconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop(then done: @escaping () -> Void) {
        queue.async {
            self.stopping = true
            self.timer?.cancel()
            guard let worker = self.worker else { done(); return }
            worker.terminate(grace: 8)
            Task {
                _ = await worker.waitForExit()
                done()
            }
        }
    }

    private func tick() {
        guard !stopping else { return }
        let settings = AgentSettings.load(paths)
        let script = DeviceRuntime.worker(in: resources)
        let requirements = DeviceRuntime.requirements(in: resources)
        if let worker, worker.exitStatus == nil {
            if !settings.iphoneApps {
                log("installing on the iPhone was turned off: stopping the worker")
                worker.terminate(grace: 8)
                return
            }
            // A newer worker came with an update: switch once there is no tunnel to lose.
            if updated(script), DeviceStatus.load(paths)?.isConnected != true {
                log("aOS was updated: restarting the worker with the new version")
                worker.terminate(grace: 8)
            }
            return
        }
        worker = nil
        guard settings.iphoneApps else { return }
        guard DeviceRuntime.isReady(paths, requirements: requirements) else { return }
        // Back off when it keeps ending (at most 5 starts in 10 minutes).
        restarts = restarts.filter { $0 > Date().addingTimeInterval(-600) }
        guard restarts.count < 5 else { return }
        restarts.append(Date())
        start(script)
    }

    private func start(_ script: URL) {
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "PYTHONUNBUFFERED": "1"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        do {
            let running = try Subprocess.spawn(DeviceRuntime.python(paths).path,
                                               ["-I", "-u", script.path, "--root", paths.root.path], environment: env)
            worker = running
            startedWith = Self.identity(script)
            log("worker started (pid \(running.pid))")
            forward(running.output)
            forward(running.errors)
            Task { [weak self] in
                let code = await running.waitForExit()
                self?.log("worker ended (\(code))")
            }
        } catch {
            log("the worker could not start: \(error.localizedDescription)")
        }
    }

    private func forward(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            FileHandle.standardError.write(data)
            _ = self
        }
    }

    private func updated(_ script: URL) -> Bool {
        guard let startedWith, let now = Self.identity(script) else { return false }
        return now.inode != startedWith.inode
    }

    private static func identity(_ url: URL) -> (path: String, inode: ino_t)? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return (url.path, st.st_ino)
    }
}
