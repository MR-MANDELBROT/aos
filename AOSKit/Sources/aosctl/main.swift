import AOSKit
import AppKit
import CoreGraphics
import Foundation
import Virtualization

// Development tool: drives the engine without the app. Not shipped.
//
//   aosctl latest                 newest macOS this Mac can virtualize
//   aosctl download               download it into RestoreImages (resumable)
//   aosctl create IPSW            create the VM and install macOS
//   aosctl run [--provision]      start the VM (first boot: account, auto login, SSH) and keep it running;
//                                   Ctrl-C suspends it
//   aosctl ip                     guest address

setvbuf(stdout, nil, _IOLBF, 0)
let paths = Paths.default
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("error: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

@MainActor
func runCommand() async {
    do {
        try paths.prepare()
        let bundle = VMBundle(url: paths.vm)
        switch args.first {
        case "latest":
            let info = try await RestoreImage.latestSupported()
            print("macOS \(info.osVersion) (\(info.buildVersion))\n\(info.url.absoluteString)")
            exit(0)

        case "download":
            let info = try await RestoreImage.latestSupported()
            let dest = paths.restoreImages.appendingPathComponent("\(info.buildVersion).ipsw")
            print("downloading macOS \(info.osVersion) (\(info.buildVersion)) to \(dest.path)")
            let lastPercent = Counter()
            let download = ResumableDownload(source: info.url, destination: dest) { got, total in
                let pct = total > 0 ? Int(Double(got) / Double(total) * 100) : 0
                if lastPercent.swap(pct) != pct { print("  \(pct)%  \(bytes(got)) of \(bytes(total))") }
            }
            _ = try await download.run()
            print("done: \(dest.path)")
            exit(0)

        case "create":
            guard args.count >= 2 else { fail("usage: aosctl create IPSW") }
            let file = URL(fileURLWithPath: args[1])
            let (image, requirements) = try await RestoreImage.load(file)
            print("creating VM for macOS \(image.buildVersion) in \(bundle.url.path)")
            _ = try VMBundle.create(at: bundle.url, requirements: requirements, settings: .standard)
            let host = VMHost(bundle: bundle, paths: paths)
            var last = -1
            try await host.install(restoreImage: file) { fraction in
                let pct = Int(fraction * 100)
                if pct != last { last = pct; print("  installing \(pct)%") }
            }
            print("installed")
            exit(0)

        case "run":
            let host = VMHost(bundle: bundle, paths: paths)
            var provisioning: VZMacGuestProvisioningOptions?
            if args.contains("--provision") {
                let secret = try GuestSecrets(paths: paths).adminPassword(createIfMissing: true)
                let p = VZMacGuestProvisioningOptions()
                p.fullName = Brand.guestFullName
                p.username = Brand.guestUser
                p.password = secret
                p.logsInAutomatically = true
                p.enablesRemoteLogin = true
                try p.validate()
                provisioning = p
            }
            host.onPhaseChange = { print("vm: \($0.rawValue)") }
            var vnc: HypervisorVNC?
            let vncPassword = String(UUID().uuidString.prefix(8))
            if args.contains("--vnc") {
                // Development only: hypervisor-level screen, attached before the VM starts.
                host.beforeStart = { machine in
                    let v = HypervisorVNC()
                    _ = try? v.start(machine: machine, password: vncPassword)
                    vnc = v
                }
            }
            try await host.start(provisioning: provisioning)
            if args.contains("--window"), let machine = host.virtualMachine {
                let w = VMWindow(machine: machine)
                keepAlive.append(w)
                let server = LineSocketServer(path: paths.run.appendingPathComponent("ctl.sock")) { line in
                    let text = String(decoding: line, as: UTF8.self)
                    return await MainActor.run { Data(w.command(text, paths: paths).utf8) }
                }
                try server.start()
                keepAlive.append(server)
                print("window and control socket ready")
            }
            if let vnc {
                keepAlive.append(vnc)
                var port: UInt16 = 0
                for _ in 0..<100 where port == 0 { try await Task.sleep(nanoseconds: 100_000_000); port = vnc.port }
                try Data("\(port) \(vncPassword)".utf8).write(to: paths.run.appendingPathComponent("hypervisor-vnc"))
                print("hypervisor VNC on port \(port)")
            }
            let ip = try await host.waitForAddress(timeout: 180)
            print("guest address: \(ip)")
            // Ctrl-C: suspend and quit.
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            source.setEventHandler {
                Task { @MainActor in
                    print("suspending")
                    do { try await host.suspend(); print("suspended") } catch { print("suspend failed: \(error)") }
                    exit(0)
                }
            }
            source.resume()
            keepAlive.append(source)

        case "connect":
            guard args.count >= 3, let agent = AgentIntegration.byID(args[1]) else {
                fail("usage: aosctl connect AGENT MCP-BINARY (agents: \(AgentIntegration.all.map(\.id).joined(separator: ", ")))")
            }
            print("\(agent.name): installed \(agent.isInstalled), executable \(agent.executable ?? "-")")
            try agent.configure(binary: URL(fileURLWithPath: args[2]), sessionFolder: nil)
            print("connected")
            exit(0)

        case "bootstrap":
            let host = VMHost(bundle: bundle, paths: paths)
            guard let ip = try host.guestAddress() else { fail("no guest address") }
            try await Provisioner(paths: paths).bootstrap(host: ip) { print("  " + $0) }
            exit(0)

        case "ssh":
            let host = VMHost(bundle: bundle, paths: paths)
            guard let ip = try host.guestAddress() else { fail("no guest address") }
            let r = try await Provisioner(paths: paths).maintenance(host: ip)
                .run(args.dropFirst().joined(separator: " "), timeout: 120, check: false)
            print(r.text, terminator: ""); FileHandle.standardError.write(Data(r.stderr.utf8))
            exit(r.status)

        case "shot", "hvclick", "hvtype", "hvkeys", "hvsharing", "hvprobe", "sskeys":
            // shot FILE [--hv]: screenshot over screen sharing (or the hypervisor VNC with --hv);
            // hvclick X Y / hvtype TEXT / hvkeys COMBO: input over the hypervisor VNC (development only)
            let hv = (args.first != "shot" && args.first != "sskeys") || args.contains("--hv")
            let client: RFBClient
            if hv {
                let info = try String(contentsOf: paths.run.appendingPathComponent("hypervisor-vnc"), encoding: .utf8)
                    .split(separator: " ")
                client = RFBClient(host: "127.0.0.1", port: UInt16(info[0])!, username: "", password: String(info[1]), encodings: [])
            } else {
                let host = VMHost(bundle: bundle, paths: paths)
                guard let ip = try host.guestAddress() else { fail("no guest address") }
                let password = try GuestSecrets(paths: paths).adminPassword(createIfMissing: false)
                client = RFBClient(host: ip, username: Brand.guestUser, password: password)
            }
            try await client.connect()
            switch args.first {
            case "hvclick":
                try await client.click(x: Int(args[1])!, y: Int(args[2])!)
                try await Task.sleep(nanoseconds: 800_000_000)
            case "hvtype":
                // --guest-password types the VM account's own password (read here, never printed)
                let text = args.contains("--guest-password")
                    ? try GuestSecrets(paths: paths).adminPassword(createIfMissing: false) + "\n"
                    : args.dropFirst().joined(separator: " ")
                for run in Keysyms.runs(for: text) {
                    if case .keys(let k) = run { try await client.type(k) }
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            case "hvsharing":
                // One connection: wait for a real frame, click the switch, type the account password, picture.
                for _ in 0..<6 {
                    if !isBlack(try await client.screenshot()) { break }
                    try await Task.sleep(nanoseconds: 700_000_000)
                }
                try await client.click(x: 984, y: 286)
                try await Task.sleep(nanoseconds: 3_000_000_000)
                // The hypervisor's server maps key symbols with the HOST's layout: on a German Mac y and z swap.
                let pw = String(try GuestSecrets(paths: paths).adminPassword(createIfMissing: false).map { c -> Character in
                    switch c { case "y": return "z"; case "z": return "y"; case "Y": return "Z"; case "Z": return "Y"; default: return c }
                })
                for run in Keysyms.runs(for: pw) { if case .keys(let k) = run { try await client.type(k) } }
                try await Task.sleep(nanoseconds: 500_000_000)
                try await client.press([Keysyms.returnKey])
                try await Task.sleep(nanoseconds: 4_000_000_000)
            case "hvprobe":
                // One connection: cancel the dialog, type a probe string into the settings search field.
                try await client.click(x: 640, y: 523)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                try await client.click(x: 350, y: 139)
                try await Task.sleep(nanoseconds: 500_000_000)
                for run in Keysyms.runs(for: "ABCabc xyz 23456789 QZqz") { if case .keys(let k) = run { try await client.type(k) } }
                try await Task.sleep(nanoseconds: 800_000_000)
            case "sskeys":
                // screen sharing (not hypervisor): wait the grace period, press a combination, type text
                try await client.press(try Keysyms.combination(args[1]))
                try await Task.sleep(nanoseconds: 1_200_000_000)
                if args.count > 2 {
                    for run in Keysyms.runs(for: args[2]) { if case .keys(let k) = run { try await client.type(k) } }
                    try await Task.sleep(nanoseconds: 1_200_000_000)
                }
            case "hvkeys":
                try await client.press(try Keysyms.combination(args[1]))
                try await Task.sleep(nanoseconds: 800_000_000)
            default: break
            }
            let out = args.first == "shot" ? args[1] : NSTemporaryDirectory() + "aos-hv.jpg"
            try await client.connect()
            var image = try await client.screenshot()
            if hv {
                // The hypervisor's server sends a placeholder first; ask a few more times.
                for _ in 0..<4 {
                    try await Task.sleep(nanoseconds: 700_000_000)
                    image = try await client.screenshot()
                    if !isBlack(image) { break }
                }
            }
            try ScreenImage.encode(image).write(to: URL(fileURLWithPath: out))
            print("\(image.width)x\(image.height) -> \(out)")
            exit(0)

        case "stop":
            // Orderly shutdown through the stop key (Chrome quits first).
            let host = VMHost(bundle: bundle, paths: paths)
            guard let ip = try host.guestAddress() else { fail("no guest address") }
            try await Provisioner(paths: paths).shutdown(host: ip)
            print("shutdown requested")
            exit(0)

        case "serve":
            // The app's workspace engine without the app (development): agent socket, VM host, idle watch.
            // --approve answers Mac-side approval requests with yes.
            let controller = WorkspaceController(paths: paths)
            controller.log = { print("workspace: \($0)") }
            if args.contains("--approve") {
                controller.onApprovalRequest = { agent, purpose, minutes in
                    print("approval asked: \(agent) \(minutes) min: \(purpose) -> yes"); return true
                }
            }
            controller.onHelpRequest = { purpose in print("help asked: \(purpose)"); return "The user is done. Continue with a screenshot." }
            let server = LineSocketServer(path: paths.agentSocket) { line in
                guard let request = try? JSONDecoder().decode(AgentRequest.self, from: line) else { return Data() }
                if request.op == "dev.allowHelper" {
                    // What the app does in AppModel.allowHelper, for testing without the app
                    let text = await devAllowHelper(controller)
                    return (try? JSONEncoder().encode(AgentResponse(id: request.id, ok: true, text: text))) ?? Data()
                }
                let response = await controller.handle(request)
                return (try? JSONEncoder().encode(response)) ?? Data()
            }
            try server.start()
            controller.startIdleWatch()
            keepAlive.append(server)
            keepAliveController = controller
            print("serving on \(paths.agentSocket.path)")

        case "vnctest":
            // vnctest HOST PORT USER: asks for the password without echo (never printed) and tries a screen sharing
            // login with Apple's classic RSA method; prints only success or the error.
            guard args.count >= 4, let port = UInt16(args[2]) else { fail("usage: aosctl vnctest HOST PORT USER") }
            guard let raw = getpass("Password for \(args[3]) (not shown): ") else { fail("no password") }
            let password = String(cString: raw)
            let client = RFBClient(host: args[1], port: port, username: args[3], password: password)
            do {
                try await client.connect()
                let image = try await client.screenshot()
                print("LOGIN OK with the classic RSA method, screen \(image.width)x\(image.height)")
            } catch {
                print("LOGIN FAILED: \(error.localizedDescription)")
            }
            exit(0)

        case "pair-test":
            // pair-test KEYS_FILE PORT FINGERPRINT [HOSTS [COMPANION]]: a pairing against a test sshd (its own
            // authorized_keys), prints the link and waits for one phone. HOSTS: comma-separated, instead of this
            // Mac's names and addresses; COMPANION: the aos-companion the phone runs.
            guard args.count >= 4, let port = UInt16(args[2]) else {
                fail("pair-test KEYS_FILE PORT FINGERPRINT [HOSTS [COMPANION]]")
            }
            let hosts = args.count > 4 ? args[4].split(separator: ",").map(String.init) : nil
            let session = PairingSession(keys: AuthorizedKeys(url: URL(fileURLWithPath: args[1])), sshPort: port,
                                         hostKeyFingerprint: args[3], hosts: hosts,
                                         companion: args.count > 5 ? args[5] : nil)
            session.onChange = {
                switch session.state {
                case .waiting: print("LINK \(session.url ?? "")")
                case .paired(let name): print("PAIRED \(name)"); exit(0)
                case .failed(let why): print("FAILED \(why)"); exit(1)
                case .expired: print("EXPIRED"); exit(1)
                case .starting: break
                }
            }
            session.start()
            keepAlive.append(session)
            return

        case "keeper":
            // keeper plan: what the session keeper would keep now (with the current settings, or --all as if on)
            var settings = AgentSettings.load(paths)
            if args.contains("--all") { settings.keepReachable = true }
            let recent = ClaudeConversations.recent(within: Double(settings.keepHours) * 3600)
            let live = ClaudeConversations.live()
            print("conversations in the last \(settings.keepHours) h: \(recent.count), live processes: \(live.count)")
            for c in recent {
                let d = c.desktop.map { "desktop(archived:\($0.archived) scheduled:\($0.scheduled) mode:\($0.permissionMode ?? "-") rcOff:\($0.remoteControlTurnedOff))" } ?? "cli"
                let running = live.filter { $0.sessionId == c.id }.map { "\($0.entrypoint):\($0.pid)" }.joined(separator: ",")
                print("  \(c.id.prefix(8)) rc:\(c.usedRemoteControl ? "y" : "n") \(d) \(running.isEmpty ? "" : "LIVE \(running) ")\"\(c.title.prefix(50))\" \(c.cwd)")
            }
            let chosen = SessionKeeper.select(recent, settings: settings, exclude: paths.session.standardizedFileURL.path)
            print("would keep (max \(settings.keepMax)):")
            for (c, pinned) in chosen { print("  \(pinned ? "pinned" : "auto  ") \(c.id.prefix(8)) \"\(c.title.prefix(60))\"") }
            guard args.contains("--run") else { exit(0) }
            // keeper --all --run: run the keeper in the foreground with these settings (testing), Ctrl-C ends it
            let keeper = SessionKeeper(paths: paths)
            let fixed = settings
            keeper.settings = { _ in fixed }
            keeper.log = { line in print(ISO8601DateFormatter().string(from: Date()), line); fflush(stdout) }
            signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
            for sig in [SIGTERM, SIGINT] {
                let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                src.setEventHandler { keeper.stopAll(); DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) } }
                src.resume()
                keepAlive.append(src as AnyObject)
            }
            keeper.run()
            return

        case "remote":
            // remote --run: Claude Code's server mode in the foreground with the current settings (testing),
            // Ctrl-C ends it
            let server = RemoteServer(paths: paths)
            server.log = { line in print(ISO8601DateFormatter().string(from: Date()), line); fflush(stdout) }
            guard args.contains("--run") else {
                if let s = RemoteServerStatus.read(paths) { print("\(s.state.rawValue) \(s.detail) \(s.folder)") } else { print("no status") }
                exit(0)
            }
            signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
            for sig in [SIGTERM, SIGINT] {
                let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                src.setEventHandler { DispatchQueue.global().async { server.stop(); exit(0) } }
                src.resume()
                keepAlive.append(src as AnyObject)
            }
            server.run()
            return

        case "ip":
            let host = VMHost(bundle: bundle, paths: paths)
            print(try host.guestAddress() ?? "no address")
            exit(0)

        default:
            fail("commands: latest, download, create IPSW, run [--provision], ip")
        }
    } catch {
        fail(error.localizedDescription)
    }
}

