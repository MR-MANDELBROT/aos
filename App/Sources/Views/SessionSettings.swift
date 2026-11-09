import AOSKit
import SwiftUI

/// Settings > Claude Code: aOS's own session, the chat that always runs: its folder, effort, environment, start
/// message and a fresh start; then its routines and the reminders other programs left for it.
struct SessionSettingsSections: View {
    @EnvironmentObject var model: AppModel
    @Binding var sessionName: String
    let saveName: () -> Void
    @State private var editing: Routine?
    @State private var confirmFresh = false
    @State private var startMessage = ""

    var body: some View {
        Section {
            TextField("Name in the Claude app", text: $sessionName).onSubmit(saveName)
            Toggle("Keep the session running", isOn: binding(\.sessionEnabled))
            LabeledContent("Folder") {
                HStack(spacing: 8) {
                    Text(folderText).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if !model.settings.sessionFolder.isEmpty {
                        Button("\(Brand.name)'s Folder") { model.update { $0.sessionFolder = "" } }.buttonStyle(.glass)
                    }
                    Button("Choose …", action: chooseFolder).buttonStyle(.glass)
                }
            }
            Picker("Effort", selection: binding(\.sessionEffort)) {
                Text("Claude Code's default").tag("")
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
                Text("Extra high").tag("xhigh")
                Text("Max").tag("max")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Environment files")
                    Spacer()
                    Button("Add …", action: addEnvFile).buttonStyle(.glass)
                }
                ForEach(model.settings.sessionEnvFiles, id: \.self) { file in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(abbreviate(file)).lineLimit(1).truncationMode(.middle)
                        if !FileManager.default.isReadableFile(atPath: (file as NSString).expandingTildeInPath) {
                            Text("not found").font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") {
                            model.update { $0.sessionEnvFiles.removeAll { $0 == file } }
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                    .font(.callout)
                }
                Text("Lines like KEY=value, for the tools the session uses. \(Brand.name) never shows or logs the values.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Start message")
                TextField("Sent after each start (optional)", text: $startMessage, axis: .vertical)
                    .lineLimit(2...5)
                    .onSubmit(saveStartMessage)
            }
            HStack {
                Text("Conversation")
                Spacer()
                Button("Start Fresh …") { confirmFresh = true }.buttonStyle(.glass)
            }
        } header: {
            Text("\(Brand.name)'s own session")
        } footer: {
            Text("A chat that always runs, reachable in the Claude app. After a restart it continues its own conversation; after two restarts within 30 minutes it starts fresh.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Start a fresh conversation?", isPresented: $confirmFresh) {
            Button("Start Fresh") { SessionCommand.fresh.send(paths: model.paths) }
        } message: {
            Text("The session restarts with an empty conversation. The old one stays in the Claude app's history.")
        }
        .onAppear { startMessage = model.settings.sessionStartMessage }
        .onDisappear(perform: saveStartMessage)

        Section {
            if model.settings.routines.isEmpty {
                Text("No routines yet.").foregroundStyle(.secondary)
            }
            ForEach(model.settings.routines) { r in
                RoutineRow(routine: r, next: model.routines?.next.first { $0.id == r.id }?.at,
                           edit: { editing = r })
            }
            Button("Add Routine …") {
                editing = Routine(name: "", schedule: "0 8 * * *", prompt: "", enabled: true)
            }
            .buttonStyle(.glass)
        } header: {
            Text("Routines")
        } footer: {
            Text("\(Brand.name) sends a routine into the session when it is due and Claude Code isn't busy. If the Mac was asleep, it comes up to 6 hours later.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { r in
            RoutineEditor(routine: r, isNew: !model.settings.routines.contains { $0.id == r.id }) { saved in
                model.update { s in
                    if let i = s.routines.firstIndex(where: { $0.id == saved.id }) { s.routines[i] = saved }
                    else { s.routines.append(saved) }
                }
                editing = nil
            } delete: {
                model.update { $0.routines.removeAll { $0.id == r.id } }
                editing = nil
            } cancel: {
                editing = nil
            }
        }

        Section {
            if let status = model.routines, !status.reminders.isEmpty || !status.recent.isEmpty || status.queued > 0 {
                ForEach(status.reminders, id: \.id) { r in
                    LabeledContent {
                        Text(r.at.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    } label: {
                        Label(r.name, systemImage: "bell").lineLimit(1)
                    }
                }
                if status.queued > 0 {
                    Label(status.queued == 1 ? String(localized: "1 message waits until the session is free")
                                              : String(localized: "\(status.queued) messages wait until the session is free"),
                          systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(status.recent.prefix(5).enumerated()), id: \.offset) { _, d in
                    LabeledContent {
                        Text(d.at.formatted(.relative(presentation: .named))).foregroundStyle(.tertiary)
                    } label: {
                        Label(deliveredTitle(d), systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            } else {
                Text("Nothing waiting.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Reminders and notes")
        } footer: {
            Text("Other programs can leave the session a message: a JSON file with \"text\" (and \"at\" for a time, \"source\" for who sends it) in \(abbreviate(model.paths.inbox.path)). Reminders more than 30 minutes late are dropped.")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    func deliveredTitle(_ d: RoutinesStatus.Delivered) -> String {
        switch d.kind {
        case .routine: return d.name
        case .reminder: return String(localized: "Reminder")
        case .note: return d.name.isEmpty ? String(localized: "Note") : String(localized: "Note from \(d.name)")
        case .start: return String(localized: "Start message")
        }
    }

    var folderText: String {
        model.settings.sessionFolder.isEmpty ? String(localized: "\(Brand.name)'s folder") : abbreviate(model.settings.sessionFolder)
    }

    func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let full = (path as NSString).expandingTildeInPath
        return full.hasPrefix(home) ? "~" + full.dropFirst(home.count) : full
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.settings.sessionDirectory(model.paths)
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.update { $0.sessionFolder = url.standardizedFileURL.path == model.paths.session.standardizedFileURL.path ? "" : url.path }
    }

    func addEnvFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = model.settings.sessionDirectory(model.paths)
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = abbreviate(url.path)
        model.update { s in if !s.sessionEnvFiles.contains(path) { s.sessionEnvFiles.append(path) } }
    }

    func saveStartMessage() {
        let text = startMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if text != model.settings.sessionStartMessage { model.update { $0.sessionStartMessage = text } }
    }

    func binding<T>(_ path: WritableKeyPath<AgentSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: path] }, set: { v in model.update { $0[keyPath: path] = v } })
    }
}

/// One routine: on or off, name, when, the next time; Run Now and Edit.
struct RoutineRow: View {
    @EnvironmentObject var model: AppModel
    let routine: Routine
    let next: Date?
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { routine.enabled }, set: { on in
                model.update { s in if let i = s.routines.firstIndex(where: { $0.id == routine.id }) { s.routines[i].enabled = on } }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.name.isEmpty ? String(localized: "Routine") : routine.name).lineLimit(1)
                HStack(spacing: 6) {
                    Text(RoutineText.schedule(routine.schedule)).font(.caption).foregroundStyle(.secondary)
                    if routine.enabled, let next {
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                        Text("next \(next.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 8)
            Button("Run Now", systemImage: "play.fill") { SessionCommand.run(routine: routine.id).send(paths: model.paths) }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help(Text("Send it into the session now"))
            Button("Edit …", systemImage: "pencil", action: edit)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
    }
}

/// Adding or changing a routine: name, what to send, and when (a time on weekdays, or cron for more).
struct RoutineEditor: View {
    @State var routine: Routine
    let isNew: Bool
    let save: (Routine) -> Void
    let delete: () -> Void
    let cancel: () -> Void
    @State private var time = Date()
    @State private var weekdays: Set<Int> = Set(0...6)
    @State private var advanced = false
    @State private var cronText = ""
    @State private var confirmDelete = false

    init(routine: Routine, isNew: Bool, save: @escaping (Routine) -> Void, delete: @escaping () -> Void,
         cancel: @escaping () -> Void) {
        _routine = State(initialValue: routine)
        self.isNew = isNew
        self.save = save
        self.delete = delete
        self.cancel = cancel
        let simple = CronSchedule(routine.schedule)?.simple
        if let simple, simple.times.count == 1, let t = simple.times.first {
            _time = State(initialValue: Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date())
            _weekdays = State(initialValue: simple.weekdays)
        } else {
            _advanced = State(initialValue: true)
        }
        _cronText = State(initialValue: routine.schedule)
    }

    var schedule: String {
        if advanced { return cronText.trimmingCharacters(in: .whitespaces) }
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        return CronSchedule.text(hour: c.hour ?? 8, minute: c.minute ?? 0, weekdays: weekdays)
    }

    var valid: Bool {
        !routine.name.trimmingCharacters(in: .whitespaces).isEmpty && !routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && CronSchedule(schedule) != nil && (advanced || !weekdays.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $routine.name)
                Section("Message to the session") {
                    TextEditor(text: $routine.prompt)
                        .font(.body)
                        .frame(minHeight: 90)
                }
                Section("When") {
                    Toggle("Cron schedule", isOn: $advanced)
                    if advanced {
                        TextField("Minute Hour Day Month Weekday", text: $cronText)
                            .font(.body.monospaced())
                        Text(CronSchedule(cronText) == nil ? String(localized: "Not a valid schedule (five fields, like 0 6 * * 1-5).")
                                                           : RoutineText.schedule(cronText))
                            .font(.caption)
                            .foregroundStyle(CronSchedule(cronText) == nil ? .orange : .secondary)
                    } else {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        WeekdayPicker(selection: $weekdays)
                    }
                }
                Toggle("On", isOn: $routine.enabled)
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button("Delete …", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var r = routine
                    r.name = r.name.trimmingCharacters(in: .whitespaces)
                    r.schedule = schedule
                    save(r)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 460)
        .confirmationDialog("Delete this routine?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: delete)
        }
    }
}

/// The days of the week as toggles, in the order of the user's calendar.
struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let first = Calendar.current.firstWeekday - 1
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { i in
                let day = (first + i) % 7
                let on = selection.contains(day)
                Button(symbols[day]) {
                    if on { selection.remove(day) } else { selection.insert(day) }
                }
                .buttonStyle(.plain)
                .frame(width: 28, height: 28)
                .background(Circle().fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
                .foregroundStyle(on ? Color.white : Color.primary)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// A schedule in words: "Daily at 06:00", "Mon to Fri at 08:00", "Sun at 17:30", else the cron text.
enum RoutineText {
    static func schedule(_ text: String) -> String {
        guard let cron = CronSchedule(text), let simple = cron.simple else { return text }
        let times = simple.times.map { t -> String in
            let date = Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
            return date.formatted(date: .omitted, time: .shortened)
        }.joined(separator: ", ")
        let days = simple.weekdays
        if days.count == 7 { return String(localized: "Daily at \(times)") }
        if days == Set(1...5) { return String(localized: "Mon to Fri at \(times)") }
        if days == [0, 6] { return String(localized: "Weekends at \(times)") }
        let symbols = Calendar.current.shortWeekdaySymbols
        let first = Calendar.current.firstWeekday - 1
        let ordered = (0..<7).map { (first + $0) % 7 }.filter { days.contains($0) }
        return String(localized: "\(ordered.map { symbols[$0] }.joined(separator: ", ")) at \(times)")
    }
}
