import SwiftUI

/// aOS's session's routines on the Mac: on or off, run now, add, change, delete; reminders waiting and what went in
/// lately. Every change goes to the Mac as a signed action and comes back in its status.
struct RoutinesPage: View {
    @Environment(AppModel.self) private var model
    @State private var actions = ActionState()
    @State private var editing: MacStatus.Routines.Item?
    @State private var deleting: MacStatus.Routines.Item?

    private var connection: MacConnection? { model.connection }
    private var routines: MacStatus.Routines? { connection?.macStatus?.routines }

    var body: some View {
        List {
            if let routines {
                Section {
                    if routines.items.isEmpty {
                        Text("No routines yet.").foregroundStyle(.secondary)
                    }
                    ForEach(routines.items) { r in
                        RoutineRowView(routine: r, busy: actions.running != nil) { on in
                            var changed = r
                            changed.enabled = on
                            save(changed)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editing = r }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = r }
                            Button("Edit", systemImage: "pencil") { editing = r }.tint(BrandColor.indigo)
                        }
                        .swipeActions(edge: .leading) {
                            Button("Run Now", systemImage: "play.fill") { run(r) }.tint(.green)
                        }
                        .contextMenu {
                            Button("Run Now", systemImage: "play.fill") { run(r) }
                            Button("Edit", systemImage: "pencil") { editing = r }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = r }
                        }
                    }
                } footer: {
                    Text("aOS sends a routine into its session on the Mac when it is due and Claude Code isn't busy. If the Mac was asleep, it comes up to 6 hours later.")
                }
                if !routines.reminders.isEmpty || routines.queued > 0 {
                    Section("Waiting") {
                        if routines.queued > 0 {
                            Label(routines.queued == 1 ? String(localized: "1 message waits until the session is free")
                                                       : String(localized: "\(routines.queued) messages wait until the session is free"),
                                  systemImage: "hourglass")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(routines.reminders.enumerated()), id: \.offset) { _, r in
                            LabeledContent {
                                Text(r.at.formatted(date: .abbreviated, time: .shortened))
                            } label: {
                                Label(r.name, systemImage: "bell").lineLimit(2)
                            }
                        }
                    }
                }
                if !routines.recent.isEmpty {
                    Section("Recently sent") {
                        ForEach(Array(routines.recent.enumerated()), id: \.offset) { _, d in
                            LabeledContent {
                                Text(d.at.formatted(.relative(presentation: .named)))
                            } label: {
                                Label(Self.sentTitle(d), systemImage: Self.sentSymbol(d.kind))
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Not available", systemImage: "clock.arrow.circlepath",
                                       description: Text("Connect to your Mac, and update aOS there if it's older."))
            }
        }
        .navigationTitle("Routines")
        .toolbar {
            if routines != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Routine", systemImage: "plus") {
                        editing = MacStatus.Routines.Item(id: UUID().uuidString, name: "", schedule: "0 8 * * *",
                                                          prompt: "", enabled: true, next: nil)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let problem = actions.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(in: Capsule())
                    .padding(.bottom, 8)
            }
        }
        .refreshable { await connection?.refreshMacStatus() }
        .task { await connection?.refreshMacStatus() }
        .sheet(item: $editing) { r in
            NavigationStack {
                RoutineEditorView(routine: r, isNew: !(routines?.items.contains { $0.id == r.id } ?? false)) { saved in
                    save(saved)
                    editing = nil
                } cancel: {
                    editing = nil
                }
            }
        }
        .confirmationDialog("Delete this routine?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { r in
            Button("Delete", role: .destructive) {
                if let connection { actions.run(.routineDelete, value: r.id, on: connection) }
                deleting = nil
            }
        } message: { r in
            Text(r.name)
        }
    }

    private func save(_ r: MacStatus.Routines.Item) {
        guard let connection, let data = try? JSONEncoder().encode(r) else { return }
        actions.run(.routineSet, value: String(decoding: data, as: UTF8.self), on: connection)
    }

    private func run(_ r: MacStatus.Routines.Item) {
        guard let connection else { return }
        actions.run(.routineRun, value: r.id, on: connection)
    }

    static func sentTitle(_ d: MacStatus.Routines.Sent) -> String {
        switch d.kind {
        case "reminder": String(localized: "Reminder")
        case "note": d.name.isEmpty ? String(localized: "Note") : String(localized: "Note from \(d.name)")
        case "start": String(localized: "Start message")
        default: d.name
        }
    }

    static func sentSymbol(_ kind: String) -> String {
        switch kind {
        case "reminder": "bell"
        case "note": "envelope"
        case "start": "power"
        default: "clock.arrow.circlepath"
        }
    }
}

/// One routine: name, when, the next time, and its switch.
struct RoutineRowView: View {
    let routine: MacStatus.Routines.Item
    let busy: Bool
    let setEnabled: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(routine.name).lineLimit(1)
                Text(RoutineSchedule.text(routine.schedule)).font(.footnote).foregroundStyle(.secondary)
                if routine.enabled, let next = routine.next {
                    Text("Next \(next.formatted(.relative(presentation: .named)))").font(.footnote).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Toggle("On", isOn: Binding(get: { routine.enabled }, set: setEnabled))
                .labelsHidden()
                .disabled(busy)
        }
    }
}

/// Adding or changing a routine: a name, the message, and a time on weekdays (or cron for more).
struct RoutineEditorView: View {
    @State var routine: MacStatus.Routines.Item
    let isNew: Bool
    let save: (MacStatus.Routines.Item) -> Void
    let cancel: () -> Void
    @State private var time: Date
    @State private var weekdays: Set<Int>
    @State private var advanced: Bool
    @State private var cronText: String

