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

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) { guide }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    let delta = height - barHeight
                    barHeight = height
                    resizeWindow(by: delta, bar: height)
                }
            screen
        }
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
                Button("Check") { setup.checkScreenSharing() }.disabled(setup.isBusy)
                Button("Enter Password") { setup.typeGuestPassword(into: coordinator) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
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

    /// Grows (or shrinks) the window by the bar's height at its bottom edge, so the workspace's screen keeps its
    /// size instead of shrinking into black bars.
    func resizeWindow(by delta: CGFloat, bar: CGFloat) {
        guard abs(delta) > 0.5,
              let window = coordinator?.view?.window
                ?? NSApp.windows.first(where: { $0.identifier?.rawValue.contains(WindowID.workspace) == true })
        else { return }
        var frame = window.frame
        frame.size.height += delta
        frame.origin.y -= delta
        if let visible = window.screen?.visibleFrame {
            if frame.height > visible.height { frame.size.height = visible.height }
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
        }
        // As wide as the screen in it at that height (1280 x 800 with 10 pt around it): no bars at the sides.
        let content = window.contentRect(forFrameRect: frame)
        let screenHeight = content.height - bar - 20
        if screenHeight > 200 {
            let width = screenHeight * 1280 / 800 + 20 + (frame.width - content.width)
            frame.origin.x += (frame.width - width) / 2
            frame.size.width = width
        }
        window.setFrame(frame, display: true, animate: true)
    }

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
