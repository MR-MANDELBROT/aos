import CoreGraphics
import Foundation

/// The workspace as the MCP tools see it: a lease ("open for N minutes"), the VM behind it, the screen
/// connection and the exchange folder. Every request comes through `handle`.
@MainActor
public final class WorkspaceController {
    public let paths: Paths
    public let host: VMHost
    public private(set) var provisioner: Provisioner
    public private(set) var settings: AgentSettings
    private var rfb: RFBClient?
    private var lease: (until: Date, purpose: String)?
    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var busy = false
    private var closing = false
    public var log: (String) -> Void = { _ in }
    /// Called whenever something the app shows changes.
    public var onChange: (() -> Void)?
    /// Shows the workspace to the user with the request and returns when they are done (the app sets this).
    public var onHelpRequest: ((String) async -> String)?
    /// Asks the user on the Mac whether an agent may open the workspace (agent name, purpose, minutes).
    public var onApprovalRequest: ((String, String, Int) async -> Bool)?

    public init(paths: Paths) {
        self.paths = paths
        self.settings = AgentSettings.load(paths)
        self.host = VMHost(bundle: VMBundle(url: paths.vm), paths: paths)
        self.provisioner = Provisioner(paths: paths, kit: GuestKit(policies: ChromePolicies(keepSignedIn: settings.keepSignedIn)))
        host.onPhaseChange = { [weak self] _ in self?.onChange?() }
    }

    public func updateSettings(_ s: AgentSettings) throws {
        try s.save(paths)
        settings = s
        // New sign-in domains change the Chrome policies: the guest gets them at its next opening.
        provisioner = Provisioner(paths: paths, kit: GuestKit(policies: ChromePolicies(keepSignedIn: s.keepSignedIn)))
        onChange?()
    }

