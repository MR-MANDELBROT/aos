import AOSKit
import Foundation
import ServiceManagement

/// Setting up the device worker's Python environment (Settings > Apps).
enum DeviceSetupState: Equatable {
    case idle
    case running(DeviceRuntime.Step)
    case failed(String)
}

/// The LaunchAgent that keeps the device worker running (App/LaunchAgents/dev.marquart.aos.devices.plist).
enum DevicesAgent {
    static let plistName = "dev.marquart.aos.devices.plist"
    static var service: SMAppService { SMAppService.agent(plistName: plistName) }
}

extension AppModel {
    var deviceResources: URL { Bundle.main.resourceURL ?? Bundle.main.bundleURL }

    func refreshDevices(loginItems: Bool) {
        let status = DeviceStatus.load(paths)
        if status != devices { devices = status }
        let ready = DeviceRuntime.isReady(paths, requirements: DeviceRuntime.requirements(in: deviceResources))
        if ready != deviceRuntimeReady { deviceRuntimeReady = ready }
        if loginItems, DevicesAgent.service.status != devicesAgentStatus { devicesAgentStatus = DevicesAgent.service.status }
    }

    /// The worker runs while installing on the iPhone is on.
    func updateDevicesAgent() {
        let service = DevicesAgent.service
        do {
            if settings.iphoneApps && service.status != .enabled {
                try service.register()
                append("device worker registered")
            } else if !settings.iphoneApps && service.status == .enabled {
                try service.unregister()
                append("device worker removed")
            }
        } catch { append("device worker: \(error.localizedDescription)") }
        devicesAgentStatus = service.status
    }

    /// Downloads uv, Python and pymobiledevice3 into aOS's folder (the person pressed Set Up).
    func setUpDevices() {
        if case .running = deviceSetup { return }
        deviceSetup = .running(.downloadingUV)
        let paths = self.paths
        let requirements = DeviceRuntime.requirements(in: deviceResources)
        Task {
            do {
                try await DeviceRuntime.setUp(paths, requirements: requirements) { step in
                    Task { @MainActor in self.deviceSetup = .running(step) }
                }
                await MainActor.run {
                    self.deviceSetup = .idle
                    self.refreshDevices(loginItems: true)
                    self.append("device environment ready")
                }
            } catch {
                await MainActor.run { self.deviceSetup = .failed(error.localizedDescription) }
            }
        }
    }

    /// Ends the worker; aos-devices starts it again within 10 s and it looks for the iPhone at once.
    func reconnectDevices() {
        guard let pid = devices?.pid, devices?.isFresh() == true else { return }
        kill(pid, SIGTERM)
    }

    /// Pairs this Mac with the iPhone connected by cable: the Trust dialog on the iPhone if needed, then the
    /// RemotePairing record the tunnel uses (pymobiledevice3 `lockdown pair`, `lockdown remotepairing --pair`).
    func pairIPhone() async -> String? {
        let tool = DeviceRuntime.environment(paths).appendingPathComponent("bin/pymobiledevice3").path
        var env = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        func run(_ args: [String]) async -> (ok: Bool, output: String) {
            guard let r = try? await Subprocess.run(tool, args, environment: env, timeout: 120) else { return (false, "") }
            return (r.status == 0, String(decoding: r.stderr + r.stdout, as: UTF8.self))
        }
        var result = await run(["lockdown", "remotepairing", "--pair"])
        if !result.ok {
            _ = await run(["lockdown", "pair"])
            result = await run(["lockdown", "remotepairing", "--pair"])
        }
        if result.ok {
            reconnectDevices()
            return nil
        }
        let last = result.output.split(separator: "\n").last.map(String.init) ?? ""
        return last.isEmpty ? String(localized: "Connect the iPhone with a cable, unlock it and tap Trust.") : last
    }
}
