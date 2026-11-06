import AOSRFB
import SwiftUI

/// The viewer's toolbar: close, which screen, keyboard, trackpad or touch, and a menu with the rest.
struct ScreenToolbar: View {
    @Environment(AppModel.self) private var model
    let session: ScreenSession
    @Binding var keyboard: Bool
    @Binding var showSettings: Bool
    @Binding var showGestures: Bool
    @Binding var focus: RemoteScreen.FocusRequest
    /// Something in the toolbar was used: it stays a while longer.
    let interacted: () -> Void
    let close: () -> Void
    let picker: AnyView

    var body: some View {
        @Bindable var settings = model.settings
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button("Close", systemImage: "xmark") { close() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .accessibilityHint(Text("Ends the screen connection"))
                picker
                Button(keyboard ? "Hide keyboard" : "Keyboard", systemImage: keyboard ? "keyboard.chevron.compact.down" : "keyboard") {
                    keyboard.toggle()
                    interacted()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                Menu {
                    menuContent(settings: settings)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .simultaneousGesture(TapGesture().onEnded { interacted() })
            }
        }
        .padding(.horizontal, 12)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private func menuContent(settings: AppSettings) -> some View {
        @Bindable var settings = settings
        Picker(selection: $settings.inputMode) {
            Label("Trackpad", systemImage: "rectangle.and.hand.point.up.left").tag(AppSettings.InputMode.trackpad)
            Label("Touch", systemImage: "hand.point.up.left").tag(AppSettings.InputMode.direct)
        } label: {
            Label("One finger", systemImage: "hand.point.up.left")
        }
        if model.screenTarget == .mac {
            Picker(selection: $settings.macScaling) {
                Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left").tag(ScreenGeometry.Scaling.fit)
                Label("Fill", systemImage: "arrow.up.left.and.arrow.down.right").tag(ScreenGeometry.Scaling.fill)
                Label("Actual pixels", systemImage: "1.magnifyingglass").tag(ScreenGeometry.Scaling.actual)
            } label: {
                Label("Size", systemImage: "aspectratio")
            }
        }
        Button("Zoom out", systemImage: "arrow.down.right.and.arrow.up.left") { focus = .init(region: nil) }
        Menu {
            ShortcutButtons(session: session)
        } label: {
            Label("Shortcuts", systemImage: "command")
        }
        Divider()
        Picker(selection: $settings.screenQuality) {
            ForEach(AppSettings.ScreenQuality.allCases) { q in Text(q.title).tag(q) }
        } label: {
            Label("Quality", systemImage: "sparkles.tv")
        }
        Toggle(isOn: $settings.showsScreenStats) { Label("Picture rate and data", systemImage: "gauge.with.dots.needle.67percent") }
        Button("Screen settings", systemImage: "gearshape") { showSettings = true }
        Button("Gestures", systemImage: "hand.tap") { showGestures = true }
    }
}

/// Common Mac shortcuts as buttons (with whatever modifiers are on in the key bar on top).
struct ShortcutButtons: View {
    let session: ScreenSession

    var body: some View {
        shortcut("Copy", "doc.on.doc", [Keysyms.command, 0x63])
        shortcut("Paste", "doc.on.clipboard", [Keysyms.command, 0x76])
        shortcut("Cut", "scissors", [Keysyms.command, 0x78])
        shortcut("Undo", "arrow.uturn.backward", [Keysyms.command, 0x7a])
        shortcut("Select all", "selection.pin.in.out", [Keysyms.command, 0x61])
        shortcut("Find", "magnifyingglass", [Keysyms.command, 0x66])
        Divider()
        shortcut("Spotlight", "magnifyingglass.circle", [Keysyms.command, 0x20])
        shortcut("Switch app", "square.on.square", [Keysyms.command, Keysyms.tab])
        shortcut("Mission Control", "rectangle.3.group", [Keysyms.control, KeyInput.up])
        shortcut("App windows", "macwindow.on.rectangle", [Keysyms.control, KeyInput.down])
        shortcut("Close window", "xmark.rectangle", [Keysyms.command, 0x77])
        shortcut("Quit app", "power", [Keysyms.command, 0x71])
        shortcut("Force quit", "exclamationmark.octagon", [Keysyms.command, Keysyms.option, KeyInput.escape])
        Divider()
        shortcut("New tab", "plus.square.on.square", [Keysyms.command, 0x74])
        shortcut("Reload", "arrow.clockwise", [Keysyms.command, 0x72])
        shortcut("Screenshot of an area", "camera.viewfinder", [Keysyms.command, Keysyms.shift, 0x34])
    }

    private func shortcut(_ title: LocalizedStringKey, _ symbol: String, _ keys: [UInt32]) -> some View {
        Button(title, systemImage: symbol) { session.press(combination: keys) }
    }
}

/// Above the keyboard: Esc, Tab, the modifier keys (on for the next key; tapped again: locked), arrows, Delete,
/// function keys and shortcuts.
struct KeyBar: View {
    let session: ScreenSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    editingKeys
                    modifierKeys
                    arrowKeys
                    moreKeys
                }
                .padding(.horizontal, 2)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var editingKeys: some View {
        key("esc") { session.press(KeyInput.escape) }
        key("tab", symbol: "arrow.right.to.line") { session.press(Keysyms.tab) }
    }

    @ViewBuilder private var modifierKeys: some View {
        modifier("⌘", Keysyms.command, name: "Command")
        modifier("⌥", Keysyms.option, name: "Option")
        modifier("⌃", Keysyms.control, name: "Control")
        modifier("⇧", Keysyms.shift, name: "Shift")
    }

    @ViewBuilder private var arrowKeys: some View {
        key("left", symbol: "arrow.left") { session.press(KeyInput.left) }
        key("down", symbol: "arrow.down") { session.press(KeyInput.down) }
        key("up", symbol: "arrow.up") { session.press(KeyInput.up) }
        key("right", symbol: "arrow.right") { session.press(KeyInput.right) }
        key("return", symbol: "return") { session.press(Keysyms.returnKey) }
        key("delete", symbol: "delete.right") { session.press(KeyInput.forwardDelete) }
    }

    @ViewBuilder private var moreKeys: some View {
        Menu {
            ForEach(1...12, id: \.self) { n in
                Button(String("F\(n)")) { session.press(0xffbe + UInt32(n - 1)) }
            }
        } label: {
            Text(verbatim: "fn").font(.callout.weight(.medium)).frame(minWidth: 26, minHeight: 22)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(Text("Function keys"))
        Menu {
            ShortcutButtons(session: session)
        } label: {
            Image(systemName: "command").frame(minWidth: 26, minHeight: 22)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(Text("Shortcuts"))
    }

    private func key(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol) } else { Text(verbatim: title).font(.callout.weight(.medium)) }
            }
            .frame(minWidth: 26, minHeight: 22)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(Text(title))
    }