@MainActor var keepAlive: [AnyObject] = []

/// The helper permission flow of the app (AppModel.allowHelper / watchHelper), driven from aosctl serve.
@MainActor
func devAllowHelper(_ controller: WorkspaceController) async -> String {
    do {
        print("helper: boot and prepare")
        let ip = try await controller.bootAndPrepare(reason: "allowing the helper")
        print("helper: status")
        guard let status = await controller.provisioner.helperStatus(host: ip) else { return "helper not installed" }
        if status.trusted == true { return "already allowed" }
        print("helper: begin")
        let wasAdmin = try await controller.provisioner.beginHelperPermission(host: ip)
        print("helper: waiting for the switch (account was admin: \(wasAdmin))")
        var typed = false, typings = 0
        let deadline = Date().addingTimeInterval(600)
        var allowed = false
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let poll = await controller.provisioner.helperPermissionPoll(host: ip)
            if poll.trusted { allowed = true; break }
            if poll.passwordDialog && !typed && typings < 3 {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                try await controller.typeGuestPasswordForSetup()
                typed = true; typings += 1
                print("helper: entered the workspace password")
            } else if !poll.passwordDialog { typed = false }
        }
        try await controller.provisioner.endHelperPermission(host: ip, wasAdmin: wasAdmin)
        return allowed ? "allowed" : "not allowed (timeout)"
    } catch {
        return "error: \(error.localizedDescription)"
    }
}
@MainActor var keepAliveController: WorkspaceController?

