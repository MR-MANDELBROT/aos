import AOSKit
import AppKit
import SystemConfiguration

/// Reaching this Mac from the iPhone on the go (Docs/DESIGN.md, "Reaching the Mac on the go"): the person's Tailscale
/// app (read only), aOS's own Tailscale node (through the helper) and what goes into the pairing code. The setup's
/// step and Settings > Connection show it.
@MainActor
final class TailnetController: ObservableObject {
    static let shared = TailnetController()

    /// The Tailscale app on this Mac; nil until read once.
    @Published private(set) var app: TailscaleAppState?
    /// aOS's node: the helper's last answer.
    @Published private(set) var node: TailnetReply?
    /// Why aOS's node can't be reached right now (the helper isn't allowed, or an older one still runs).
    @Published private(set) var helperProblem: String?
    /// Something runs (setting up, signing out, ...).
    @Published private(set) var working = false
    /// The last action's note, for the panel.
    @Published private(set) var note: String?
    /// The person started a sign-in: the sign-in page opens in the browser, the panel waits until the node runs.
    @Published private(set) var waitingForSignIn = false

    private var openedSignIn: String?
    private var signInWatch: Task<Void, Never>?
    private var timer: Timer?
    private var model: AppModel { AppModel.shared }
    private var power: PowerController { AppModel.shared.power }

    var log: (String) -> Void = { AppModel.shared.append($0) }

    var way: ReachWay? { model.settings.reachWay }
    var nodeStatus: TailnetStatus? { node?.status }
    var nodeRunning: Bool { nodeStatus?.isRunning == true }
    /// aOS's node is meant to run (set up and not stopped).
    var nodeEnabled: Bool { node?.enabled == true }
    /// What the setup recommends now.
    var recommended: ReachWay { ReachAdvisor.recommended(for: app ?? .notInstalled) }

    /// The name of aOS's node: "aos-" and this Mac's local host name.
    var hostname: String {
        TailnetRequest.hostname(forMac: (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? MacSSH.macName())
    }

    /// The pairing code's part about the way (nil until a way was chosen: the link as before).
    var pairingReach: PairingReach? {
        guard let way else { return nil }
        switch way {
        case .tailscaleApp: return PairingReach(way: way, node: app?.status)
        case .aosTailscale: return PairingReach(way: way, node: nodeStatus)
        case .localNetwork: return PairingReach(way: way)
        }
    }

    /// At launch: read both, then look at aOS's node every 30 s while it is the way (which also starts the helper
    /// again after an update; the helper then starts the node).
    func start() {
        guard timer == nil else { return }
        // The helper only when aOS's node is the way (a call starts it, and it would stay two minutes for nothing).
        Task {
            await readApp()
            if way == .aosTailscale { await readNode() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                let controller = TailnetController.shared
                if controller.way == .aosTailscale || controller.nodeEnabled { await controller.readNode() }
            }
        }
    }

    func refresh() {
        Task {
            await readApp()
            await readNode()
        }
    }

    func readApp() async {
        let state = await TailscaleApp.read()
        if state != app { app = state }
    }

    func readNode() async {
        guard power.helperStatus == .enabled else {
            helperProblem = String(localized: "\(Brand.name)'s Tailscale runs in its background helper. Allow it in \(Brand.name)'s settings (General).")
            return
        }
        guard let version = await power.helperVersion(), version >= 4 else {
            helperProblem = String(localized: "\(Brand.name)'s background helper is being updated. Try again in a minute or two.")
            return
        }
        let reply = await power.tailnet(TailnetRequest(op: .status))
        if reply.ok {
            helperProblem = nil
            if reply != node { node = reply }
        } else {
            helperProblem = reply.message
        }
    }

    // MARK: Actions

    /// "aOS sets up Tailscale": the helper starts the node, the sign-in page opens in the browser.
    func setUp() {
        run {
            let reply = await self.power.tailnet(TailnetRequest(op: .start, hostname: self.hostname))
            self.take(reply)
            self.log("tailnet: aOS's node \(reply.ok ? "started" : "didn't start: \(reply.message ?? "")")")
            if reply.ok && !(reply.status?.isRunning ?? false) { self.watchSignIn() }
        }
    }

    /// Opens the sign-in page again (a new one if the old one is used up).
    func signIn() {
        run {
            if self.node?.running != true {
                self.take(await self.power.tailnet(TailnetRequest(op: .start, hostname: self.hostname)))
            } else if self.nodeStatus?.authURL == nil {
                self.take(await self.power.tailnet(TailnetRequest(op: .login)))
            }
            self.openedSignIn = nil
            self.watchSignIn()
        }
    }

    func reconnect() {
        run {
            self.take(await self.power.tailnet(TailnetRequest(op: .reconnect)))
            self.log("tailnet: aOS's node reconnected")
        }
    }

    /// Signs out: this Mac's node leaves the tailnet and its keys are deleted.
    func signOut() {
        signInWatch?.cancel()
        waitingForSignIn = false
        run {
            let reply = await self.power.tailnet(TailnetRequest(op: .logout))
            self.take(reply)
            self.note = reply.message
            self.log("tailnet: signed out of aOS's node")
        }
    }

    /// The way changed: aOS's node runs only while it is the way (stopped it keeps its sign-in).
    func wayChanged(from old: ReachWay?, to new: ReachWay) {
        guard old != new else { return }
        if old == .aosTailscale, nodeEnabled {
            run { self.take(await self.power.tailnet(TailnetRequest(op: .stop))) }
        } else if new == .aosTailscale, node?.hostname != nil, !nodeEnabled {
            // Set up before: on again, without a new sign-in.
            run { self.take(await self.power.tailnet(TailnetRequest(op: .start, hostname: self.hostname))) }
        }
        if new == .tailscaleApp { Task { await readApp() } }
    }

    func openAdminConsole() {
        NSWorkspace.shared.open(URL(string: "https://login.tailscale.com/admin/machines")!)
    }

    // MARK: Signing in

    private func watchSignIn() {
        signInWatch?.cancel()
        waitingForSignIn = true
        signInWatch = Task { [weak self] in
            for _ in 0..<400 {
                guard let self, !Task.isCancelled else { return }
                await self.readNode()
                if self.nodeRunning {
                    self.waitingForSignIn = false
                    self.log("tailnet: aOS's node is signed in")
                    return
                }
                if let url = self.nodeStatus?.authURL, url != self.openedSignIn, let page = Self.signInPage(url) {
                    self.openedSignIn = url
                    NSWorkspace.shared.open(page)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            self?.waitingForSignIn = false
        }
    }

    /// Only Tailscale's own sign-in pages open (the helper relays what the coordination server sent).
    nonisolated static func signInPage(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased(),
              host == "tailscale.com" || host.hasSuffix(".tailscale.com") else { return nil }
        return url
    }

    private func take(_ reply: TailnetReply) {
        if reply.ok {
            node = reply
            helperProblem = nil
        } else {
            note = reply.message
        }
    }

    private func run(_ body: @escaping @MainActor () async -> Void) {
        guard !working else { return }
        working = true
        note = nil
        Task {
            let version = power.helperStatus == .enabled ? await power.helperVersion() : nil
            if (version ?? 0) < 4 {
                await readNode()
                working = false
                return
            }
            await body()
            working = false
        }
    }
}
