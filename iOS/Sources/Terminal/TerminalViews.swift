import SwiftTerm
import SwiftUI

/// The Terminal tab: the terminal sessions on the Mac, a new one, and the terminal that shows one of them.
struct TerminalTab: View {
    @Environment(AppModel.self) private var model
    @State private var path: [TerminalSession.Target] = []
    @State private var ending: MacTermSession?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let mac = model.activeMac {
                    Section {
                        Button {
                            newSession(on: mac)
                        } label: {
                            Label("New Session", systemImage: "plus.circle.fill")
                                .font(.body.weight(.semibold))
                        }
                    } footer: {
                        Text("Starts another shell on \(mac.name). The others keep running.")
                    }
                    Section {
                        if let note = connectionNote {
                            Label(note.text, systemImage: note.symbol)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if model.macSessions.loaded, model.macSessions.sessions.isEmpty, connectionNote == nil {
                            Text("No sessions on the Mac. New Session starts one.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.macSessions.sessions) { session in
                            Button {
                                open(session, on: mac)
                            } label: {
                                MacSessionRow(session: session, home: "/Users/\(mac.user)", holder: holder(of: session, on: mac))
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("End", systemImage: "xmark.circle", role: .destructive) { ending = session }
                            }
                            .contextMenu {
                                Button("Open Session", systemImage: "apple.terminal") { open(session, on: mac) }
                                Button("End Session", systemImage: "xmark.circle", role: .destructive) { ending = session }
                            }
                        }
                    } header: {
                        Text("Sessions on the Mac")
                    } footer: {
                        Text("They keep running when the connection drops, also with the app closed, and this iPhone picks up where it left off. End the ones you no longer need.")
                    }
                }
            }
            .navigationTitle("Terminal")
            .navigationDestination(for: TerminalSession.Target.self) { target in
                TerminalScreen(session: model.terminal(for: target))
            }
            .overlay {
                if model.activeMac == nil {
                    ContentUnavailableView {
                        Label("No Mac yet", systemImage: "apple.terminal")
                    } description: {
                        Text("Pair your Mac to open a terminal on it.")
                    } actions: {
                        Button("Pair with your Mac") { model.isPairingPresented = true }.buttonStyle(.glass)
                    }
                }
            }
            .onAppear {
                #if DEBUG
                if model.isDemo, Demo.tab == "terminal", let mac = model.activeMac, path.isEmpty, Demo.sheet == "shell" {
                    path = [.mac(mac.id)]
                }
                #endif
            }
            .task(id: model.connection?.isConnected == true) {
                // While the list is on screen: now and every 10 s (what runs in the sessions changes).
                while !Task.isCancelled {
                    await refreshSessions()
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            .refreshable {
                model.connection?.retryNow()
                await refreshSessions()
            }
            .onChange(of: model.openTerminal, initial: true) { _, target in
                guard let target else { return }
                model.openTerminal = nil
                path = [target]
            }
            .confirmationDialog("End this session?", isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
                                titleVisibility: .visible, presenting: ending) { session in
                Button("End Session", role: .destructive) {
                    Task {
                        await model.macSessions.end(session, model: model)
                        ending = nil
                    }
                }
            } message: { _ in
                Text("The shell on the Mac ends, and so do the programs running in it.")
            }
        }
    }

    private func refreshSessions() async {
        #if DEBUG
        if model.isDemo { model.macSessions.showDemo(phoneID: model.deviceKey?.phoneID); return }
        #endif
        await model.macSessions.load(model: model)
    }

    /// Why the list may be old or empty: the Mac sleeps, isn't reachable, or can't hold sessions.
    private var connectionNote: (text: String, symbol: String)? {
        guard !model.isDemo, let connection = model.connection else { return nil }
        if let since = connection.sleepingSince {
            return (String(localized: "The Mac is sleeping since \(since.formatted(date: .omitted, time: .shortened)). The sessions continue when it wakes."),
                    "moon.zzz")
        }
        switch connection.state {
        case .connected:
            if let hello = connection.hello, connection.companionState == .ready, !hello.features.contains("term") {
                return (String(localized: "Update aOS on the Mac to keep terminals when the connection drops."), "arrow.down.circle")
            }
            return nil
        case .idle, .connecting:
            return (String(localized: "Connecting to the Mac …"), "arrow.triangle.2.circlepath")
        case .unreachable, .needsAttention:
            return (String(localized: "The Mac isn't reachable right now. The sessions keep running there."), "wifi.slash")
        }
    }

    private func holder(of session: MacTermSession, on mac: PairedMac) -> MacTermSession.Holder {
        let target = TerminalSession.Target.mac(mac.id)
        let terminal = model.terminals[target]
        return session.holder(shown: terminal?.isActive == true ? terminal?.holderID : nil,
                              phoneID: model.deviceKey?.phoneID,
                              last: terminal?.holderID ?? TerminalSession.storedHolderID(for: target))
    }

    /// The terminal shows that session (the one it showed keeps running).
    private func open(_ session: MacTermSession, on mac: PairedMac) {
        let terminal = model.terminal(for: .mac(mac.id))
        path = [.mac(mac.id)]
        if !model.isDemo { terminal.switchTo(session: session.id) }
    }

    private func newSession(on mac: PairedMac) {
        let terminal = model.terminal(for: .mac(mac.id))
        if !model.isDemo { terminal.startNewSession() }
        path = [.mac(mac.id)]
    }
}

/// The terminal sessions on the paired Mac (`aos-companion term list`).
@MainActor @Observable
final class MacSessionList {
    private(set) var sessions: [MacTermSession] = []
    /// The Mac sent its list at least once (an empty list then means: none).
    private(set) var loaded = false

