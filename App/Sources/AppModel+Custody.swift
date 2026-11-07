import AOSKit
import Foundation

/// Where the workspace's keys and disk are (AOSKit WorkspaceCustody.swift).
enum CustodyMode: Equatable {
    case unknown
    /// A workspace of an earlier aOS whose files are still in the user's folder, while the helper can't take them
    /// (not allowed yet, or an older helper still running): it works as before.
    case legacy
    /// The helper keeps them.
    case custody
    /// The helper is needed and not there.
    case unavailable(String)
}

/// The workspace's keys and disk go to aOS's background helper: at launch, and once the helper is allowed. A
/// workspace of an earlier aOS is handed over (keys and password at once, the disk while the workspace is off); the
/// keys are replaced at its next start (WorkspaceController.rotateSecretsIfNeeded).
extension AppModel {
    func setUpWorkspaceCustody() {
        if Self.isPreview { return }
        let host = workspace.host
        host.diskSource = { [weak self] in try await self?.custodyDisk() }
        host.diskReleased = { [weak self] in await self?.releaseCustodyDisk() }
    }

    var custodyClient: WorkspaceCustodyClient {
        let power = self.power
        return WorkspaceCustodyClient { await power.workspace($0) }
    }

    /// One sync at a time; returns when it's done.
    func syncWorkspaceCustody() async {
        if Self.isPreview || custodySettled { return }
        if let running = custodyTask { await running.value; return }
        let task = Task { @MainActor in await self.performCustodySync() }
        custodyTask = task
        await task.value
        custodyTask = nil
    }

    private func performCustodySync() async {
        let secrets = GuestSecrets(paths: paths)
        let bundle = workspace.host.bundle
        let state = try? bundle.loadState()
        // Without the helper, only a workspace whose secrets are still the user's files can run (as before).
        let legacyPossible = secrets.hasLocalKeys && state?.diskInCustody != true
        let helperMissing = String(localized: "\(Brand.name)'s background helper keeps the workspace's keys and disk. Allow it in \(Brand.name)'s settings (General).")
        guard power.helperStatus == .enabled else {
            changed(custodyMode, legacyPossible ? .legacy : .unavailable(helperMissing))
            return
        }
        let client = custodyClient
        guard let version = await power.helperVersion(), version >= 3 else {
            // An older helper from before the update still runs; it exits within two minutes when idle.
            changed(custodyMode, legacyPossible ? .legacy : .unavailable(String(localized: "\(Brand.name)'s background helper is being updated. Try again in a minute or two.")))
            return
        }
        do {
            var status = try await client.status()
            if status.hasKeys != true && secrets.hasLocalKeys {
                try await client.importLegacy(legacyFiles(secrets))
                append("workspace: keys and password handed to the helper")
                status = try await client.status()
            }
            GuestSecrets.custody = client
            if status.pinned != true { await pinFromEarlierVersion(client) }
            let password = try await secrets.load()
            // The user's copies go once the helper holds the same (the guest gets new ones at its next start).
            if secrets.hasLocalKeys, (try? String(contentsOf: secrets.adminPasswordURL, encoding: .utf8)) == password {
                retireLocalKeys(secrets)
            }
            let host = workspace.host
            var hasDisk = status.hasDisk == true
            if !hasDisk, FileManager.default.fileExists(atPath: bundle.diskURL.path) {
                guard host.phase == .stopped && !host.isRunning else {
                    // Handed over once the workspace is off.
                    changed(custodyMode, .custody)
                    return
                }
                try await client.adoptDisk()
                hasDisk = true
                append("workspace: disk handed to the helper")
            }
            if hasDisk, state != nil, state?.diskInCustody != true {
                try? bundle.updateState { $0.diskInCustody = true }
            }
            if FileManager.default.fileExists(atPath: bundle.diskURL.path), hasDisk {
                append("workspace: a disk.img in the user's folder is ignored (the helper has the workspace's disk)")
            }
            changed(custodyMode, .custody)
            // Settled, unless an earlier version's host key is still waiting to be taken over (try again then).
            let pinned = (try? await client.status())?.pinned == true
            custodySettled = pinned || !hasEarlierHostKeys
        } catch {
            append("workspace: helper custody: \(error.localizedDescription)")
            changed(custodyMode, legacyPossible && GuestSecrets.custody == nil ? .legacy : .unavailable(error.localizedDescription))
        }
    }

