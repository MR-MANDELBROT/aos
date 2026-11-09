import SwiftUI

/// The Claude Code chats aOS keeps reachable from the Claude app (Docs/COMPANION.md, "Chats"), as the Mac's settings
/// list them: pinned first, then by when you last wrote in them or got an answer. A tap opens a chat's page with what
/// can be done; pressing and holding offers the same.
struct ChatsCard: View {
    let connection: MacConnection
    let list: ChatList
    @State private var actions = ActionState()
    @State private var showAll = false
    @State private var opened: ChatList.Chat?
    @State private var stopping: ChatList.Chat?

    private var features: Set<String> { connection.hello?.features ?? [] }
    private var shown: [ChatList.Chat] { showAll ? list.chats : list.shortList() }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                OverviewRow(symbol: "bubble.left.and.bubble.right", title: String(localized: "Chats"),
                            detail: ChatsText.summary(list)) {
                    if actions.running != nil { ProgressView().controlSize(.small) }
                }
                if !list.enabled {
                    Text("Switch on “Keep conversations reachable” in aOS on the Mac (Settings > Claude Code), and aOS keeps your chats running there for the Claude app.")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, OverviewRow<EmptyView>.iconWidth + 12)
                } else if list.chats.isEmpty {
                    Text("No chats in the last days.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.leading, OverviewRow<EmptyView>.iconWidth + 12)
                } else {
                    ForEach(shown) { chat in
                        Button {
                            opened = chat
                        } label: {
                            ChatRow(chat: chat, list: list)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { menu(for: chat) }
                    }
                    if list.chats.count > list.shortList().count {
                        Button(showAll ? String(localized: "Show Fewer") : String(localized: "Show All (\(list.chats.count))")) {
                            withAnimation(.snappy) { showAll.toggle() }
                        }
                        .font(.subheadline)
                        .padding(.leading, OverviewRow<EmptyView>.iconWidth + 12)
                    }
                }
                ProblemLine(text: actions.problem)
            }
        }
        .animation(.snappy(duration: 0.2), value: actions.problem)
        .onAppear {
            #if DEBUG
            // -AOSDemoSheet chat: the page of the chat that needs something (else the first).
            if Demo.isRequested, Demo.sheet == "chat", opened == nil {
                opened = list.chats.first { $0.state == "needsAttention" } ?? list.chats.first
            }
            #endif
        }
        .sheet(item: $opened) { chat in
            ChatPage(connection: connection, id: chat.id, actions: actions)
        }
        .confirmationDialog(stopping.map { String(localized: "Stop “\($0.title)”?") } ?? "",
                            isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                            titleVisibility: .visible, presenting: stopping) { chat in
            Button("Stop", role: .destructive) { actions.run(.chatsSkip, value: chat.id, on: connection) }
        } message: { _ in
            Text(ChatsText.stopMessage)
        }
    }

    /// The chat's actions for the context menu (the page has them too).
    @ViewBuilder private func menu(for chat: ChatList.Chat) -> some View {
        let offer = ChatOffer.now(chat, in: list, features: features)
        if offer.pin {
            Button("Pin", systemImage: "pin") { actions.run(.chatsPin, value: chat.id, on: connection) }
        }
        if offer.unpin {
            Button("Unpin", systemImage: "pin.slash") { actions.run(.chatsUnpin, value: chat.id, on: connection) }
        }
        if offer.restart {
            Button("Restart", systemImage: "arrow.clockwise") { actions.run(.chatsRestart, value: chat.id, on: connection) }
        }
        if offer.keepAgain {
            Button("Keep Again", systemImage: "arrow.uturn.backward") { actions.run(.chatsUnskip, value: chat.id, on: connection) }
        }
        if offer.stop {
            Button(ChatsText.stopLabel(chat), systemImage: "stop.circle", role: .destructive) { stopping = chat }
        }
    }
}