    func load(model: AppModel) async {
        guard let mac = model.activeMac, let ssh = model.connection?.ssh, ssh.isActive,
              let data = try? await ssh.run(TermAttach.list(companion: mac.companionPath)),
              let list = TermAttach.sessions(fromList: data) else { return }
        sessions = TermAttach.ordered(list)
        loaded = true
    }

    func end(_ session: MacTermSession, model: AppModel) async {
        guard let mac = model.activeMac else { return }
        if let terminal = model.terminals[.mac(mac.id)], terminal.holderID == session.id {
            await terminal.endSession()
        } else if let ssh = model.connection?.ssh, ssh.isActive,
                  let command = TermAttach.end(companion: mac.companionPath, id: session.id) {
            _ = try? await ssh.run(command)
        }
        sessions.removeAll { $0.id == session.id }
        try? await Task.sleep(for: .milliseconds(400))
        await load(model: model)
    }

    /// The name of a session in menus and titles: its title, or the program and the folder.
    func name(of id: String?, home: String) -> String? {
        guard let id, let session = sessions.first(where: { $0.id == id }) else { return nil }
        return session.title ?? session.place(home: home)
    }

    #if DEBUG
    /// Claude Code open on this iPhone, a shell nobody has open, one on the Mac's own Terminal.
    func showDemo(phoneID: String?) {
        let now = Date()
        sessions = [
            MacTermSession(id: "3fa9c1d2", attached: true, since: now.addingTimeInterval(-600), created: now.addingTimeInterval(-7200),
                           from: "ssh 192.168.178.31", client: phoneID, command: "claude", cwd: "/Users/max/Developer/aos"),
            MacTermSession(id: "7b2e90aa", attached: false, since: now.addingTimeInterval(-3 * 3600),
                           created: now.addingTimeInterval(-5 * 3600), command: "zsh", cwd: "/Users/max"),
            MacTermSession(id: "c41d07e5", attached: true, since: now.addingTimeInterval(-1200), created: now.addingTimeInterval(-1800),
                           from: "local", command: "htop", cwd: "/Users/max"),
        ]
        sessions = TermAttach.ordered(sessions)
        loaded = true
    }
    #endif
}

private struct MacSessionRow: View {
    let session: MacTermSession
    let home: String
    let holder: MacTermSession.Holder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: holder == .nobody ? "apple.terminal" : "apple.terminal.fill")
                .foregroundStyle(BrandColor.indigo).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title ?? session.place(home: home)).lineLimit(1)
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        switch holder {
        case .here:
            return String(localized: "Open on this iPhone")
        case .elsewhere(let from):
            // `term attach` in a terminal on the Mac itself says "local".
            if from == "local" { return String(localized: "Open in a terminal on the Mac") }
            return from.map { String(localized: "Open on another device (\($0))") } ?? String(localized: "Open on another device")
        case .nobody:
            let time = session.since.map {
                $0.formatted(date: Calendar.current.isDateInToday($0) ? .omitted : .abbreviated, time: .shortened)
            } ?? ""
            return time.isEmpty ? String(localized: "Not open anywhere") : String(localized: "Not open anywhere since \(time)")
        }
    }
}

