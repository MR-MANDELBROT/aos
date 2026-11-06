#if DEBUG
import Foundation
import UIKit

/// Sample data for screenshots and UI work: start the app with `-AOSDemo YES` (debug builds only).
/// `-AOSDemoTab overview|terminal|screen` picks the tab, `-AOSDemoSheet signin|signin-code|signin-none|signin-locked|
/// signin-off|approval|help|pairing|settings|lock|requests` opens a request or sheet. Nothing here touches the keychain
/// or the network.
enum Demo {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "AOSDemo") }
    static var tab: String? { UserDefaults.standard.string(forKey: "AOSDemoTab") }
    static var sheet: String? { UserDefaults.standard.string(forKey: "AOSDemoSheet") }
    /// `-AOSDemoUnpaired YES`: the welcome page.
    static var unpaired: Bool { UserDefaults.standard.bool(forKey: "AOSDemoUnpaired") }
    /// `-AOSScreenDirect HOST:PORT`: the workspace screen connects straight to a screen sharing server (the
    /// simulator reaches a workspace VM's address), with the login from the environment variables AOS_SCREEN_USER and
    /// AOS_SCREEN_PASSWORD. For testing the viewer against a real screensharingd.
    static var directScreen: (host: String, port: UInt16)? {
        guard let text = UserDefaults.standard.string(forKey: "AOSScreenDirect") else { return nil }
        let parts = text.split(separator: ":")
        return (String(parts[0]), parts.count > 1 ? UInt16(parts[1]) ?? 5900 : 5900)
    }

    struct Content {
        var mac: PairedMac
        var hosts: [SSHHost]
    }

    static func content() -> Content {
        let mac = PairedMac(name: "Max’s MacBook Pro", hosts: ["Maxs-MacBook-Pro.local", "192.168.178.24",
                                                              "maxs-macbook-pro.tail4c2a.ts.net"],
                            sshPort: 22, user: "max", hostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN8Rl2qwv75VjkzLHaW5OyZu4CaxGsZU2+cYoDrSFSrY",
                            hostKeyFingerprint: "SHA256:IKIpT5qrBHciGB6LMk+7fuTQHDnNluSkoLBSGY4SWMQ",
                            companionPath: CompanionCommand.defaultPath, lastHost: "Maxs-MacBook-Pro.local")
        let hosts = [
            SSHHost(label: "Raspberry Pi", host: "pi.local", user: "pi", auth: .deviceKey,
                    hostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN8Rl2qwv75VjkzLHaW5OyZu4CaxGsZU2+cYoDrSFSrY"),
            SSHHost(label: "", host: "lxhalle.in.tum.de", user: "ge12abc", auth: .password),
        ]
        return Content(mac: mac, hosts: hosts)
    }

    /// Bitwarden logins as the Mac offers them with a request (sample data).
    static let amazonLogins = [
        BitwardenLogin(id: "0b6d3f7e-1c2a-4e5b-9a8d-7c6b5a4f3e21", name: "Amazon", username: "max@marquart.dev", hasCode: false),
        BitwardenLogin(id: "4f2e8a1c-3b7d-4c9e-8f6a-1d2c3b4a5e6f", name: "Amazon Business", username: "einkauf@marquart.dev",
                       hasCode: true),
    ]
    static let githubLogins = [
        BitwardenLogin(id: "9c8b7a6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d", name: "GitHub", username: "mr-mandelbrot", hasCode: true),
    ]

    @MainActor
    static func start(_ connection: MacConnection, model: AppModel) {
        let server = MockCompanionServer()
        connection.startDemo(server)
        switch tab {
        case "terminal": model.tab = .terminal
        case "screen": model.tab = .screen
        default: model.tab = .overview
        }
        if let direct = directScreen {
            let env = ProcessInfo.processInfo.environment
            model.workspaceScreen.startDirect(host: direct.host, port: direct.port, username: env["AOS_SCREEN_USER"] ?? "",
                                              password: env["AOS_SCREEN_PASSWORD"] ?? "",
                                              options: ScreenOptions(settings: model.settings, cellular: false))
        } else if let image = workspacePicture() {
            model.workspaceScreen.showDemo(image)
        }
        if let image = macPicture() { model.macScreen.showDemo(image) }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            switch sheet {
            case "signin":
                server.emit(.signIn(SignInRequest(id: "demo-1", agent: "Claude Code", host: "www.amazon.de",
                                                  purpose: "Die Rechnung vom Oktober herunterladen",
                                                  expires: Date().addingTimeInterval(4 * 60 + 32),
                                                  logins: amazonLogins, bitwarden: .unlocked)))
            case "signin-code":
                server.emit(.signIn(SignInRequest(id: "demo-3", agent: "Claude Code", host: "github.com",
                                                  purpose: "Mit dem Code aus der App anmelden",
                                                  expires: Date().addingTimeInterval(2 * 60 + 10), field: .code,
                                                  logins: githubLogins, bitwarden: .unlocked)))
            case "signin-locked":
                server.emit(.signIn(SignInRequest(id: "demo-5", agent: "Claude Code", host: "www.amazon.de",
                                                  purpose: "Die Rechnung vom Oktober herunterladen",
                                                  expires: Date().addingTimeInterval(4 * 60), bitwarden: .locked)))
            case "signin-off":
                server.emit(.signIn(SignInRequest(id: "demo-6", agent: "Codex", host: "portal.example-energie.de",
                                                  purpose: "Zählerstand eintragen",
                                                  expires: Date().addingTimeInterval(3 * 60), bitwarden: .off)))
            case "approval":
                server.emit(.approval(ApprovalRequest(id: "demo-4", agent: "Codex",
                                                      purpose: "Die Rechnungen vom Oktober herunterladen",
                                                      minutes: 30, expires: Date().addingTimeInterval(4 * 60 + 50))))
            case "signin-none":
                server.emit(.signIn(SignInRequest(id: "demo-2", agent: "Codex", host: "portal.example-energie.de",
                                                  purpose: "Zählerstand eintragen",
                                                  expires: Date().addingTimeInterval(3 * 60), bitwarden: .unlocked)))
            case "help":
                server.emit(.help(HelpRequest(id: "help-1", agent: "Claude Code",
                                              purpose: "Bitte das Captcha auf der Anmeldeseite lösen",
                                              region: .init(x: 470, y: 430, width: 340, height: 120))))
            case "pairing": model.isPairingPresented = true
            case "lock": model.lock.lockForDemo()
            case "requests":
                server.emit(.signIn(SignInRequest(id: "demo-1", agent: "Claude Code", host: "www.amazon.de",
                                                  purpose: "Die Rechnung vom Oktober herunterladen",
                                                  expires: Date().addingTimeInterval(4 * 60 + 32),
                                                  logins: amazonLogins, bitwarden: .unlocked)))
                try? await Task.sleep(for: .milliseconds(300))
                model.closeQuestionSheet()
            default: break
            }
        }
    }

    static let terminalText = """
    Last login: Thu Nov  6 08:12:44 on ttys002\r
    \u{1B}[1;32mmax@Maxs-MacBook-Pro\u{1B}[0m \u{1B}[1;34m~\u{1B}[0m % cd Developer/aos\r
    \u{1B}[1;32mmax@Maxs-MacBook-Pro\u{1B}[0m \u{1B}[1;34m~/Developer/aos\u{1B}[0m % git status --short\r
     M iOS/Sources/App/AppModel.swift\r
    ?? iOS/Sources/Screen/\r
    \u{1B}[1;32mmax@Maxs-MacBook-Pro\u{1B}[0m \u{1B}[1;34m~/Developer/aos\u{1B}[0m % uptime\r
    08:15  up 3 days, 22:41, 2 users, load averages: 1.42 1.37 1.29\r
    \u{1B}[1;32mmax@Maxs-MacBook-Pro\u{1B}[0m \u{1B}[1;34m~/Developer/aos\u{1B}[0m %
    """

    // MARK: Pictures

    /// A workspace screen (1280x800): a browser with a sign-in page and a captcha.
    static func workspacePicture() -> CGImage? {
        render(width: 1280, height: 800) { ctx, size in
            desktop(ctx, size, top: UIColor(red: 0.30, green: 0.32, blue: 0.88, alpha: 1),
                    bottom: UIColor(red: 0.70, green: 0.73, blue: 1, alpha: 1))
            let window = CGRect(x: 140, y: 70, width: 1000, height: 660)
            browserWindow(ctx, window, url: "www.amazon.de/ap/signin")
            let card = CGRect(x: 440, y: 170, width: 400, height: 420)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.addPath(UIBezierPath(roundedRect: card, cornerRadius: 12).cgPath)
            ctx.fillPath()
            text("Anmelden", at: CGPoint(x: 470, y: 195), size: 28, weight: .bold)
            field(CGRect(x: 470, y: 260, width: 340, height: 44), "max@marquart.dev")
            field(CGRect(x: 470, y: 320, width: 340, height: 44), "••••••••••••")
            ctx.setFillColor(UIColor(red: 1, green: 0.85, blue: 0.4, alpha: 1).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: CGRect(x: 470, y: 380, width: 340, height: 40), cornerRadius: 8).cgPath)
            ctx.fillPath()
            text("Weiter", at: CGPoint(x: 612, y: 389), size: 17, weight: .semibold)
            ctx.setStrokeColor(UIColor(white: 0.75, alpha: 1).cgColor)
            ctx.setLineWidth(1.5)
            ctx.addPath(UIBezierPath(roundedRect: CGRect(x: 470, y: 440, width: 340, height: 100), cornerRadius: 6).cgPath)
            ctx.strokePath()
            ctx.setStrokeColor(UIColor(white: 0.45, alpha: 1).cgColor)
            ctx.stroke(CGRect(x: 490, y: 474, width: 30, height: 30))
            text("Ich bin kein Roboter", at: CGPoint(x: 534, y: 478), size: 17, weight: .regular)
        }
    }

    /// The Mac's own screen (1512x982): the desktop with a Terminal window.
    static func macPicture() -> CGImage? {
        render(width: 1512, height: 982) { ctx, size in
            desktop(ctx, size, top: UIColor(red: 0.15, green: 0.18, blue: 0.35, alpha: 1),
                    bottom: UIColor(red: 0.24, green: 0.85, blue: 0.71, alpha: 1))
            let window = CGRect(x: 260, y: 160, width: 980, height: 600)
            ctx.setFillColor(UIColor(white: 0.12, alpha: 0.96).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: window, cornerRadius: 14).cgPath)
            ctx.fillPath()
            trafficLights(ctx, at: CGPoint(x: window.minX + 22, y: window.minY + 20))
            for (i, line) in ["Last login: Thu Nov  6 08:12:44", "max@Maxs-MacBook-Pro ~ % claude",
                              "✻ Welcome to Claude Code", "> Lade die Rechnung von Amazon herunterladen"].enumerated() {
                text(line, at: CGPoint(x: window.minX + 24, y: window.minY + 60 + CGFloat(i) * 30), size: 19,
                     weight: .regular, color: UIColor(white: 0.9, alpha: 1), mono: true)
            }
        }
    }

    private static func render(width: Int, height: Int, draw: (CGContext, CGSize) -> Void) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in draw(context.cgContext, size) }
        return image.cgImage
    }

    private static func desktop(_ ctx: CGContext, _ size: CGSize, top: UIColor, bottom: UIColor) {
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        ctx.setFillColor(UIColor(white: 1, alpha: 0.55).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 30))
        text("  Chrome   Ablage   Bearbeiten   Darstellung", at: CGPoint(x: 10, y: 6), size: 15, weight: .medium)
    }

    private static func browserWindow(_ ctx: CGContext, _ frame: CGRect, url: String) {
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 30, color: UIColor(white: 0, alpha: 0.35).cgColor)
        ctx.setFillColor(UIColor(white: 0.97, alpha: 1).cgColor)
        ctx.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 12).cgPath)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)
        trafficLights(ctx, at: CGPoint(x: frame.minX + 20, y: frame.minY + 18))
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.addPath(UIBezierPath(roundedRect: CGRect(x: frame.minX + 120, y: frame.minY + 10, width: frame.width - 240,
                                                     height: 28), cornerRadius: 14).cgPath)
        ctx.fillPath()
        text(url, at: CGPoint(x: frame.minX + 140, y: frame.minY + 15), size: 14, weight: .regular,
             color: UIColor(white: 0.35, alpha: 1))
        ctx.setFillColor(UIColor(white: 0.92, alpha: 1).cgColor)
        ctx.fill(CGRect(x: frame.minX, y: frame.minY + 48, width: frame.width, height: frame.height - 60))
    }

    private static func trafficLights(_ ctx: CGContext, at origin: CGPoint) {
        for (i, color) in [UIColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: origin.x + CGFloat(i) * 20, y: origin.y, width: 12, height: 12))
        }
    }

    private static func field(_ rect: CGRect, _ value: String) {
        let ctx = UIGraphicsGetCurrentContext()!
        ctx.setStrokeColor(UIColor(white: 0.7, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 6).cgPath)
        ctx.strokePath()
        text(value, at: CGPoint(x: rect.minX + 12, y: rect.minY + 12), size: 17, weight: .regular)
    }

    private static func text(_ string: String, at point: CGPoint, size: CGFloat, weight: UIFont.Weight,
                             color: UIColor = UIColor(white: 0.1, alpha: 1), mono: Bool = false) {
        let font = mono ? UIFont.monospacedSystemFont(ofSize: size, weight: weight) : UIFont.systemFont(ofSize: size, weight: weight)
        (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
}

extension MacConnection {
    /// The demo: "connected", with the mock companion in memory.
    func startDemo(_ server: MockCompanionServer) {
        Task { await runDemo(server) }
    }
}
#endif