/// One chat: where it was started, its title (a pin if pinned), its state and folder, and when it was used last.
private struct ChatRow: View {
    let chat: ChatList.Chat
    let list: ChatList

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: ChatsText.symbol(chat))
                .font(.body.weight(.medium))
                .foregroundStyle(BrandColor.indigo)
                .frame(width: OverviewRow<EmptyView>.iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                // As in Mail: the title, and the time with the chevron on its line; the second line has the width.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if chat.pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(BrandColor.indigo)
                            .accessibilityLabel(Text("Pinned"))
                    }
                    Text(chat.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    if let activity = chat.activity {
                        Text(ChatsText.lastUsedShort(activity)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                    }
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                HStack(spacing: 6) {
                    StatusDot(color: ChatsText.tint(chat))
                    Text(ChatsText.state(chat, in: list)).lineLimit(1)
                    if !chat.folder.isEmpty {
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                        Text(chat.folderName).foregroundStyle(.tertiary).lineLimit(1).layoutPriority(-1)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Shows the chat and what you can do with it"))
    }
}

/// A chat's page: what aOS does with it and why, where it is, and its actions.
private struct ChatPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connection: MacConnection
    let id: String
    let actions: ActionState
    @State private var confirmStop = false
    @State private var confirmRestart = false

    private var list: ChatList? { connection.chats }
    private var chat: ChatList.Chat? { list?.chats.first { $0.id == id } }

    var body: some View {
        NavigationStack {
            Group {
                if let list, let chat {
                    content(chat, list: list)
                } else {
                    ContentUnavailableView("This chat isn't in the list any more.", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private func content(_ chat: ChatList.Chat, list: ChatList) -> some View {
        let offer = ChatOffer.now(chat, in: list, features: connection.hello?.features ?? [])
        List {
            Section {
                HStack(spacing: 14) {
                    HeroSymbol(systemName: ChatsText.symbol(chat), tint: ChatsText.tint(chat) == .secondary ? .gray : ChatsText.tint(chat),
                               size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chat.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            StatusDot(color: ChatsText.tint(chat))
                            Text(ChatsText.state(chat, in: list)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                if let text = ChatsText.explanation(chat, in: list) {
                    Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if chat.note == "signIn" {
                    // As for aOS's own session: a terminal on the Mac, from here.
                    Button("Open Terminal", systemImage: "apple.terminal") {
                        dismiss()
                        model.openNewTerminal()
                    }
                }
            }
            if offer != ChatOffer() {
                Section {
                    if offer.pin {
                        Button("Pin: Always Keep Reachable", systemImage: "pin") { run(.chatsPin) }
                    }
                    if offer.unpin {
                        Button("Unpin", systemImage: "pin.slash") { run(.chatsUnpin) }
                    }
                    if offer.restart {
                        Button("Restart", systemImage: "arrow.clockwise") { confirmRestart = true }
                    }
                    if offer.keepAgain {
                        Button("Keep Again", systemImage: "arrow.uturn.backward") { run(.chatsUnskip) }
                    }
                    if offer.stop {
                        Button(ChatsText.stopLabel(chat), systemImage: "stop.circle", role: .destructive) { confirmStop = true }
                    }
                } footer: {
                    Text("Pinned chats stay reachable, also when you haven't used them for a while. Stop ends a chat on the Mac, and aOS doesn't keep it until you keep it again.")
                }
                .disabled(actions.running != nil)
            }
            if let problem = actions.problem {
                Section { ProblemLine(text: problem) }
            }
            Section {
                if !chat.folder.isEmpty { LabeledContent("Folder", value: chat.folder) }
                LabeledContent("Started in", value: ChatsText.origin(chat))
                if let activity = chat.activity {
                    LabeledContent("Last used", value: activity.formatted(date: .abbreviated, time: .shortened))
                }
                if chat.pinned { LabeledContent("Pinned", value: String(localized: "Always kept reachable")) }
            }
        }
        .confirmationDialog(String(localized: "Stop “\(chat.title)”?"), isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) { run(.chatsSkip) }
        } message: {
            Text(ChatsText.stopMessage)
        }
        .confirmationDialog(String(localized: "Restart “\(chat.title)”?"), isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart") { run(.chatsRestart) }
        } message: {
            Text("aOS on the Mac starts Claude Code for it again. The chat continues where it was; an answer it is writing right now stops.")
        }
    }

    private func run(_ action: MacAction) {
        actions.run(action, value: id, on: connection)
    }
}

/// The chats in words (and symbols and colors), kept apart from the views for the tests.
enum ChatsText {
    static func summary(_ list: ChatList) -> String {
        guard list.enabled else { return String(localized: "Off on the Mac") }
        switch list.running {
        case 0: return String(localized: "None is reachable in the Claude app right now")
        case 1: return String(localized: "1 is reachable in the Claude app")
        default: return String(localized: "\(list.running) are reachable in the Claude app")
        }
    }

    static func symbol(_ chat: ChatList.Chat) -> String {
        chat.origin == "terminal" ? "terminal" : "macwindow"
    }

    /// Green while aOS runs it, indigo while it is open elsewhere, yellow on the way, orange when it needs something.
    static func tint(_ chat: ChatList.Chat) -> Color {
        switch chat.state {
        case "running": .green
        case "openElsewhere": BrandColor.indigo
        case "starting", "waitingForNetwork": .yellow
        case "needsAttention", "failed", "folderMissing": .orange
        default: .secondary
        }
    }

    /// What aOS does with it, or why not, in a few words.
    static func state(_ chat: ChatList.Chat, in list: ChatList) -> String {
        if let state = chat.state {
            switch state {
            case "running": return String(localized: "Reachable")
            case "starting": return chat.note == "restarting" ? String(localized: "Restarting") : String(localized: "Starting")
            case "openElsewhere":
                switch chat.note {
                case "app": return String(localized: "Open in the Claude app")
                case "terminal": return String(localized: "Open in a terminal")
                default: return String(localized: "Open elsewhere")
                }
            case "waitingForNetwork": return String(localized: "Waiting for the network")
            case "needsAttention":
                switch chat.note {
                case "signIn": return String(localized: "Needs a sign-in on the Mac")
                case "question": return String(localized: "Asks something on the Mac")
                case "exiting": return String(localized: "Keeps stopping")
                default: return chat.detail ?? String(localized: "Needs you on the Mac")
                }
            case "failed": return chat.detail ?? String(localized: "Didn't start")
            case "folderMissing": return String(localized: "Its folder is gone")
            default: return chat.detail ?? state
            }
        }
        switch chat.reason {
        case "skipped": return String(localized: "Stopped")
        case "archived": return String(localized: "Archived in the Claude app")
        case "scheduled": return String(localized: "Scheduled task")
        case "remoteControlOff": return String(localized: "Remote Control turned off")
        case "ownSession": return String(localized: "aOS's own session")
        case "automation": return String(localized: "Started by automation")
        case "onlyPinned": return String(localized: "Not pinned")
        case "terminal": return String(localized: "From a terminal")
        case "noRemoteControl": return String(localized: "Never used Remote Control")
        case "inactive": return String(localized: "Not used in the last \(list.hours) hours")
        case "overLimit": return String(localized: "Above the limit of \(list.max)")
        case "off": return String(localized: "Off on the Mac")
        case nil: return String(localized: "Starting soon")
        default: return chat.reason ?? ""
        }
    }

    /// More about the state on the chat's page, where it helps.
    static func explanation(_ chat: ChatList.Chat, in list: ChatList) -> String? {
        switch chat.state {
        case "running": return String(localized: "aOS runs it on the Mac, so you can continue it in the Claude app.")
        case "openElsewhere":
            return chat.note == "app"
                ? String(localized: "It's open in the Claude app on the Mac. aOS takes it over a minute after the app lets it go.")
                : String(localized: "It's open in a terminal or another tool on the Mac. aOS takes it over a minute after that ends.")
        case "needsAttention":
            switch chat.note {
            case "signIn": return String(localized: "Claude Code on the Mac needs a sign-in. Run claude once in a terminal there and sign in.")
            case "exiting": return String(localized: "Claude Code keeps stopping. aOS tries again later; Restart tries now.")
            default: return nil
            }
        case nil:
            switch chat.reason {
            case "skipped": return String(localized: "You stopped it. aOS doesn't keep it until you keep it again.")
            case "inactive", "overLimit", "terminal", "noRemoteControl", "onlyPinned":
                return String(localized: "aOS keeps the chats you used last, at most \(list.max). Pin this one to keep it reachable anyway.")
            default: return nil
            }
        default: return nil
        }
    }

    static func origin(_ chat: ChatList.Chat) -> String {
        switch chat.origin {
        case "app": String(localized: "The Claude app")
        case "terminal": String(localized: "A terminal or a tool")
        default: String(localized: "Elsewhere")
        }
    }

    /// "Stop" for one aOS has now (it ends there), "Don't Keep" for the others.
    static func stopLabel(_ chat: ChatList.Chat) -> String {
        chat.state == nil ? String(localized: "Don't Keep") : String(localized: "Stop")
    }

    static var stopMessage: String {
        String(localized: "aOS ends it on the Mac and doesn't keep it any more. Keep Again undoes that; the chat itself stays as it is.")
    }

    /// "4 min. ago", "2 hr. ago", "yesterday" (as short as it gets).
    static func lastUsedShort(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