// MARK: - The terminal

struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let session: TerminalSession
    @State private var visible = false

    var body: some View {
        ZStack {
            TerminalViewRepresentable(view: session.view)
                .ignoresSafeArea(.container, edges: .bottom)
            switch session.phase {
            case .connecting:
                ProgressView("Connecting …").padding(20).glassEffect(in: RoundedRectangle(cornerRadius: 20))
            case .failed(let message):
                StateOverlay(symbol: "exclamationmark.triangle", text: message, action: "Try again") { connect() }
            case .ended:
                switch session.endReason {
                case .taken:
                    StateOverlay(symbol: "rectangle.portrait.and.arrow.right",
                                 text: String(localized: "This session is open on another device now. It keeps running on the Mac."),
                                 action: "Open It Here") { connect() }
                case .exited:
                    StateOverlay(symbol: "power", text: String(localized: "The shell ended."), action: "New Session") { newSession() }
                case .ended:
                    StateOverlay(symbol: "power", text: String(localized: "The session was ended."), action: "New Session") {
                        newSession()
                    }
                case .closed:
                    StateOverlay(symbol: "power", text: String(localized: "The session ended."), action: "Connect again") { connect() }
                }
            default:
                EmptyView()
            }
        }
        .overlay(alignment: .top) {
            if session.phase == .reconnecting {
                Label(macSleeps ? "The Mac is sleeping. The session continues when it wakes."
                                : "Reconnecting … The session keeps running on the Mac.",
                      systemImage: macSleeps ? "moon.zzz" : "arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(in: Capsule())
                    .padding(.top, 10)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            } else if let notice = session.notice {
                Text(notice.text)
                    .font(.callout.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .glassEffect(in: Capsule())
                    .padding(.top, 10)
                    .id(notice.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.2), value: session.notice)
        .animation(.snappy(duration: 0.2), value: session.phase)
        .navigationTitle(session.title)
        .navigationSubtitle(model.macSessions.name(of: session.holderID, home: home) ?? "")
        .navigationBarTitleDisplayMode(.inline)
        // The terminal gets the rows the tab bar would take.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(session.keyboardShown ? "Hide Keyboard" : "Show Keyboard",
                       systemImage: session.keyboardShown ? "keyboard.chevron.compact.down" : "keyboard") {
                    session.toggleKeyboard()
                }
                TerminalMenu(session: session, home: home) { newSession() }
            }
        }
        .alert(pasteTitle, isPresented: Binding(get: { session.pendingPaste != nil }, set: { if !$0 { session.pendingPaste = nil } }),
               presenting: session.pendingPaste) { text in
            Button("Paste") { session.confirmPaste(text) }
            Button("Cancel", role: .cancel) { session.pendingPaste = nil }
        } message: { _ in
            Text("The shell runs each line as soon as it arrives.")
        }
        .onAppear {
            visible = true
            session.setFontSize(model.settings.terminalFontSize)
            session.view.keyBar.arrows = model.settings.terminalArrowKeys
            session.view.swipeArrows = model.settings.terminalSwipeArrows
        }
        .onDisappear { visible = false }
        .onChange(of: session.fontSize) { _, size in model.settings.terminalFontSize = Double(size) }
        .onChange(of: model.settings.terminalArrowKeys) { _, arrows in session.view.keyBar.arrows = arrows }
        .onChange(of: model.settings.terminalSwipeArrows) { _, on in session.view.swipeArrows = on }
        .onChange(of: keepsScreenOn, initial: true) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
        // A new session shows up in the menu's list once it runs.
        .onChange(of: session.phase) { _, phase in
            if phase == .connected, !model.isDemo { Task { await model.macSessions.load(model: model) } }
        }
        .task {
            if session.phase == .idle { connect() }
            if !model.isDemo { await model.macSessions.load(model: model) }
        }
    }

    private var home: String { model.activeMac.map { "/Users/\($0.user)" } ?? "" }

    private var macSleeps: Bool { model.connection?.sleepingSince != nil }

    /// While the terminal is on screen and connected, if the person wants that.
    private var keepsScreenOn: Bool {
        visible && scenePhase == .active && session.phase == .connected && model.settings.terminalKeepsScreenOn
    }

    private var pasteTitle: String {
        let lines = session.pendingPaste?.split(whereSeparator: \.isNewline).count ?? 0
        return String(localized: "Paste \(lines) lines?")
    }

    private func connect() {
        Task {
            #if DEBUG
            if model.isDemo {
                showDemo()
                return
            }
            #endif
            if let connection = model.connection { await session.connect(mac: connection) }
        }
    }

    private func newSession() {
        #if DEBUG
        if model.isDemo {
            showDemo()
            return
        }
        #endif
        session.startNewSession()
    }

    #if DEBUG
    private func showDemo() {
        session.showDemo(Demo.terminalText)
        // -AOSDemoTerminal selection|keys|menu: states of the terminal for screenshots
        if let state = UserDefaults.standard.string(forKey: "AOSDemoTerminal") {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                session.view.showDemoState(state)
            }
        }
    }
    #endif
}

