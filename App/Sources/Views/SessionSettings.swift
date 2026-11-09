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
            Picker("Permissions", selection: binding(\.sessionPermissionMode)) {
                Text("Claude Code's default").tag("")
                Text("Auto (Claude Code decides)").tag("auto")
                Text("Accept edits").tag("acceptEdits")
                Text("Plan only").tag("plan")
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
            Text("Reminders and notes from other programs")
        } footer: {
            Text("One-time messages that other programs leave for the session: a reminder arrives at its time (for example a push reminder at 8:05), a note as soon as the session is free (for example a watchdog's warning). A program leaves one as a JSON file with \"text\" (and \"at\" for a time, \"source\" for the sender) in \(abbreviate(model.paths.inbox.path)). Reminders more than 30 minutes late are dropped.")
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

/// Adding or changing a routine: name, what to send, and when: at times on weekdays, every few hours, or cron.
struct RoutineEditor: View {
    enum Mode: Hashable { case times, interval, cron }

    @State var routine: Routine
    let isNew: Bool
    let save: (Routine) -> Void
    let delete: () -> Void
    let cancel: () -> Void
    @State private var mode: Mode
    @State private var times: [Date]
    @State private var weekdays: Set<Int>
    @State private var every: Int
    @State private var from: Int
    @State private var to: Int
    @State private var minute: Int
    @State private var cronText: String
    @State private var confirmDelete = false

    init(routine: Routine, isNew: Bool, save: @escaping (Routine) -> Void, delete: @escaping () -> Void,
         cancel: @escaping () -> Void) {
        _routine = State(initialValue: routine)
        self.isNew = isNew
        self.save = save
        self.delete = delete
        self.cancel = cancel
        let set = CronSet(routine.schedule)
        func at(_ h: Int, _ m: Int) -> Date { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date() }
        if let i = set?.interval, i.hours > 1 || set?.simple == nil {
            _mode = State(initialValue: .interval)
            _times = State(initialValue: [at(8, 0)])
            _weekdays = State(initialValue: i.weekdays)
            _every = State(initialValue: i.hours); _from = State(initialValue: i.from); _to = State(initialValue: i.to)
            _minute = State(initialValue: i.minute)
        } else if let simple = set?.simple {
            _mode = State(initialValue: .times)
            _times = State(initialValue: simple.times.map { at($0.hour, $0.minute) })
            _weekdays = State(initialValue: simple.weekdays)
            _every = State(initialValue: 2); _from = State(initialValue: 8); _to = State(initialValue: 20); _minute = State(initialValue: 0)
        } else {
            _mode = State(initialValue: .cron)
            _times = State(initialValue: [at(8, 0)])
            _weekdays = State(initialValue: Set(0...6))
            _every = State(initialValue: 2); _from = State(initialValue: 8); _to = State(initialValue: 20); _minute = State(initialValue: 0)
        }
        _cronText = State(initialValue: routine.schedule)
    }

    var schedule: String {
        switch mode {
        case .cron:
            return CronSet(cronText)?.text ?? cronText
        case .interval:
            return CronSet.every(hours: every, from: min(from, to), to: max(from, to), minute: minute, weekdays: weekdays)
        case .times:
            let list = times.map { Calendar.current.dateComponents([.hour, .minute], from: $0) }
                .map { (hour: $0.hour ?? 8, minute: $0.minute ?? 0) }
            return CronSet.text(times: list, weekdays: weekdays)
        }
    }

    var valid: Bool {
        !routine.name.trimmingCharacters(in: .whitespaces).isEmpty && !routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && CronSet(schedule) != nil && (mode == .cron || !weekdays.isEmpty) && (mode != .times || !times.isEmpty)
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
                Section {
                    Picker("Repeat", selection: $mode) {
                        Text("At times").tag(Mode.times)
                        Text("Every few hours").tag(Mode.interval)
                        Text("Cron").tag(Mode.cron)
                    }
                    .pickerStyle(.segmented)
                    switch mode {
                    case .times:
                        ForEach(times.indices, id: \.self) { i in
                            HStack {
                                DatePicker("Time", selection: $times[i], displayedComponents: .hourAndMinute)
                                if times.count > 1 {
                                    Button("Remove", systemImage: "minus.circle") { times.remove(at: i) }
                                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                                }
                            }
                        }
                        Button("Add Time", systemImage: "plus") {
                            times.append(times.last.map { $0.addingTimeInterval(2 * 3600) } ?? Date())
                        }
                        .buttonStyle(.borderless)
                        WeekdayPicker(selection: $weekdays)
                    case .interval:
                        Picker("Every", selection: $every) {
                            ForEach([1, 2, 3, 4, 6, 8, 12], id: \.self) { h in
                                Text(h == 1 ? String(localized: "hour") : String(localized: "\(h) hours")).tag(h)
                            }
                        }
                        Picker("From", selection: $from) {
                            ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
                        }
                        Picker("Until", selection: $to) {
                            ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
                        }
                        Stepper(value: $minute, in: 0...59) {
                            Text("At minute \(minute)")
                        }
                        WeekdayPicker(selection: $weekdays)
                    case .cron:
                        TextField("Minute Hour Day Month Weekday", text: $cronText)
                            .font(.body.monospaced())
                    }
                } header: {
                    Text("When")
                } footer: {
                    Text(CronSet(schedule) == nil
                         ? String(localized: "Not a valid schedule (five fields, like 0 6 * * 1-5; several separated by ;).")
                         : RoutineText.schedule(schedule))
                        .font(.caption)
                        .foregroundStyle(CronSet(schedule) == nil ? .orange : .secondary)
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
        .frame(minWidth: 500, minHeight: 520)
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

/// A schedule in words: "Daily at 06:00", "Mon to Fri at 08:00, 12:00", "Every 2 hours from 10:00 to 18:00", else
/// the cron text.
enum RoutineText {
    static func days(_ set: Set<Int>) -> String? {
        if set.count == 7 { return nil }
        if set == Set(1...5) { return String(localized: "Mon to Fri") }
        if set == [0, 6] { return String(localized: "Weekends") }
        let symbols = Calendar.current.shortWeekdaySymbols
        let first = Calendar.current.firstWeekday - 1
        return (0..<7).map { (first + $0) % 7 }.filter { set.contains($0) }.map { symbols[$0] }.joined(separator: ", ")
    }

    static func clock(_ hour: Int, _ minute: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func schedule(_ text: String) -> String {
        guard let set = CronSet(text) else { return text }
        if let i = set.interval, i.hours > 1 || set.simple == nil {
            let base = i.hours == 1
                ? String(localized: "Every hour from \(clock(i.from, i.minute)) to \(clock(i.to, i.minute))")
                : String(localized: "Every \(i.hours) hours from \(clock(i.from, i.minute)) to \(clock(i.to, i.minute))")
            return days(i.weekdays).map { "\(base) (\($0))" } ?? base
        }
        guard let simple = set.simple else { return set.text }
        let times = simple.times.map { clock($0.hour, $0.minute) }.joined(separator: ", ")
        guard let d = days(simple.weekdays) else { return String(localized: "Daily at \(times)") }
        return String(localized: "\(d) at \(times)")
    }
}
