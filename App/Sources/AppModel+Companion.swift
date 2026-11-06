import AOSKit
import AppKit
import Foundation
import UserNotifications

/// The helper in the workspace that signs in for the agent (needs a one-time permission).
enum HelperState: Equatable {
    case unknown
    case checking
    /// Installed, but macOS doesn't let it see and type yet.
    case notAllowed
    /// The user is switching it on in the workspace window.
    case allowing
    case allowed
    case unavailable(String)
}

extension AppModel {
    // MARK: Events from the hub

    func companionChanged() {
        let hub = workspace.companion
        phoneConnected = hub.phoneConnected
        phoneName = hub.lastDevice?.name
        let open = workspace.openSignIns
        let new = open.filter { e in !signIns.contains { $0.request == e.request } }
        signIns = open
        for e in new { announceSignIn(e) }
        if open.isEmpty { closeSignInWindow() }
    }

    /// A help or approval answered on the iPhone.
    func companionAnswer(_ request: AgentRequest) -> String? {
        switch request.op {
        case "help.done":
            guard let h = help, h.id.uuidString == request.request else { return "This help request is no longer open." }
            finishHelp(h.id, "The user is done (on their iPhone). Continue with a screenshot.")
            return nil
        case "approval.answer":
            guard let a = approval, a.id.uuidString == request.request else { return "This request is no longer open." }
            answerApproval(a.id, request.allowed ?? false)
            return nil
        default:
            return "unknown answer"
        }
    }

    // MARK: Sign-ins