private struct StateOverlay: View {
    let symbol: String
    let text: String
    let action: LocalizedStringKey
    let perform: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center)
            Button(action, action: perform).buttonStyle(.glassProminent)
        }
        .padding(24)
        .frame(maxWidth: 340)
        .glassEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding()
    }
}

/// The terminal's menu: copying, text size, keeping the screen on, and the Mac's sessions (a new one, another one,
/// ending this one).
private struct TerminalMenu: View {
    @Environment(AppModel.self) private var model
    let session: TerminalSession
    let home: String
    let newSession: () -> Void
    @State private var confirmEnd = false

    /// Something to end: the session on the Mac, or a plain shell (an older aOS on the Mac).
    private var canEnd: Bool { session.holdsSession ? session.holderID != nil : session.isActive }

    private var others: [MacTermSession] { model.macSessions.sessions.filter { $0.id != session.holderID } }

    var body: some View {
        menu
            .confirmationDialog("End this session?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End Session", role: .destructive) { Task { await session.endSession() } }
            } message: {
                Text("The shell on the Mac ends, and so do the programs running in it.")
            }
    }

    private var menu: some View {
        Menu {
            Section {
                Button("Copy Screen", systemImage: "doc.on.doc") { session.copyScreen() }
                Button("Copy Last Output", systemImage: "text.line.last.and.arrowtriangle.forward") { session.copyLastOutput() }
                Button("Select All", systemImage: "selection.pin.in.out") { session.view.selectAll(nil) }
            }
            Section("Text Size") {
                ControlGroup {
                    Button("Smaller", systemImage: "textformat.size.smaller") { session.adjustFontSize(by: -1) }
                    Button("Default", systemImage: "textformat.size") { session.adjustFontSize(to: TerminalFontSize.standard) }
                    Button("Bigger", systemImage: "textformat.size.larger") { session.adjustFontSize(by: 1) }
                }
            }
            Section {
                Toggle("Keep Screen On", systemImage: "sun.max", isOn: Binding(
                    get: { model.settings.terminalKeepsScreenOn }, set: { model.settings.terminalKeepsScreenOn = $0 }))
            }
            Section {
                Button("New Session", systemImage: "plus") { newSession() }
                if !others.isEmpty {
                    Menu("Switch Session", systemImage: "rectangle.stack") {
                        ForEach(others) { other in
                            Button(other.title ?? other.place(home: home)) { session.switchTo(session: other.id) }
                        }
                    }
                }
                if canEnd {
                    Button("End Session", systemImage: "xmark.circle", role: .destructive) { confirmEnd = true }
                }
            } footer: {
                Text("Sessions keep running on the Mac until you end them.")
            }
        } label: {
            Label("Terminal", systemImage: "ellipsis")
        }
    }
}

/// The terminal view (AOSTerminalView with its key bar) in SwiftUI.
struct TerminalViewRepresentable: UIViewRepresentable {
    let view: TerminalView

    func makeUIView(context: Context) -> TerminalView {
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}
}