    public func startIdleWatch() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.idleCheck() }
        }
    }

    private func idleCheck() async {
        guard !busy, !closing else { return }
        if let lease, lease.until < Date() {
            log("lease for \"\(lease.purpose)\" expired, closing the workspace")
            _ = await close()
            return
        }
        if lease == nil, host.isRunning,
           Date().timeIntervalSince(lastActivity) > Double(settings.idleMinutes * 60) {
            log("workspace idle for \(settings.idleMinutes) min, closing")
            _ = await close()
        }
    }

    // MARK: State

    public var setupComplete: Bool {
        guard let state = try? host.bundle.loadState() else { return false }
        return state.bootstrapped && state.screenSharingReady
    }

    public func status() -> AgentStatus {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: paths.exchange.path))?
            .filter { !$0.hasPrefix(".") }.count ?? 0
        return AgentStatus(vmPhase: host.phase.rawValue, installed: host.bundle.exists, setupComplete: setupComplete,
                           leaseUntil: lease?.until, leasePurpose: lease?.purpose,
                           guestAddress: try? host.guestAddress(), exchangeFiles: files,
                           lastError: host.lastError, sessionState: nil)
    }

    // MARK: Requests

    public func handle(_ request: AgentRequest) async -> AgentResponse {
        lastActivity = Date()
        busy = true
        defer { busy = false; lastActivity = Date(); onChange?() }
        do {
            switch request.op {
            case "status": return AgentResponse(id: request.id, ok: true, text: statusText())
            case "open": return try await open(request)
            case "close": return AgentResponse(id: request.id, ok: true, text: await close())
            case "files": return AgentResponse(id: request.id, ok: true, text: try Exchange(paths: paths).listing())
            case "put":
                let text = try Exchange(paths: paths).put(path: request.path ?? "", name: request.name)
                return AgentResponse(id: request.id, ok: true, text: text)
            case "help":
                _ = try requireLease()
                let purpose = (request.purpose ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !purpose.isEmpty else { throw WorkspaceError.needsPurpose }
                guard let ask = onHelpRequest else { throw WorkspaceError.helpUnavailable }
                // The lease must not run out while the user works.
                if let l = lease { lease = (max(l.until, Date().addingTimeInterval(15 * 60)), l.purpose) }
                return AgentResponse(id: request.id, ok: true, text: await ask(purpose))
            case "get":
                let text = try Exchange(paths: paths).get(name: request.name ?? "", keep: request.keep ?? false)
                return AgentResponse(id: request.id, ok: true, text: text)
            default:
                return try await input(request)
            }
        } catch {
            log("\(request.op): \(error.localizedDescription)")
            return .failure(request.id, error.localizedDescription)
        }
    }

    private func statusText() -> String {
        let s = status()
        var lines = ["workspace: \(s.installed ? (s.setupComplete ? "ready" : "setup not finished") : "not created")",
                     "vm: \(s.vmPhase)"]
        if let until = s.leaseUntil, let purpose = s.leasePurpose {
            let minutes = max(0, Int(until.timeIntervalSinceNow / 60))
            lines.append("open for \"\(purpose)\", \(minutes) min left")
        } else {
            lines.append("not open (call workspace_open first)")
        }
        lines.append("exchange folder: \(s.exchangeFiles) item(s)")
        lines.append("sign-ins: \(settings.expireSignIns ? "expire when closed, except \(settings.keepSignedIn.joined(separator: ", "))" : "kept (workspace is suspended)")")
        if let e = s.lastError { lines.append("last error: \(e)") }
        return lines.joined(separator: "\n")
    }

    private func guestPassword() throws -> String { try GuestSecrets(paths: paths).adminPassword(createIfMissing: false) }

    private func open(_ request: AgentRequest) async throws -> AgentResponse {
        guard setupComplete else {
            throw WorkspaceError.notSetUp
        }
        let purpose = (request.purpose ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !purpose.isEmpty else { throw WorkspaceError.needsPurpose }
        let minutes = max(1, min(request.minutes ?? 30, 120))
        // Approved by the agent or through it; otherwise (or from an unknown client) Annex asks on the Mac.
        if request.approval != "agent" && request.approval != "elicited" {
            guard let ask = onApprovalRequest else { throw WorkspaceError.approvalUnavailable }
            log("asking the user: \(request.agent ?? "an agent") wants the workspace for \"\(purpose)\"")
            guard await ask(request.agent ?? "An agent", purpose, minutes) else { throw WorkspaceError.declined }
        }
        if !host.isRunning {
            log("starting the workspace for \"\(purpose)\"")
            try await host.start()
        }
        let ip = try await host.waitForAddress(timeout: 120)
        do {
            try await provisioner.updateIfNeeded(host: ip) { [weak self] line in Task { @MainActor in self?.log(line) } }
        } catch {
            log("workspace update failed (continuing): \(error.localizedDescription)")
        }
        let client = try await connectScreen(ip: ip, timeout: 120)
        lease = (Date().addingTimeInterval(Double(minutes * 60)), purpose)
        log("open for \"\(purpose)\", \(minutes) min")
        let image = try await client.screenshot()
        return try picture(request.id, "Workspace open for \(minutes) min. Screen \(image.width)x\(image.height) pixels; coordinates are pixels in this picture.", image)
    }

    /// Connects to screen sharing in the guest; right after a boot it takes a while until it answers.
    private func connectScreen(ip: String, timeout: TimeInterval) async throws -> RFBClient {
        if let rfb, await rfb.isConnected, rfb.host == ip { return rfb }
        await rfb?.disconnect()
        let client = RFBClient(host: ip, username: Brand.guestUser, password: try guestPassword())
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = WorkspaceError.screenUnavailable
        while Date() < deadline {
            do {
                try await client.connect()
                // A picture that is all black means screen sharing is on but not allowed to capture.
                rfb = client
                return client
            } catch {
                lastError = error
                if Self.isLocalNetworkDenied(error) { throw WorkspaceError.localNetworkDenied }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw lastError
    }

    /// macOS' local network privacy: without the user's permission connections to the VM fail with ENETDOWN.
    static func isLocalNetworkDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "Network.NWError" || ns.domain == NSPOSIXErrorDomain { return ns.code == Int(ENETDOWN) }
        return "\(error)".contains("Network is down") || "\(error)".contains("error 50")
    }

    private func requireLease() throws -> RFBClient {
        guard let lease, lease.until > Date() else { throw WorkspaceError.notOpen }
        guard let rfb else { throw WorkspaceError.notOpen }
        return rfb
    }

    private func picture(_ id: Int, _ text: String, _ image: CGImage) throws -> AgentResponse {
        let data = try ScreenImage.encode(image, quality: 0.8)
        return AgentResponse(id: id, ok: true, text: text + leaseNote(), image: data, mimeType: "image/jpeg")
    }

    private func leaseNote() -> String {
        guard let lease else { return "" }
        let left = Int(lease.until.timeIntervalSinceNow / 60)
        return left < 5 ? " (\(max(0, left)) min left in this session)" : ""
    }

    private func point(_ v: Double?, _ name: String) throws -> Int {
        guard let v, v.isFinite else { throw WorkspaceError.missing(name) }
        return Int(v.rounded())
    }

    private func input(_ request: AgentRequest) async throws -> AgentResponse {
        let client = try requireLease()
        var done = ""
        switch request.op {
        case "screenshot":
            let image = try await client.screenshot()
            if let r = request.region, r.count == 4, let crop = ScreenImage.crop(image, to: CGRect(x: r[0], y: r[1], width: r[2], height: r[3])) {
                return try picture(request.id, "Region \(Int(r[0])),\(Int(r[1])) \(crop.width)x\(crop.height) of the screen.", crop)
            }
            return try picture(request.id, "Screen \(image.width)x\(image.height).", image)
        case "click":
            let x = try point(request.x, "x"), y = try point(request.y, "y")
            let button: RFBClient.Button
            switch (request.button ?? "left").lowercased() {
            case "right": button = .right
            case "middle": button = .middle
            default: button = .left
            }
            let mods = try (request.modifiers ?? "").isEmpty ? [] : Keysyms.combination(request.modifiers!)
            try await client.click(x: x, y: y, button: button, count: request.count ?? 1, modifiers: mods)
            done = "Clicked at \(x),\(y)."
        case "drag":
            let x = try point(request.x, "x"), y = try point(request.y, "y")
            let tx = try point(request.toX, "to_x"), ty = try point(request.toY, "to_y")
            try await client.drag(fromX: x, fromY: y, toX: tx, toY: ty)
            done = "Dragged from \(x),\(y) to \(tx),\(ty)."
        case "scroll":
            let x = try point(request.x, "x"), y = try point(request.y, "y")
            let dir = RFBClient.ScrollDirection(rawValue: (request.direction ?? "down").lowercased()) ?? .down
            try await client.scroll(x: x, y: y, direction: dir, steps: request.steps ?? 3)
            done = "Scrolled \(dir.rawValue) at \(x),\(y)."
        case "type":
            let text = request.text ?? ""
            guard !text.isEmpty else { throw WorkspaceError.missing("text") }
            for run in Keysyms.runs(for: text) {
                switch run {
                case .keys(let keys): try await client.type(keys)
                case .paste(let s): try await paste(s, client: client)
                }
            }
            done = "Typed \(text.count) character(s)."
        case "keys":
            let combo = try Keysyms.combination(request.keys ?? "")
            try await client.press(combo)
            done = "Pressed \(request.keys ?? "")."
        case "wait":
            let s = max(0.5, min(request.seconds ?? 2, 15))
            try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
            done = "Waited \(s) s."
        default:
            throw WorkspaceError.unknownOperation(request.op)
        }
        if request.image == false { return AgentResponse(id: request.id, ok: true, text: done + leaseNote()) }
        try await Task.sleep(nanoseconds: 350_000_000)
        return try picture(request.id, done, try await client.screenshot())
    }

    /// Text without a key symbol goes through the guest's clipboard: set over SSH, pasted with cmd+v.
    private func paste(_ text: String, client: RFBClient) async throws {
        guard let ip = try host.guestAddress() else { throw VMHostError.noAddress }
        try await provisioner.maintenance(host: ip).run(
            "u=\(Brand.guestUser); launchctl asuser \"$(id -u $u)\" sudo -u $u env LANG=en_US.UTF-8 /usr/bin/pbcopy",
            input: Data(text.utf8), timeout: 20, what: "clipboard")
        try await client.press([Keysyms.command, 0x76])
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    /// Ends the lease and stops the VM: an orderly shutdown (sign-ins expire) or a suspend.
    public func close() async -> String {
        if closing { return "Workspace is closing." }
        closing = true
        defer { closing = false }
        lease = nil
        await rfb?.disconnect()
        rfb = nil
        guard host.isRunning else { return "Workspace closed." }
        if settings.expireSignIns, let ip = try? host.guestAddress() {
            log("shutting the workspace down (sign-ins expire)")
            host.expectStop()
            try? await provisioner.shutdown(host: ip)
            if await host.waitUntilStopped(timeout: 90) { return "Workspace closed and shut down." }
            log("guest did not power off in time, stopping it")
            try? await host.forceStop()
            return "Workspace closed (forced off)."
        }
        do {
            try await host.suspend()
            return "Workspace closed and suspended."
        } catch {
            log("suspend failed: \(error.localizedDescription); shutting down")
            try? await host.forceStop()
            return "Workspace closed."
        }
    }
}

public enum WorkspaceError: LocalizedError {
    case notSetUp, needsPurpose, notOpen, screenUnavailable, helpUnavailable, approvalUnavailable, declined, localNetworkDenied
    case missing(String)
    case unknownOperation(String)

    public var errorDescription: String? {
        switch self {
        case .notSetUp: return "The workspace isn't set up yet. The user has to finish the setup in the \(Brand.name) app."
        case .needsPurpose: return "Say in one sentence what you need the workspace for (purpose)."
        case .notOpen: return "The workspace is not open. Call workspace_open first (the user approves it)."
        case .screenUnavailable: return "Screen sharing in the workspace doesn't answer."
        case .approvalUnavailable: return "Nobody can approve opening the workspace right now (the \(Brand.name) app is not showing). Tell the user."
        case .declined: return "The user did not allow opening the workspace."
        case .localNetworkDenied: return "macOS doesn't let \(Brand.name) reach its workspace yet. The user has to allow \(Brand.name) under System Settings > Privacy & Security > Local Network. Tell the user."
        case .helpUnavailable: return "Asking the user for help is not available right now. Tell the user in the chat what you need."
        case .missing(let p): return "Missing parameter \(p)."
        case .unknownOperation(let op): return "Unknown operation \(op)."
        }
    }
}