    private func modifier(_ glyph: String, _ keysym: UInt32, name: String) -> some View {
        let on = session.isModifierOn(keysym)
        let locked = session.isModifierLocked(keysym)
        return Button {
            session.toggleSticky(keysym)
        } label: {
            Text(verbatim: glyph).font(.title3.weight(.medium)).frame(minWidth: 26, minHeight: 22)
        }
        .buttonStyle(.glass)
        .tint(on ? BrandColor.indigo : nil)
        .overlay {
            if on { Capsule().stroke(BrandColor.indigo, lineWidth: locked ? 3 : 1.5) }
        }
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(Text(locked ? "Locked" : on ? "On" : "Off"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Picture rate, data, round trip and size of the live screen.
struct StatsBadge: View {
    let stats: ScreenStats

    var body: some View {
        Text(verbatim: String(format: "%.0f fps · %.0f KB/s · %.0f ms · %dx%d · %@", stats.framesPerSecond,
                              stats.kilobytesPerSecond, stats.roundTrip * 1000, Int(stats.size.width),
                              Int(stats.size.height), stats.quality.rawValue))
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassEffect()
            .environment(\.colorScheme, .dark)
            .accessibilityLabel(Text("Screen statistics"))
    }
}

extension AppSettings.ScreenQuality {
    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .best: "Best (all colours)"
        case .balanced: "Balanced (thousands of colours)"
        case .saver: "Data saver (4096 colours)"
        case .gray: "Gray (least data)"
        }
    }
}

/// The screen's settings: in the app's settings and from the viewer.
struct ScreenSettingsForm: View {
    @Environment(AppModel.self) private var model
    var target: ScreenTarget? = nil

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Quality", selection: $settings.screenQuality) {
                    ForEach(AppSettings.ScreenQuality.allCases) { q in Text(q.title).tag(q) }
                }
                Picker("Picture rate", selection: $settings.frameRate) {
                    Text("Smooth").tag(AppSettings.FrameRate.smooth)
                    Text("Balanced").tag(AppSettings.FrameRate.balanced)
                    Text("Saves data").tag(AppSettings.FrameRate.saver)
                }
            } header: {
                Text("Picture")
            } footer: {
                Text("Automatic shows all colours on Wi-Fi and fewer on a cellular connection. Every quality keeps text sharp.")
            }

