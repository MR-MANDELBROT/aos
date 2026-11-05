import AnnexKit
import Foundation
import Virtualization

// Development tool: drives the engine without the app. Not shipped.
//
//   annexctl latest                 newest macOS this Mac can virtualize
//   annexctl download               download it into RestoreImages (resumable)
//   annexctl create IPSW            create the VM and install macOS
//   annexctl run [--provision]      start the VM (first boot: account, auto login, SSH) and keep it running;
//                                   Ctrl-C suspends it
//   annexctl ip                     guest address

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
            guard args.count >= 2 else { fail("usage: annexctl create IPSW") }
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
            try await host.start(provisioning: provisioning)
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
                fail("usage: annexctl connect AGENT MCP-BINARY (agents: \(AgentIntegration.all.map(\.id).joined(separator: ", ")))")
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

        case "shot":
            guard args.count >= 2 else { fail("usage: annexctl shot FILE.jpg") }
            let host = VMHost(bundle: bundle, paths: paths)
            guard let ip = try host.guestAddress() else { fail("no guest address") }
            let password = try GuestSecrets(paths: paths).adminPassword(createIfMissing: false)
            let client = RFBClient(host: ip, username: Brand.guestUser, password: password)
            try await client.connect()
            let image = try await client.screenshot()
            try ScreenImage.encode(image).write(to: URL(fileURLWithPath: args[1]))
            print("\(image.width)x\(image.height) -> \(args[1])")
            exit(0)

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

final class Counter: @unchecked Sendable {
    private var value = -1
    private let lock = NSLock()
    func swap(_ v: Int) -> Int { lock.withLock { let old = value; value = v; return old } }
}
Task { @MainActor in await runCommand() }
dispatchMain()
