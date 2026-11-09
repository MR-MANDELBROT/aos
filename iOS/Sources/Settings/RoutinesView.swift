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

/// Adding or changing a routine: a name, the message, and when: at times on weekdays, every few hours, or cron.
struct RoutineEditorView: View {
    enum Mode: Hashable { case times, interval, cron }

    @State var routine: MacStatus.Routines.Item
    let isNew: Bool
    let save: (MacStatus.Routines.Item) -> Void
    let cancel: () -> Void
    @State private var mode: Mode
    @State private var times: [Date]
    @State private var weekdays: Set<Int>
    @State private var every: Int
    @State private var from: Int
    @State private var to: Int
    @State private var minute: Int
    @State private var cronText: String

    init(routine: MacStatus.Routines.Item, isNew: Bool, save: @escaping (MacStatus.Routines.Item) -> Void,
         cancel: @escaping () -> Void) {
        _routine = State(initialValue: routine)
        self.isNew = isNew
        self.save = save
        self.cancel = cancel
        func at(_ h: Int, _ m: Int) -> Date { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date() }
        let simple = RoutineSchedule.simple(routine.schedule)
        let interval = RoutineSchedule.interval(routine.schedule)
        if let i = interval, i.hours > 1 || simple == nil {
            _mode = State(initialValue: .interval)
            _times = State(initialValue: [at(8, 0)])
            _weekdays = State(initialValue: i.weekdays)
            _every = State(initialValue: i.hours); _from = State(initialValue: i.from); _to = State(initialValue: i.to)
            _minute = State(initialValue: i.minute)
        } else if let simple {
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

    private var schedule: String {
        switch mode {
        case .cron:
            return cronText.split(separator: ";").map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                .filter { !$0.isEmpty }.joined(separator: "; ")
        case .interval:
            return RoutineSchedule.every(hours: every, from: min(from, to), to: max(from, to), minute: minute, weekdays: weekdays)
        case .times:
            let list = times.map { Calendar.current.dateComponents([.hour, .minute], from: $0) }
                .map { (hour: $0.hour ?? 8, minute: $0.minute ?? 0) }
            return RoutineSchedule.cron(times: list, weekdays: weekdays)
        }
    }

    private var valid: Bool {
        !routine.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && RoutineSchedule.looksValid(schedule) && (mode == .cron || !weekdays.isEmpty) && (mode != .times || !times.isEmpty)
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
                Picker("Repeat", selection: $mode) {
                    Text("At times").tag(Mode.times)
                    Text("Every few hours").tag(Mode.interval)
                    Text("Cron").tag(Mode.cron)
                }
                .pickerStyle(.segmented)
                switch mode {
                case .times:
                    ForEach(times.indices, id: \.self) { i in
                        DatePicker("Time", selection: $times[i], displayedComponents: .hourAndMinute)
                    }
                    .onDelete { offsets in if times.count > offsets.count { times.remove(atOffsets: offsets) } }
                    Button("Add Time", systemImage: "plus") {
                        times.append(times.last.map { $0.addingTimeInterval(2 * 3600) } ?? Date())
                    }
                    WeekdayToggles(selection: $weekdays)
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
                    Stepper(value: $minute, in: 0...59) { Text("At minute \(minute)") }
                    WeekdayToggles(selection: $weekdays)
                case .cron:
                    TextField("Minute Hour Day Month Weekday", text: $cronText)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            } header: {
                Text("When")
            } footer: {
                Text(mode == .cron ? String(localized: "Five fields in the Mac's time, like 0 6 * * 1-5 (Monday to Friday at 6:00); several separated by ;.")
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

/// Cron schedules as aOS writes them: times on weekdays ("M H * * days", several separated by ";") or every few
/// hours ("M A-B/N * * days"), in words.
enum RoutineSchedule {
    struct Simple: Equatable {
        var times: [Time]
        /// 0 is Sunday.
        var weekdays: Set<Int>
    }
    struct Time: Equatable {
        var hour: Int
        var minute: Int
    }
    struct Interval: Equatable {
        var hours: Int
        var from: Int
        var to: Int
        var minute: Int
        var weekdays: Set<Int>
    }

    static func parts(_ text: String) -> [[String]] {
        text.split(separator: ";").map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }.filter { !$0.isEmpty }
    }

    static func days(_ field: String) -> Set<Int>? {
        if field == "*" { return Set(0...6) }
        var out = Set<Int>()
        for part in field.split(separator: ",") {
            let bounds = part.split(separator: "-").compactMap { Int($0) }
            guard (1...2).contains(bounds.count), bounds.allSatisfy({ (0...7).contains($0) }), bounds[0] <= bounds.last! else { return nil }
            for d in bounds[0]...bounds.last! { out.insert(d == 7 ? 0 : d) }
        }
        return out.isEmpty ? nil : out
    }

    static func simple(_ cron: String) -> Simple? {
        var times: [Time] = []
        var weekdays: Set<Int>?
        for f in parts(cron) {
            guard f.count == 5, let minute = Int(f[0]), (0...59).contains(minute), f[2] == "*", f[3] == "*",
                  let d = days(f[4]) else { return nil }
            let hours = f[1].split(separator: ",").compactMap { Int($0) }
            guard !hours.isEmpty, hours.count == f[1].split(separator: ",").count, hours.allSatisfy({ (0...23).contains($0) })
            else { return nil }
            if let weekdays, weekdays != d { return nil }
            weekdays = d
            times += hours.map { Time(hour: $0, minute: minute) }
        }
        guard let weekdays, !times.isEmpty else { return nil }
        var unique: [Time] = []
        for t in times.sorted(by: { ($0.hour, $0.minute) < ($1.hour, $1.minute) }) where !unique.contains(t) { unique.append(t) }
        return Simple(times: unique, weekdays: weekdays)
    }

    static func interval(_ cron: String) -> Interval? {
        let p = parts(cron)
        guard p.count == 1, let f = p.first, f.count == 5, let minute = Int(f[0]), (0...59).contains(minute),
              f[2] == "*", f[3] == "*", let d = days(f[4]) else { return nil }
        let hp = f[1].split(separator: "/")
        let step = hp.count == 2 ? Int(hp[1]) ?? 0 : 1
        guard hp.count <= 2, step >= 1 else { return nil }
        var from = 0, to = 23
        if hp[0] != "*" {
            let b = hp[0].split(separator: "-").compactMap { Int($0) }
            guard b.count == 2 else { return nil }
            from = b[0]; to = b[1]
        }
        guard step > 1 || hp[0] == "*" else { return nil }
        return Interval(hours: step, from: from, to: to, minute: minute, weekdays: d)
    }

    static func dayField(_ weekdays: Set<Int>) -> String {
        weekdays.count == 7 || weekdays.isEmpty ? "*" : weekdays.sorted().map(String.init).joined(separator: ",")
    }

    /// One schedule per minute value (hours that share a minute go together), as the Mac writes it.
    static func cron(times: [(hour: Int, minute: Int)], weekdays: Set<Int>) -> String {
        var byMinute: [Int: [Int]] = [:]
        for t in times { byMinute[t.minute, default: []].append(t.hour) }
        return byMinute.keys.sorted().map { m in
            "\(m) \(Array(Set(byMinute[m]!)).sorted().map(String.init).joined(separator: ",")) * * \(dayField(weekdays))"
        }.joined(separator: "; ")
    }

    static func cron(hour: Int, minute: Int, weekdays: Set<Int>) -> String {
        cron(times: [(hour, minute)], weekdays: weekdays)
    }

    static func every(hours: Int, from: Int, to: Int, minute: Int, weekdays: Set<Int>) -> String {
        let range = from == 0 && to == 23 ? "*" : "\(from)-\(to)"
        return "\(minute) \(range)\(hours > 1 ? "/\(hours)" : "") * * \(dayField(weekdays))"
    }

    /// Five fields of digits and cron's signs per schedule (the Mac checks it properly).
    static func looksValid(_ cron: String) -> Bool {
        let p = parts(cron)
        return !p.isEmpty && p.allSatisfy { f in f.count == 5 && f.allSatisfy { $0.allSatisfy { $0.isNumber || "*,-/".contains($0) } } }
    }

    static func clock(_ hour: Int, _ minute: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func daysText(_ set: Set<Int>) -> String? {
        if set.count == 7 { return nil }
        if set == Set(1...5) { return String(localized: "Mon to Fri") }
        if set == [0, 6] { return String(localized: "Weekends") }
        let symbols = Calendar.current.shortWeekdaySymbols
        let first = Calendar.current.firstWeekday - 1
        return (0..<7).map { (first + $0) % 7 }.filter { set.contains($0) }.map { symbols[$0] }.joined(separator: ", ")
    }

    static func text(_ cron: String) -> String {
        let s = simple(cron)
        if let i = interval(cron), i.hours > 1 || s == nil {
            let base = i.hours == 1
                ? String(localized: "Every hour from \(clock(i.from, i.minute)) to \(clock(i.to, i.minute))")
                : String(localized: "Every \(i.hours) hours from \(clock(i.from, i.minute)) to \(clock(i.to, i.minute))")
            return daysText(i.weekdays).map { "\(base) (\($0))" } ?? base
        }
        guard let s else { return cron }
        let times = s.times.map { clock($0.hour, $0.minute) }.joined(separator: ", ")
        guard let d = daysText(s.weekdays) else { return String(localized: "Daily at \(times)") }
        return String(localized: "\(d) at \(times)")
    }
}