    init(routine: MacStatus.Routines.Item, isNew: Bool, save: @escaping (MacStatus.Routines.Item) -> Void,
         cancel: @escaping () -> Void) {
        _routine = State(initialValue: routine)
        self.isNew = isNew
        self.save = save
        self.cancel = cancel
        let simple = RoutineSchedule.simple(routine.schedule)
        _time = State(initialValue: Calendar.current.date(bySettingHour: simple?.hour ?? 8, minute: simple?.minute ?? 0,
                                                          second: 0, of: Date()) ?? Date())
        _weekdays = State(initialValue: simple?.weekdays ?? Set(0...6))
        _advanced = State(initialValue: simple == nil)
        _cronText = State(initialValue: routine.schedule)
    }

    private var schedule: String {
        if advanced { return cronText.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        return RoutineSchedule.cron(hour: c.hour ?? 8, minute: c.minute ?? 0, weekdays: weekdays)
    }

    private var valid: Bool {
        !routine.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (advanced ? RoutineSchedule.looksValid(schedule) : !weekdays.isEmpty)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $routine.name)
            }
            Section {
                TextField("What the session should do", text: $routine.prompt, axis: .vertical)
                    .lineLimit(4...12)
            } header: {
                Text("Message to the session")
            }
            Section {
                if advanced {
                    TextField("Minute Hour Day Month Weekday", text: $cronText)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } else {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    WeekdayToggles(selection: $weekdays)
                }
                Toggle("Cron schedule", isOn: $advanced)
            } header: {
                Text("When")
            } footer: {
                Text(advanced ? String(localized: "Five fields in the Mac's time, like 0 6 * * 1-5 (Monday to Friday at 6:00).")
                              : RoutineSchedule.text(schedule))
            }
            Section {
                Toggle("On", isOn: $routine.enabled)
            }
        }
        .navigationTitle(isNew ? String(localized: "New Routine") : routine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? String(localized: "Add") : String(localized: "Save")) {
                    var r = routine
                    r.name = r.name.trimmingCharacters(in: .whitespaces)
                    r.prompt = r.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    r.schedule = schedule
                    save(r)
                }
                .disabled(!valid)
            }
        }
    }
}

/// The days of the week as round toggles, in the order of the user's calendar (0 is Sunday, as in cron).
struct WeekdayToggles: View {
    @Binding var selection: Set<Int>

    var body: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let first = Calendar.current.firstWeekday - 1
        HStack {
            ForEach(0..<7, id: \.self) { i in
                let day = (first + i) % 7
                let on = selection.contains(day)
                Button {
                    if on { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(symbols[day])
                        .font(.footnote.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(on ? BrandColor.indigo : Color.secondary.opacity(0.15)))
                        .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(Calendar.current.weekdaySymbols[day]))
                .accessibilityAddTraits(on ? .isSelected : [])
                if i < 6 { Spacer(minLength: 0) }
            }
        }
    }
}

/// Cron schedules as simple as aOS writes them ("M H * * days") and in words.
enum RoutineSchedule {
    struct Simple: Equatable {
        var hour: Int
        var minute: Int
        /// 0 is Sunday.
        var weekdays: Set<Int>
    }

    static func simple(_ cron: String) -> Simple? {
        let f = cron.split(whereSeparator: \.isWhitespace).map(String.init)
        guard f.count == 5, let minute = Int(f[0]), let hour = Int(f[1]), (0...59).contains(minute), (0...23).contains(hour),
              f[2] == "*", f[3] == "*" else { return nil }
        if f[4] == "*" { return Simple(hour: hour, minute: minute, weekdays: Set(0...6)) }
        var days = Set<Int>()
        for part in f[4].split(separator: ",") {
            let bounds = part.split(separator: "-").compactMap { Int($0) }
            guard (1...2).contains(bounds.count), bounds.allSatisfy({ (0...7).contains($0) }) else { return nil }
            let lo = bounds[0], hi = bounds.last!
            guard lo <= hi else { return nil }
            for d in lo...hi { days.insert(d == 7 ? 0 : d) }
        }
        return days.isEmpty ? nil : Simple(hour: hour, minute: minute, weekdays: days)
    }

    static func cron(hour: Int, minute: Int, weekdays: Set<Int>) -> String {
        let days = weekdays.count == 7 || weekdays.isEmpty ? "*" : weekdays.sorted().map(String.init).joined(separator: ",")
        return "\(minute) \(hour) * * \(days)"
    }

    /// Five fields of digits and cron's signs (the Mac checks it properly).
    static func looksValid(_ cron: String) -> Bool {
        let f = cron.split(whereSeparator: \.isWhitespace)
        return f.count == 5 && f.allSatisfy { $0.allSatisfy { $0.isNumber || "*,-/".contains($0) } }
    }

    static func text(_ cron: String) -> String {
        guard let s = simple(cron) else { return cron }
        let date = Calendar.current.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: Date()) ?? Date()
        let time = date.formatted(date: .omitted, time: .shortened)
        if s.weekdays.count == 7 { return String(localized: "Daily at \(time)") }
        if s.weekdays == Set(1...5) { return String(localized: "Mon to Fri at \(time)") }
        if s.weekdays == [0, 6] { return String(localized: "Weekends at \(time)") }
        let symbols = Calendar.current.shortWeekdaySymbols
        let first = Calendar.current.firstWeekday - 1
        let days = (0..<7).map { (first + $0) % 7 }.filter { s.weekdays.contains($0) }.map { symbols[$0] }
        return String(localized: "\(days.joined(separator: ", ")) at \(time)")
    }
}