    private func changed(_ old: CustodyMode, _ new: CustodyMode) {
        if custodyMode != new { custodyMode = new }
    }

    private var earlierHostKeyFiles: [URL] {
        [GuestSecrets(paths: paths).knownHosts,
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application")]
    }

    private var hasEarlierHostKeys: Bool {
        earlierHostKeyFiles.contains { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    /// The workspace's host key as an earlier aOS recorded it. Its ssh option had a path with a space, so ssh wrote
    /// to ~/Library/Application instead of Keys/known_hosts (only host keys, nothing secret).
    private func pinFromEarlierVersion(_ client: WorkspaceCustodyClient) async {
        let fm = FileManager.default
        for url in earlierHostKeyFiles {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let data = fm.contents(atPath: url.path), !data.isEmpty, data.count < 65_536 else { continue }
            do {
                try await client.pin(knownHosts: data)
                append("workspace: host key taken over from the earlier version")
                // aOS's own stray file from that mistake goes.
                if url.lastPathComponent == "Application" { try? fm.removeItem(at: url) }
                return
            } catch {
                append("workspace: earlier host key not taken over: \(error.localizedDescription)")
            }
        }
    }

    /// The files an earlier aOS kept in Keys (whatever of them exists).
    private func legacyFiles(_ secrets: GuestSecrets) -> [String: Data] {
        var files: [String: Data] = [:]
        let sources: [(String, URL)] = [
            ("maintenance", secrets.maintenanceKey), ("maintenance.pub", secrets.maintenanceKey.appendingPathExtension("pub")),
            ("stop", secrets.stopKey), ("stop.pub", secrets.stopKey.appendingPathExtension("pub")),
            ("password", secrets.adminPasswordURL), ("known_hosts", secrets.knownHosts),
        ]
        for (name, url) in sources {
            if let data = FileManager.default.contents(atPath: url.path), !data.isEmpty { files[name] = data }
        }
        return files
    }

    /// Removes the user's copies of the keys and the password (the helper has them). Not to the Trash: there they
    /// would stay readable.
    private func retireLocalKeys(_ secrets: GuestSecrets) {
        let fm = FileManager.default
        for url in [secrets.maintenanceKey, secrets.maintenanceKey.appendingPathExtension("pub"), secrets.stopKey,
                    secrets.stopKey.appendingPathExtension("pub"), secrets.adminPasswordURL, secrets.knownHosts,
                    secrets.paths.keys.appendingPathComponent("askpass.sh")] {
            try? fm.removeItem(at: url)
        }
        append("workspace: the user's copies of the keys removed")
    }

    /// The disk for the VM: from the helper; nil only for a workspace of an earlier aOS that still runs on its own.
    func custodyDisk() async throws -> FileHandle? {
        await syncWorkspaceCustody()
        switch custodyMode {
        case .legacy:
            return nil
        case .custody:
            let client = custodyClient
            guard (try? await client.status())?.hasDisk == true else {
                if FileManager.default.fileExists(atPath: workspace.host.bundle.diskURL.path), custodySettled == false {
                    // Not handed over yet (the workspace was running): once more now that it's off.
                    await syncWorkspaceCustody()
                }
                guard (try? await client.status())?.hasDisk == true else {
                    throw CustodyError.helper(String(localized: "The workspace's disk isn't with the helper."))
                }
                return try await client.attachDisk()
            }
            return try await client.attachDisk()
        case .unknown:
            throw CustodyError.helper(String(localized: "The background helper doesn't answer."))
        case .unavailable(let why):
            throw CustodyError.helper(why)
        }
    }

    func releaseCustodyDisk() async {
        guard custodyMode == .custody else { return }
        await custodyClient.detachDisk()
    }
}