            if target != .mac {
                Section {
                    Toggle("In the iPhone's shape", isOn: $settings.matchWorkspaceShape)
                    Toggle("Retina sharpness", isOn: $settings.retinaWorkspace).disabled(!settings.matchWorkspaceShape)
                } header: {
                    Text("Workspace")
                } footer: {
                    Text("While you watch, the workspace's screen takes the shape of your iPhone, upright or sideways. It gets its own size back when you stop. Retina draws twice the pixels: sharper, more data.")
                }
            }

            if target != .workspace {
                Section("Your Mac") {
                    Picker("Size", selection: $settings.macScaling) {
                        Text("Fit").tag(ScreenGeometry.Scaling.fit)
                        Text("Fill").tag(ScreenGeometry.Scaling.fill)
                        Text("Actual pixels").tag(ScreenGeometry.Scaling.actual)
                    }
                }
            }

            Section {
                Picker("One finger", selection: $settings.inputMode) {
                    Text("Moves the pointer (trackpad)").tag(AppSettings.InputMode.trackpad)
                    Text("Touches directly").tag(AppSettings.InputMode.direct)
                }
                VStack(alignment: .leading) {
                    Text("Pointer speed")
                    Slider(value: $settings.pointerSpeed, in: AppSettings.pointerSpeedRange) {
                        Text("Pointer speed")
                    } minimumValueLabel: {
                        Image(systemName: "tortoise")
                    } maximumValueLabel: {
                        Image(systemName: "hare")
                    }
                }
                Picker("Pointer", selection: $settings.pointerStyle) {
                    Text("Drawn on the iPhone").tag(AppSettings.PointerStyle.local)
                    Text("From the Mac").tag(AppSettings.PointerStyle.remote)
                }
                Toggle("Natural scrolling", isOn: $settings.naturalScrolling)
                Toggle("Haptic feedback", isOn: $settings.haptics)
            } header: {
                Text("Controls")
            } footer: {
                Text("Drawn on the iPhone, the pointer moves without delay. From the Mac it also shows where your agent points.")
            }

            Section("Viewer") {
                Toggle("Hide the toolbar by itself", isOn: $settings.autoHideToolbar)
                Toggle("Extra keys above the keyboard", isOn: $settings.showsKeyBar)
                Toggle("Picture rate and data", isOn: $settings.showsScreenStats)
            }
        }
        .navigationTitle("Screen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct GestureHelp: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Trackpad (one finger moves the pointer)") {
                    GestureRow(symbol: "hand.tap", text: "Tap: click where the pointer is. Tap twice: double click")
                    GestureRow(symbol: "hand.draw", text: "Drag one finger: move the pointer (faster moves go further)")
                    GestureRow(symbol: "hand.point.up", text: "Touch and hold, then move: drag (select, move windows)")
                }
                Section("Touch (one finger touches the screen)") {
                    GestureRow(symbol: "hand.point.up.left", text: "Tap: click where you tap. Tap twice: double click")
                    GestureRow(symbol: "hand.draw", text: "Drag one finger: drag (select, move windows)")
                    GestureRow(symbol: "hand.point.up", text: "Touch and hold: right click")
                }
                Section("Always") {
                    GestureRow(symbol: "hand.tap", text: "Two-finger tap: right click")
                    GestureRow(symbol: "arrow.up.and.down", text: "Two fingers: scroll (it glides on after a flick)")
                    GestureRow(symbol: "arrow.up.left.and.arrow.down.right", text: "Pinch: zoom, moving the fingers moves the picture. Three fingers: move the zoomed picture")
                    GestureRow(symbol: "keyboard", text: "Keyboard: type; ⌘ ⌥ ⌃ ⇧ in the key bar apply to the next key, tapped twice they stay on")
                    GestureRow(symbol: "computermouse", text: "A mouse or trackpad on the iPhone points, clicks and scrolls directly")
                }
            }
            .navigationTitle("Gestures")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct GestureRow: View {
    let symbol: String
    let text: LocalizedStringKey
    var body: some View {
        Label(text, systemImage: symbol)
    }
}
