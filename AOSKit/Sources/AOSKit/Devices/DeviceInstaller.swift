import Foundation

/// Puts apps on the person's iPhone: copies the app aside, signs the copy, leaves a job for the device worker and
/// waits for its result (the agent tools `iphone_install` and `iphone_status`, the Settings tab Apps).
public struct DeviceInstaller: Sendable {
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    public enum InstallError: LocalizedError {
        case off
        case notSetUp
        case notFound(String)
        case noDevice
        case unpack(String)

        public var errorDescription: String? {
            switch self {
            case .off: return "Installing apps on the iPhone is off. The user turns it on in \(Brand.name): Settings > Apps."
            case .notSetUp: return "Installing apps on the iPhone isn't set up yet (\(Brand.name): Settings > Apps)."
            case .notFound(let path): return "There is no app at \(path). Give the absolute path of a .app or .ipa."
            case .noDevice: return "\(Brand.name) doesn't know the user's iPhone yet: it is paired once over Wi-Fi or a cable (Settings > Apps)."
            case .unpack(let why): return "The .ipa could not be opened: \(why)"
            }
        }
    }

    /// The iPhone the tunnel knows, or the one this Mac holds a pairing record for.
    public func deviceUDID(status: DeviceStatus? = nil) -> String? {
        if let udid = (status ?? DeviceStatus.load(paths))?.device?.udid { return udid }
        return Self.pairedDevices().first
    }

    /// Devices this Mac holds a RemotePairing record for (pymobiledevice3's `~/.pymobiledevice3/remote_<udid>.plist`).
    public static func pairedDevices(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let folder = home.appendingPathComponent(".pymobiledevice3")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { $0.hasPrefix("remote_") && $0.hasSuffix(".plist") }
            .map { String($0.dropFirst("remote_".count).dropLast(".plist".count)) }
            .sorted()
    }