    private func announceSignIn(_ e: CompanionEvent) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(e.agent ?? "Your agent") wants to sign in")
        content.body = String(localized: "on \(e.host ?? "a website"). Approve on your iPhone or here on the Mac.")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "signin-\(e.request ?? "")",
                                                                     content: content, trigger: nil))
        // On the Mac the window comes up only when no phone is connected; the menu shows it either way.
        if !phoneConnected {
            openWindow?(WindowID.signIn)
            NSApp.activate()
        }
    }

    private func closeSignInWindow() {
        for w in NSApp.windows where w.identifier?.rawValue.hasPrefix(WindowID.signIn) == true { w.close() }
        UNUserNotificationCenter.current().getDeliveredNotifications { list in
            let ids = list.map(\.request.identifier).filter { $0.hasPrefix("signin-") }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func answerSignIn(_ event: CompanionEvent, username: String?, password: String?, code: String?) {
        guard let id = event.request else { return }
        workspace.answerSignIn(id, SignInAnswer(username: username, password: password, code: code, declined: false,
                                                from: "Mac"))
    }

    func declineSignIn(_ event: CompanionEvent) {
        guard let id = event.request else { return }
        workspace.answerSignIn(id, SignInAnswer(username: nil, password: nil, code: nil, declined: true, from: "Mac"))
    }

    // MARK: Pairing

    func refreshPhone() {
        pairedDevices = AuthorizedKeys().devices()
        let check = Task.detached(priority: .utility) { MacSSH.remoteLoginOn() }
        Task { remoteLoginOn = await check.value }
    }

    func startPairing() {
        pairing?.stop()
        let session = PairingSession()
        session.onChange = { [weak self, weak session] in
            guard let self, let session else { return }
            self.pairingTick += 1
            if case .paired(let name) = session.state {
                self.append("paired \(name)")
                self.refreshPhone()
            }
        }
        pairing = session
        session.start()
    }

    func stopPairing() {
        pairing?.stop()
        pairing = nil
    }

    func removeDevice(_ device: AuthorizedKeys.Device) {
        do {
            try AuthorizedKeys().remove(id: device.id)
            append("removed \(device.name)")
        } catch { append("could not remove \(device.name): \(error.localizedDescription)") }
        refreshPhone()
    }

    func openRemoteLoginSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!)
    }

    // MARK: Links (aos://)

    /// aos://allow-helper starts the helper permission, aos://pair opens pairing, aos://settings/<tab> a tab.
    func handle(url: URL) {
        guard url.scheme == "aos" else { return }
        switch url.host {
        case "allow-helper":
            Task { await allowHelper() }
        case "pair":
            UserDefaults.standard.set("iphone", forKey: "settingsTab")
            openSettingsWindow()
        case "settings":
            let tab = url.pathComponents.dropFirst().first ?? "general"
            UserDefaults.standard.set(tab, forKey: "settingsTab")
            openSettingsWindow()
        default:
            break
        }
        NSApp.activate()
    }

    // MARK: The workspace helper

    /// Asks the helper in a running workspace whether it may sign in.
    func checkHelper() async {
        guard workspace.host.isRunning, let ip = try? workspace.host.guestAddress() else { return }
        if helperState == .allowing { return }
        let status = await workspace.provisioner.helperStatus(host: ip)
        if helperState == .allowing { return }
        helperState = status == nil ? .unknown : (status?.trusted == true ? .allowed : .notAllowed)
    }

    /// Starts the workspace, shows its window and opens the place where the user allows the helper. The window
    /// shows what to do; `watchHelper` notices when it's done.
    func allowHelper() async {
        helperState = .checking
        do {
            let ip = try await workspace.bootAndPrepare(reason: "allowing the helper")
            guard let status = await workspace.provisioner.helperStatus(host: ip) else {
                helperState = .unavailable(String(localized: "The helper isn't installed in the workspace yet."))
                return
            }
            if status.trusted == true { helperState = .allowed; return }
            helperWasAdmin = try await workspace.provisioner.beginHelperPermission(host: ip)
            helperState = .allowing
            openWindow?(WindowID.workspace)
            NSApp.activate()
            await watchHelper(ip: ip)
        } catch {
            helperState = .unavailable(error.localizedDescription)
        }
    }

    /// Waits for the switch; when macOS asks for the password (its dialog in the guest), aOS enters the workspace
    /// account's password itself, so the user only flips the switch.
    private func watchHelper(ip: String) async {
        let deadline = Date().addingTimeInterval(600)
        var typedForDialog = false
        var typings = 0
        // The password goes in by itself only during the first setup, before any agent ever used the workspace.
        // Later an agent could have programs running there that wait for exactly this moment (a dialog of their
        // own, or a real one they asked for): then the person looks at the workspace and clicks "Enter the
        // workspace password" themselves.
        let automatic = !setup.isComplete
        while Date() < deadline, helperState == .allowing {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let poll = await workspace.provisioner.helperPermissionPoll(host: ip)
            if poll.trusted {
                await finishHelperPermission(ip: ip, allowed: true)
                return
            }
            if automatic && poll.passwordDialog && !typedForDialog && typings < 3 {
                try? await Task.sleep(nanoseconds: 1_200_000_000)  // the dialog takes the focus
                do {
                    try await workspace.typeGuestPasswordForSetup()
                    typedForDialog = true
                    typings += 1
                    append("entered the workspace password for the helper permission")
                } catch { append("could not enter the password: \(error.localizedDescription)") }
            } else if !poll.passwordDialog {
                typedForDialog = false
            }
        }
        if helperState == .allowing { await finishHelperPermission(ip: ip, allowed: false) }
    }

    func cancelHelperPermission() async {
        guard let ip = try? workspace.host.guestAddress() else { helperState = .notAllowed; return }
        await finishHelperPermission(ip: ip, allowed: false)
    }

    private func finishHelperPermission(ip: String, allowed: Bool) async {
        if let wasAdmin = helperWasAdmin {
            do {
                try await workspace.provisioner.endHelperPermission(host: ip, wasAdmin: wasAdmin)
            } catch { append("helper permission: \(error.localizedDescription)") }
            helperWasAdmin = nil
        }
        helperState = allowed ? .allowed : .notAllowed
        append(allowed ? "the workspace helper may sign in now" : "the helper permission was not given")
    }
}
