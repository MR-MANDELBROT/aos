import SwiftUI

/// The Claude Code chats aOS keeps reachable for the Claude app (Docs/COMPANION.md, "Chats"): all of them, in the
/// Mac's order (reachable first, then pinned, then by when you last wrote in them or got an answer), with "New chats
/// from the Claude app" above them. Start, Restart, Stop and Delete as swipe actions and in the context menu; a tap
/// opens the chat's page, which has them too. Pushed from the Overview's aOS card.
struct ChatsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// Shared with the chat's page: one action at a time, its problem shown on both.
    let actions: ActionState
    @State private var asking: ChatQuestion?

    private var connection: MacConnection? { model.connection }
    private var features: Set<String> { connection?.hello?.features ?? [] }

    var body: some View {
        ScrollViewReader { proxy in
            page
            #if DEBUG
                // The demo's `-AOSDemoScroll bottom`: the list's end
                .task {
                    guard Demo.scrollToBottom else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    if let last = connection?.chats?.chats.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            #endif
        }
    }

    private var page: some View {
        List {
            if let newChats = connection?.macStatus?.newChats {
                Section {
                    OverviewRow(symbol: "plus.bubble", title: String(localized: "New chats from the Claude app"),
                                detail: AOSCard.chatsText(newChats),
                                detailTint: newChats.enabled && newChats.state == "needsLogin" ? .orange : .secondary)
                    if newChats.enabled, newChats.state == "needsLogin" {
                        SignInHelp { model.openNewTerminal() }
                    }
                }
            }
            if let list = connection?.chats {
                Section {
                    if !list.enabled {
                        Text("Switch on “Keep conversations reachable” in aOS on the Mac (Settings > Claude Code), and aOS keeps your chats running there for the Claude app.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if list.chats.isEmpty {
                        Text("No chats in the last days.").foregroundStyle(.secondary)
                    }
                    ForEach(list.chats) { chat in
                        row(chat, in: list)
                    }
                } header: {
                    Text(ChatsText.summary(list))
                } footer: {
                    if !list.chats.isEmpty {
                        Text(features.contains(MacAction.chatsDelete.rawValue) ? ChatsText.actionsFooter
                                                                                 : ChatsText.actionsFooterWithoutDelete)
                    }
                }
            } else if connection?.chatsSupported == true {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                ContentUnavailableView("Not available", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Connect to your Mac, and update aOS there if it's older."))
            }
        }
        .navigationTitle("Chats")
        .animation(.snappy, value: connection?.chats?.chats.map(\.id))
        .safeAreaInset(edge: .bottom) { ProblemCapsule(text: actions.problem) }
        .animation(.snappy(duration: 0.2), value: actions.problem)
        .refreshable { await connection?.refreshChats() }
        // The list now and every 15 s while the page is on screen (its answer carries the Mac's status too); the
        // Mac's `chats` event reads it at once in between.
        .task(id: [connection?.companionState == .ready, scenePhase == .active]) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await connection?.refreshChats()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .chatQuestions($asking) { question in
            guard let connection else { return }
            actions.run(question.action, value: question.chat.id, on: connection)
        }
    }

    private func row(_ chat: ChatList.Chat, in list: ChatList) -> some View {
        let offer = ChatOffer.now(chat, in: list, features: features)
        return NavigationLink(value: OverviewPage.chat(chat.id)) {
            ChatListRow(chat: chat, list: list, busy: actions.isRunning(for: chat.id))
        }
        .swipeActions(edge: .leading) {
            if let start = offer.start {
                Button("Start", systemImage: "play.fill") { perform(.start(start), on: chat) }
                    .tint(.green)
            } else if offer.restart {
                Button("Restart", systemImage: "arrow.clockwise") { perform(.restart, on: chat) }
                    .tint(BrandColor.indigo)
            }
        }
        // Not as destructive buttons: those take the row away before the question is answered.
        .swipeActions(edge: .trailing) {
            if offer.delete {
                Button("Delete", systemImage: "trash") { perform(.delete, on: chat) }
                    .tint(.red)
            }
            if let stop = offer.stop {
                Button("Stop", systemImage: "stop.fill") { perform(.stop(stop), on: chat) }
                    .tint(.orange)
            }
        }
        .contextMenu {
            ChatActionButtons(offer: offer) { perform($0, on: chat) }
        }
    }

    private func perform(_ command: ChatCommand, on chat: ChatList.Chat) {
        guard let connection else { return }
        if let question = ChatQuestion(command, chat: chat) {
            asking = question
        } else if case .start(let action) = command {
            actions.run(action, value: chat.id, on: connection)
        }
    }
}

/// One chat in the list: where it was started, its title (a pin if pinned) and when it was used last, what aOS does
/// with it, and its folder.
struct ChatListRow: View {
    let chat: ChatList.Chat
    let list: ChatList
    var busy = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: ChatsText.symbol(chat))
                .font(.body.weight(.medium))
                .foregroundStyle(BrandColor.indigo)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                // As in Mail: the title, and on its line the time with the pin (the titles stay in line)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(chat.title).font(.body.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 8)
                    if chat.pinned {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(BrandColor.indigo)
                            .accessibilityLabel(Text("Pinned"))
                    }
                    if busy {
                        ProgressView().controlSize(.small)
                    } else if let activity = chat.activity {
                        Text(ChatsText.lastUsedShort(activity)).font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                    }
                }
                HStack(spacing: 6) {
                    StatusDot(color: ChatsText.tint(chat))
                    Text(ChatsText.state(chat, in: list)).lineLimit(2)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    if !chat.folder.isEmpty {
                        Image(systemName: "folder").imageScale(.small).accessibilityHidden(true)
                        Text(chat.folder).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                        Text(verbatim: "·").accessibilityHidden(true)
                    }
                    Text(ChatsText.originShort(chat)).lineLimit(1).fixedSize()
                }
                .font(.footnote)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// A chat's page: what aOS does with it and why, its actions, where it is.
struct ChatPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: String
    let actions: ActionState
    @State private var asking: ChatQuestion?

    private var connection: MacConnection? { model.connection }
    private var list: ChatList? { connection?.chats }
    private var chat: ChatList.Chat? { list?.chats.first { $0.id == id } }

    var body: some View {
        Group {
            if let list, let chat {
                content(chat, list: list)
            } else {
                ContentUnavailableView("This chat isn't in the list any more.", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { ProblemCapsule(text: actions.problem) }
        .animation(.snappy(duration: 0.2), value: actions.problem)
        .chatQuestions($asking) { question in
            guard let connection else { return }
            actions.run(question.action, value: question.chat.id, on: connection) { _ in
                // Deleted: nothing left to show here
                if question.action == .chatsDelete { dismiss() }
            }
        }
    }

    @ViewBuilder private func content(_ chat: ChatList.Chat, list: ChatList) -> some View {
        let offer = ChatOffer.now(chat, in: list, features: connection?.hello?.features ?? [])
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
                    Spacer(minLength: 0)
                    if actions.isRunning(for: chat.id) { ProgressView() }
                }
                if let text = ChatsText.explanation(chat, in: list) {
                    Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if chat.note == "signIn" {
                    // As for aOS's own session: a terminal on the Mac, from here.
                    Button("Open Terminal", systemImage: "apple.terminal") { model.openNewTerminal() }
                }
            }
            if !offer.isEmpty {
                Section {
                    ChatActionButtons(offer: offer) { command in
                        guard let connection else { return }
                        if let question = ChatQuestion(command, chat: chat) {
                            asking = question
                        } else if case .start(let action) = command {
                            actions.run(action, value: chat.id, on: connection)
                        }
                    }
                } footer: {
                    Text(offer.delete ? ChatsText.actionsFooter : ChatsText.actionsFooterWithoutDelete)
                }
                .disabled(actions.running != nil)
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
    }
}

/// What can be done with a chat, as the buttons and swipe actions say it.
enum ChatCommand: Equatable {
    /// With the op to send (`chats.start`, or `chats.pin` on an older Mac).
    case start(MacAction)
    case restart
    /// With the op to send (`chats.stop`, or `chats.skip` on an older Mac).
    case stop(MacAction)
    case delete
}

/// A chat's actions as buttons (the context menu, the chat's page), in one order everywhere.
struct ChatActionButtons: View {
    let offer: ChatOffer
    let perform: (ChatCommand) -> Void

    var body: some View {
        if let start = offer.start {
            Button("Start", systemImage: "play.fill") { perform(.start(start)) }
        }
        if offer.restart {
            Button("Restart", systemImage: "arrow.clockwise") { perform(.restart) }
        }
        // Red symbols too (the app's tint would color them on the chat's page)
        if let stop = offer.stop {
            Button("Stop", systemImage: "stop.fill", role: .destructive) { perform(.stop(stop)) }
                .tint(.red)
        }
        if offer.delete {
            Button("Delete", systemImage: "trash", role: .destructive) { perform(.delete) }
                .tint(.red)
        }
    }
}

/// An action that asks first: whatever ends or removes something (Stop, Restart, Delete). Start doesn't ask.
struct ChatQuestion: Identifiable, Equatable {
    enum Kind: Equatable { case stop, restart, delete }
    let kind: Kind
    let action: MacAction
    let chat: ChatList.Chat
    var id: String { "\(kind) \(chat.id)" }

    init?(_ command: ChatCommand, chat: ChatList.Chat) {
        switch command {
        case .start: return nil
        case .restart: (kind, action) = (.restart, .chatsRestart)
        case .stop(let op): (kind, action) = (.stop, op)
        case .delete: (kind, action) = (.delete, .chatsDelete)
        }
        self.chat = chat
    }

    var title: String {
        switch kind {
        case .stop: String(localized: "Stop “\(chat.title)”?")
        case .restart: String(localized: "Restart “\(chat.title)”?")
        case .delete: String(localized: "Delete “\(chat.title)”?")
        }
    }

    var message: String {
        switch kind {
        case .stop: ChatsText.stopMessage
        case .restart: String(localized: "aOS on the Mac starts Claude Code for it again. The chat continues where it was; an answer it is writing right now stops.")
        case .delete: ChatsText.deleteMessage
        }
    }
}

extension View {
    /// Asks the chat question that is set, and runs its action on yes.
    func chatQuestions(_ question: Binding<ChatQuestion?>, run: @escaping (ChatQuestion) -> Void) -> some View {
        confirmationDialog(question.wrappedValue?.title ?? "",
                           isPresented: Binding(get: { question.wrappedValue != nil },
                                                set: { if !$0 { question.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: question.wrappedValue) { q in
            switch q.kind {
            case .stop: Button("Stop", role: .destructive) { run(q) }
            case .restart: Button("Restart") { run(q) }
            case .delete: Button("Delete", role: .destructive) { run(q) }
            }
        } message: { q in
            Text(q.message)
        }
    }
}

/// What went wrong with the last action, at the bottom of a page.
struct ProblemCapsule: View {
    let text: String?

    var body: some View {
        if let text {
            Label {
                Text(text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            .font(.footnote)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.opacity)
        }
    }
}

/// The chats in words (and symbols and colors), kept apart from the views for the tests.
enum ChatsText {
    /// Above the list: how many can be continued in the Claude app now.
    static func summary(_ list: ChatList) -> String {
        guard list.enabled else { return String(localized: "Off on the Mac") }
        switch list.reachable {
        case 0: return String(localized: "None is reachable in the Claude app right now")
        case 1: return String(localized: "1 is reachable in the Claude app")
        default: return String(localized: "\(list.reachable) are reachable in the Claude app")
        }
    }

    /// The Overview's Chats row: how many are reachable (the list's count, else the status's), and whether new chats
    /// from the Claude app are on. One line each.
    static func overview(_ list: ChatList?, newChats: MacStatus.NewChats?, kept: Int?) -> String {
        var lines: [String] = []
        if let list {
            lines.append(list.enabled ? reachableShort(list.reachable)
                                      : String(localized: "Keeping chats reachable is off on the Mac"))
        } else if let kept {
            lines.append(reachableShort(kept))
        }
        if let newChats { lines.append(newChatsShort(newChats)) }
        return lines.joined(separator: "\n")
    }

    static func reachableShort(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "None reachable in the Claude app right now")
        case 1: String(localized: "1 reachable in the Claude app")
        default: String(localized: "\(count) reachable in the Claude app")
        }
    }

    /// New chats from the Claude app, in a line of the Chats row.
    static func newChatsShort(_ c: MacStatus.NewChats) -> String {
        guard c.enabled else { return String(localized: "New chats from the Claude app are off") }
        switch c.state {
        case "running": return String(localized: "New chats from the Claude app are on")
        case "needsLogin": return String(localized: "New chats need a sign-in to Claude Code on the Mac")
        case "needsTrust": return String(localized: "New chats wait for you on the Mac (trust the folder)")
        case "waitingForNetwork": return String(localized: "New chats wait for the network")
        case "missingClaude": return String(localized: "Claude Code isn't installed on the Mac")
        default: return String(localized: "New chats are starting")
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
            case "skipped": return String(localized: "You stopped it. aOS doesn't keep it until you start it again.")
            case "inactive", "overLimit", "terminal", "noRemoteControl", "onlyPinned":
                return String(localized: "aOS keeps the chats you used last, at most \(list.max). Start this one to keep it reachable anyway.")
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

    /// Where it was started, in a word (the list's rows).
    static func originShort(_ chat: ChatList.Chat) -> String {
        switch chat.origin {
        case "app": String(localized: "Claude app")
        case "terminal": String(localized: "Terminal")
        default: String(localized: "Elsewhere")
        }
    }

    static var stopMessage: String {
        String(localized: "aOS ends it on the Mac and doesn't keep it reachable until you start it again. The conversation itself stays as it is.")
    }

    static var deleteMessage: String {
        String(localized: "The conversation goes to the Mac's Trash and disappears from aOS. The Claude app may keep showing a conversation the desktop app started until it reloads.")
    }

    static var actionsFooter: String {
        String(localized: "Start keeps a chat reachable in the Claude app, also when you haven't used it for a while. Stop ends it on the Mac until you start it again. Delete moves the conversation to the Mac's Trash.")
    }

    static var actionsFooterWithoutDelete: String {
        String(localized: "Start keeps a chat reachable in the Claude app, also when you haven't used it for a while. Stop ends it on the Mac until you start it again.")
    }

    /// "4 min. ago", "2 hr. ago", "yesterday" (as short as it gets).
    static func lastUsedShort(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