func isBlack(_ image: CGImage) -> Bool {
    guard let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return true }
    let n = CFDataGetLength(data)
    var i = 0
    while i < n { if p[i] > 8 || p[i + 1] > 8 || p[i + 2] > 8 { return false }; i += 4 * 101 }
    return true
}

final class Counter: @unchecked Sendable {
    private var value = -1
    private let lock = NSLock()
    func swap(_ v: Int) -> Int { lock.withLock { let old = value; value = v; return old } }
}
if args.contains("--window") || args.first == "serve" {
    NSApplication.shared.setActivationPolicy(.accessory)
    Task { @MainActor in await runCommand() }
    NSApplication.shared.run()
} else {
    Task { @MainActor in await runCommand() }
    dispatchMain()
}


/// Development: the VM in a window, driven by synthesized events (what the app's VMDisplay does).
@MainActor
final class VMWindow: NSObject {
    let window: NSWindow
    let view: VZVirtualMachineView

    init(machine: VZVirtualMachine) {
        view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.virtualMachine = machine
        view.capturesSystemKeys = true
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 400), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.title = "aosctl VM"
        window.contentView = view
        super.init()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    /// Guest pixels (1280x800, origin top left) to window coordinates of the view.
    private func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double) {
        let b = view.bounds
        let local = NSPoint(x: x * b.width / 1280, y: b.height - y * b.height / 800)
        let p = view.convert(local, to: nil)
        guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return }
        window.sendEvent(e)
    }

    func command(_ line: String, paths: Paths) -> String {
        let parts = line.split(separator: " ").map(String.init)
        switch parts.first {
        case "click":
            guard parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]) else { return "bad" }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            mouse(.mouseMoved, x, y)
            mouse(.leftMouseDown, x, y)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.mouse(.leftMouseUp, x, y) }
            return "clicked"
        case "typepw":
            guard let pw = try? GuestSecrets(paths: paths).adminPassword(createIfMissing: false) else { return "no password" }
            KeyTyper.type(pw + "\n", into: view)
            return "typed"
        case "type":
            KeyTyper.type(parts.dropFirst().joined(separator: " "), into: view)
            return "typed"
        default:
            return "unknown"
        }
    }
}

/// Same key mapping as the app's VMDisplay (US/ABC key codes, Shift for capitals).
@MainActor
enum KeyTyper {
    static let codes: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
        "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
        "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
        "\n": 0x24, " ": 0x31,
    ]

    static func type(_ text: String, into view: NSView) {
        guard let window = view.window else { return }
        window.makeFirstResponder(view)
        var delay = 0.0
        for ch in text {
            let lower = Character(ch.lowercased())
            guard let code = codes[ch] ?? codes[lower] else { continue }
            let shift = ch.isUppercase
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                func key(_ t: NSEvent.EventType, _ c: UInt16, _ f: NSEvent.ModifierFlags) -> NSEvent? {
                    NSEvent.keyEvent(with: t, location: .zero, modifierFlags: f, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: c)
                }
                if shift, let e = key(.flagsChanged, 0x38, .shift) { view.flagsChanged(with: e) }
                if let e = key(.keyDown, code, shift ? .shift : []) { view.keyDown(with: e) }
                if let e = key(.keyUp, code, shift ? .shift : []) { view.keyUp(with: e) }
                if shift, let e = key(.flagsChanged, 0x38, []) { view.flagsChanged(with: e) }
            }
            delay += 0.06
        }
    }
}