    /// Copies the app (a .app folder or an .ipa) into `Devices/Staging/<id>/`, signs the copy (`sign`), and leaves
    /// the job for the worker. The original stays as it is.
    public func submit(path: String, source: String?, sign: Bool = true, signer: IOSAppSigner? = nil) async throws -> DeviceJob {
        guard AgentSettings.load(paths).iphoneApps else { throw InstallError.off }
        let original = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: original.path) else { throw InstallError.notFound(path) }
        guard let udid = deviceUDID() else { throw InstallError.noDevice }
        try paths.prepare()
        let id = UUID().uuidString
        let folder = paths.deviceStaging.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let app = try await stage(original, into: folder)
            let bundle = try IOSAppBundle.read(app)
            if sign {
                let chosen: IOSAppSigner
                if let signer { chosen = signer } else { chosen = await IOSAppSigner.current() }
                try await chosen.sign(app: app, udid: udid, workFolder: folder.appendingPathComponent(".work"))
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(".work"))
            }
            let job = DeviceJob(id: id, app: app.path, name: bundle.name, bundleId: bundle.bundleID,
                                version: bundle.version, source: source)
            try write(job)
            return job
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// The app folder inside `folder`: a copy of the .app, or what the .ipa holds in Payload/.
    func stage(_ original: URL, into folder: URL) async throws -> URL {
        if original.pathExtension.lowercased() == "ipa" {
            let unzip = try await Subprocess.run("/usr/bin/ditto", ["-x", "-k", original.path, folder.path], timeout: 300)
            guard unzip.status == 0 else { throw InstallError.unpack(String(decoding: unzip.stderr, as: UTF8.self)) }
            let payload = folder.appendingPathComponent("Payload")
            let apps = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
            guard let app = apps.first(where: { $0.pathExtension == "app" }) else { throw InstallError.unpack("no Payload/*.app") }
            return app
        }
        let copy = folder.appendingPathComponent(original.lastPathComponent)
        let ditto = try await Subprocess.run("/usr/bin/ditto", [original.path, copy.path], timeout: 300)
        guard ditto.status == 0 else { throw InstallError.notFound(original.path) }
        return copy
    }

    func write(_ job: DeviceJob) throws {
        try FileManager.default.createDirectory(at: paths.deviceJobs, withIntermediateDirectories: true)
        let data = try DeviceJob.encoder().encode(job)
        let target = paths.deviceJobs.appendingPathComponent("\(job.id).json")
        let temp = paths.deviceJobs.appendingPathComponent(".\(job.id).json.tmp")
        try data.write(to: temp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
    }

    public func job(_ id: String) -> DeviceJob? {
        let url = paths.deviceJobs.appendingPathComponent("\(id).json")
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? DeviceStatus.decoder().decode(DeviceJob.self, from: data)
    }

    /// Waits until the job finished, at most `timeout` seconds; returns early (with the job still queued) while
    /// there is no tunnel: then it waits for the iPhone's next Wi-Fi.
    public func wait(for id: String, timeout: TimeInterval) async -> DeviceJob? {
        let end = Date().addingTimeInterval(timeout)
        var withoutTunnel = 0
        while Date() < end {
            guard let job = job(id) else { return nil }
            if job.isFinished { return job }
            if job.state == .queued, let status = DeviceStatus.load(paths), !status.isConnected || status.isOffline {
                withoutTunnel += 1
                if withoutTunnel >= 3 { return job }
            } else {
                withoutTunnel = 0
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return job(id)
    }

    // MARK: Texts for the agent tools

    /// Installs and reports in a sentence or two (the tool `iphone_install`).
    public func installForAgent(path: String, source: String?, wait: Bool = true) async -> (ok: Bool, text: String) {
        let job: DeviceJob
        do {
            job = try await submit(path: path, source: source)
        } catch {
            return (false, error.localizedDescription)
        }
        let label = "\(job.name) (\(job.bundleId)\(job.version.map { " \($0)" } ?? ""))"
        guard wait else { return (true, "Queued \(label) for the iPhone (job \(job.id)). iphone_status shows the result.") }
        let finished = await self.wait(for: job.id, timeout: 180) ?? job
        switch finished.state {
        case .done:
            let network = finished.network == "cellular" ? "on cellular" : finished.network == "wifi" ? "on Wi-Fi" : ""
            let seconds = finished.seconds.map { String(format: "%.0f s", $0) } ?? ""
            return (true, "Installed \(label) on the iPhone (\([seconds, network].filter { !$0.isEmpty }.joined(separator: ", "))). "
                    + "The user opens it from the Home Screen.")
        case .failed:
            return (false, "The iPhone refused \(label): \(finished.message ?? "unknown error")")
        default:
            if DeviceStatus.load(paths)?.isOffline == true {
                return (true, "Signed and queued \(label). The iPhone is offline right now; the tunnel waits for it, and "
                        + "\(Brand.name) installs it by itself as soon as the iPhone is back online. Job \(job.id).")
            }
            return (true, "Signed and queued \(label). The iPhone isn't reachable right now: \(Brand.name) installs it by itself "
                    + "as soon as the iPhone is on any Wi-Fi (the tunnel then also holds on cellular). Job \(job.id).")
        }
    }

    /// The state in a few lines (the tool `iphone_status`).
    public func statusText(now: Date = Date()) -> String {
        let settings = AgentSettings.load(paths)
        guard settings.iphoneApps else { return "Installing apps on the iPhone is off (\(Brand.name): Settings > Apps)." }
        guard let status = DeviceStatus.load(paths), status.isFresh() else {
            return "The device worker isn't running (\(Brand.name): Settings > Apps)."
        }
        var lines: [String] = []
        let name = status.device?.name ?? "the iPhone"
        switch status.state {
        case .connected:
            let minutes = status.since.map { Int(now.timeIntervalSince($0) / 60) } ?? 0
            if status.isOffline {
                lines.append("Tunnel to \(name) up for \(minutes) min, but the iPhone is offline right now: installs wait until "
                             + "it's back online (the tunnel holds meanwhile).")
            } else {
                let network = status.network == "cellular" ? "on cellular" : "on Wi-Fi"
                lines.append("Connected to \(name) (iOS \(status.device?.ios ?? "?")), \(network), tunnel up for \(minutes) min: installs take seconds.")
            }
        case .notPaired:
            lines.append("This Mac isn't paired with an iPhone yet.")
        default:
            lines.append("No tunnel to \(name) right now: it comes back as soon as the iPhone is on any Wi-Fi. Installs wait until then.")
        }
        let jobs = status.jobs.prefix(8)
        if !jobs.isEmpty {
            lines.append("Latest installs:")
            for job in jobs {
                lines.append("- \(job.name) (\(job.bundleId)): \(job.state.rawValue)\(job.message.map { ", \($0)" } ?? "")")
            }
        }
        return lines.joined(separator: "\n")
    }
}
