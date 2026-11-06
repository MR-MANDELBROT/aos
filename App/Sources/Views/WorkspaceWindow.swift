import AOSKit
import AppKit
import SwiftUI

/// The workspace screen. A bar under the title guides the user (setup steps, the agent's help requests, allowing
/// the helper); it sits above the screen and never covers it.
struct WorkspaceWindow: View {
    @EnvironmentObject var model: AppModel
    /// Observed here too, so the bar follows the setup's step and activity.
    @EnvironmentObject var setup: SetupController
    @State private var coordinator: VMDisplay.Coordinator?
    /// The bar's height as last laid out: the window grows and shrinks by it, so the screen keeps its size.
    @State private var barHeight: CGFloat = 0
    @StateObject private var fitter = WindowFitter()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) { guide }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    barHeight = height
                    fitter.bar = height
                    fitter.fit(animate: true)
                }
            screen
        }
        .background(WindowAccessor { fitter.attach($0) })
        .frame(minWidth: 800, minHeight: 560)
        .onAppear { setup.beginScreenSharing() }
        // The user working in the window keeps the workspace open like the agent's requests do.
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            guard coordinator?.view?.window?.isKeyWindow == true,
                  let any = CGEventType(rawValue: ~0),
                  CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any) < 120 else { return }
            model.workspace.noteActivity()
        }
        .toolbar {
            if setup.isComplete {
                ToolbarItem(placement: .primaryAction) {
                    Button("Exchange Folder", systemImage: "folder") { NSWorkspace.shared.open(model.paths.exchange) }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Close Workspace", systemImage: "power") { Task { _ = await model.workspace.close() } }
                        .disabled(model.workspace.host.virtualMachine == nil)
                }
            }
        }
        .navigationTitle(Text("Workspace"))
        .navigationSubtitle(statusText)
    }

    @ViewBuilder var screen: some View {
        if let machine = model.workspace.host.virtualMachine {
            VMDisplay(machine: machine) { c in DispatchQueue.main.async { coordinator = c; setup.display = c } }
                .aspectRatio(1280.0 / 800.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("The workspace is off", systemImage: "macwindow")
            } description: {
                Text(setup.isComplete ? "It starts when your agent opens it." : "It starts for the next setup step.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: The bar

    @ViewBuilder var guide: some View {
        if let help = model.help {
            bar(symbol: "hand.raised.fill", tint: .orange, context: "Your agent", title: "Your agent asks for your help", detail: help.purpose) {
                Button("I can't do this") {
                    model.finishHelp(help.id, "The user could not do it. Ask them in the chat how to continue.")
                }
                Button("Done") {
                    model.finishHelp(help.id, "The user is done. Continue with a screenshot.")
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        } else if model.helperState == .allowing {
            bar(symbol: "person.badge.key.fill", tint: BrandColor.indigo,
                context: setup.isComplete ? "Sign-ins" : "Setup · aOS Helper",
                title: "Switch on aOS Helper below",
                detail: setup.isComplete
                    ? String(localized: "If macOS asks, click Open System Settings, then switch on aOS Helper. When macOS asks for the password, click Enter Password.")
                    : String(localized: "If macOS asks, click Open System Settings, then switch on aOS Helper. When macOS asks for the password, click Enter Password. Then the setup continues by itself.")) {
                Button("Not Now") { Task { await model.cancelHelperPermission() } }
                Button("Enter Password") { setup.typeGuestPassword(into: coordinator) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        } else if setup.sharingPhase == .allowingHelper && !setup.isComplete {
            bar(symbol: "person.badge.key.fill", tint: BrandColor.indigo, context: "Setup · aOS Helper", title: "One moment",
                detail: String(localized: "aOS prepares the switch for aOS Helper. Type nothing yet."), busy: true) {}
        } else if setup.step == .screenSharing && !setup.isComplete {
            sharingBar
        }
    }

    @ViewBuilder var sharingBar: some View {
        switch setup.sharingPhase {
        case .starting:
            if case .failed(let why) = setup.activity {
                bar(symbol: "exclamationmark.triangle.fill", tint: .orange, context: "Setup · Screen sharing", title: "The workspace didn't start", detail: why) {
                    Button("Try Again") { setup.beginScreenSharing() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            } else if !setup.isBusy && model.workspace.host.virtualMachine == nil {
                bar(symbol: "power", tint: BrandColor.indigo, context: "Setup · Screen sharing", title: "The workspace is off",
                    detail: String(localized: "Start it for this step.")) {
                    Button("Start the Workspace") { setup.beginScreenSharing() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            } else {
                bar(symbol: "hourglass", tint: BrandColor.indigo, context: "Setup · Screen sharing", title: "Please wait, don't click anything yet",
                    detail: String(localized: "The workspace starts and then opens System Settings at Sharing. This takes about a minute."),
                    busy: true) {}
            }
        case .waitingForSwitch:
            bar(symbol: "rectangle.on.rectangle", tint: BrandColor.indigo, context: "Setup · Screen sharing", title: "Switch on Screen Sharing below",
                detail: setup.sharingProblem.map { String(localized: "That didn't work yet: \($0)") }
                    ?? String(localized: "When macOS asks for the password, click Enter Password. aOS notices by itself when screen sharing is on."),
                warning: setup.sharingProblem != nil) {
                Button("Enter Password") { setup.typeGuestPassword(into: coordinator) }
                    .buttonStyle(.borderedProminent)
                Button("Check") { setup.checkScreenSharing() }.disabled(setup.isBusy)
            }
        case .checking:
            bar(symbol: "rectangle.on.rectangle", tint: BrandColor.indigo, context: "Setup · Screen sharing", title: "Checking screen sharing",
                detail: String(localized: "A few seconds. Then the setup continues."), busy: true) {}
        case .verified, .allowingHelper:
            bar(symbol: "checkmark.circle.fill", tint: .green, context: "Setup · Screen sharing", title: "Screen sharing is on",
                detail: String(localized: "Continue in the setup window.")) {
                Button("Back to Setup") { model.openWindow?(WindowID.setup); NSApp.activate() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// A full-width strip under the title bar, in the window's chrome, always the same height (no jumping between
    /// states): a tinted symbol (or progress), where the user is, what to do, and the buttons.
    func bar(symbol: String, tint: Color, context: LocalizedStringKey, title: LocalizedStringKey, detail: String,
             busy: Bool = false, warning: Bool = false, @ViewBuilder actions: () -> some View) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.opacity(0.16))
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(tint)
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(context).font(.caption.weight(.semibold)).foregroundStyle(tint).textCase(.uppercase)
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(warning ? .orange : .secondary)
                    .textSelection(.enabled).lineLimit(2)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) { actions() }
                .controlSize(.large)
                .tint(tint == .green || tint == .orange ? tint : BrandColor.indigo)
        }
        .padding(.horizontal, 20)
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    static let barHeight: CGFloat = 86

    var statusText: String {
        if let purpose = model.status?.leasePurpose, model.vmPhase == .running { return String(localized: "Open: \(purpose)") }
        return model.vmPhase.displayName
    }
}

/// The Claude Code session's terminal.
struct SessionWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SessionTerminal(socketURL: model.paths.run.appendingPathComponent("session.sock"))
            .padding(8)
            .frame(minWidth: 760, minHeight: 480)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Restart", systemImage: "arrow.clockwise") { SessionAgent.restart(paths: model.paths) }
                }
            }
            .navigationTitle(Text("Session \"\(model.settings.sessionName)\""))
            .navigationSubtitle(model.session?.state.displayName ?? String(localized: "Off"))
    }
}

extension VMHost.Phase {
    /// For window subtitles and the menu.
    var displayName: String {
        switch self {
        case .stopped: return String(localized: "Off")
        case .starting: return String(localized: "Starting")
        case .running: return String(localized: "Running")
        case .pausing, .paused: return String(localized: "Paused")
        case .suspending, .stopping: return String(localized: "Shutting down")
        case .installing: return String(localized: "Installing macOS")
        case .error: return String(localized: "Error")
        }
    }
}

extension SessionStatus.State {
    var displayName: String {
        switch self {
        case .starting: return String(localized: "Starting")
        case .running: return String(localized: "Running")
        case .waitingForNetwork: return String(localized: "Waiting for the network")
        case .needsLogin: return String(localized: "Sign in to Claude Code")
        case .needsAttention: return String(localized: "Claude Code asks something")
        case .missingClaude: return String(localized: "Claude Code is not installed")
        case .restarting: return String(localized: "Restarting")
        case .stopped: return String(localized: "Off")
        case .failed: return String(localized: "Error")
        }
    }
}

/// Keeps the workspace window at the shape of what it shows: the bar on top and the workspace's 1280 x 800 screen
/// with 10 pt around it, so there are no black bars at the sides. Fits when the window appears, when the bar comes
/// or goes, and after the user resized it (the width leads).
@MainActor
final class WindowFitter: ObservableObject {
    weak var window: NSWindow?
    var bar: CGFloat = 0
    private var observer: NSObjectProtocol?

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window,
                                                          queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fit(animate: true) }
        }
        fit(animate: false)
    }

    func fit(animate: Bool) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frame
        let chrome = frame.height - window.contentRect(forFrameRect: frame).height
        var screenWidth = max(frame.width - 20, 400)
        var contentHeight = screenWidth * 800 / 1280 + 20 + bar
        if let visible = window.screen?.visibleFrame, contentHeight + chrome > visible.height {
            contentHeight = visible.height - chrome
            screenWidth = (contentHeight - 20 - bar) * 1280 / 800
        }
        var fitted = frame
        fitted.size = NSSize(width: (screenWidth + 20).rounded(), height: (contentHeight + chrome).rounded())
        fitted.origin.y = frame.maxY - fitted.height
        fitted.origin.x = frame.midX - fitted.width / 2
        if let visible = window.screen?.visibleFrame {
            fitted.origin.x = min(max(fitted.origin.x, visible.minX), visible.maxX - fitted.width)
            fitted.origin.y = min(max(fitted.origin.y, visible.minY), visible.maxY - fitted.height)
        }
        guard abs(fitted.width - frame.width) > 1 || abs(fitted.height - frame.height) > 1
              || abs(fitted.origin.y - frame.origin.y) > 1 else { return }
        window.setFrame(fitted, display: true, animate: animate)
    }
}

/// Hands the hosting NSWindow to `found` once the view is in it.
struct WindowAccessor: NSViewRepresentable {
    var found: (NSWindow) -> Void

    init(_ found: @escaping (NSWindow) -> Void) { self.found = found }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in if let w = view?.window { found(w) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in if let w = view?.window { found(w) } }
    }
}
