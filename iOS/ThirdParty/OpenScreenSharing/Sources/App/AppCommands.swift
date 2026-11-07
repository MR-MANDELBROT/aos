// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import Perception
import SwiftUI

nonisolated private struct SessionControllerKey: FocusedValueKey {
    typealias Value = SessionController
}

nonisolated extension FocusedValues {
    var sessionController: SessionController? {
        get { self[SessionControllerKey.self] }
        set { self[SessionControllerKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.sessionController) private var session

    // aOS: no list of computers, so no "New Connection" and no home window; the macOS app's commands (updates,
    // settings, layout) are left out with the macOS app.
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Section {
                Button("Disconnect") { session?.close() }
                    .modifier(ActionShortcut(action: .disconnect))
                    .disabled(session == nil)
            }
        }

        CommandGroup(after: .pasteboard) {
            ClipboardCommandItems(session: session)
        }

        CommandGroup(before: .toolbar) {
            ViewCommandItems(session: session)
        }

        CommandMenu("Sound") {
            SoundCommandItems(session: session)
        }

        CommandMenu("Control") {
            ControlCommandItems(session: session)
        }

        CommandMenu("Debug") {
            DebugInfoToggle()
        }
    }
}

private struct ClipboardCommandItems: View {
    let session: SessionController?

    var body: some View {
        WithPerceptionTracking {
            Section {
                Toggle(isOn: Binding(get: { session?.clipboardSharing ?? false }, set: { session?.setClipboardSharing($0) })) { Label("Sync Clipboard", systemImage: "arrow.up.arrow.down") }
                    .modifier(ActionShortcut(action: .syncClipboard))
                    .disabled(session == nil)
                Button { session?.getClipboardFromMac() } label: { Label("Receive Clipboard", systemImage: "doc.on.clipboard") }
                    .modifier(ActionShortcut(action: .receiveClipboard))
                    .disabled(session?.phase != .connected || session?.clipboardSharing == true)
                Button { session?.sendClipboardToMac() } label: { Label("Send Clipboard", systemImage: "arrow.up.doc.on.clipboard") }
                    .modifier(ActionShortcut(action: .sendClipboard))
                    .disabled(session?.phase != .connected || session?.clipboardSharing == true)
            }
        }
    }
}

private struct ViewCommandItems: View {
    let session: SessionController?

    var body: some View {
        WithPerceptionTracking {
            Section {
                Toggle("Zoom Mode", isOn: Binding(get: { session?.isZoomModeOn ?? false }, set: { session?.setZoomMode($0) }))
                    .modifier(ActionShortcut(action: .zoomMode))
                    .disabled(session == nil)
                if session?.pictureMatchesWindow != true {
                    Button(session?.scaleMode == .fit ? "Zoom to Actual Size" : "Zoom to Fit") {
                        session?.setScale(session?.scaleMode == .fit ? .actualSize : .fit)
                    }
                    .modifier(ActionShortcut(action: .actualSize))
                    .disabled(session == nil)
                }
            }
            if let session, session.showsDisplayPicker {
                Section {
                    ForEach(Array(session.displays.enumerated()), id: \.element.id) { index, display in
                        WithPerceptionTracking {
                            Toggle(
                                display.name,
                                isOn: Binding(
                                    get: { session.displaySelection == .display(display.id) },
                                    set: { _ in session.selectDisplay(.display(display.id)) }
                                )
                            )
                            .modifier(ActionShortcut(action: ShortcutAction.display(at: index)))
                        }
                    }
                    Toggle("All Displays", isOn: Binding(get: { session.displaySelection == .all }, set: { _ in session.selectDisplay(.all) }))
                        .modifier(ActionShortcut(action: .allDisplays))
                }
                .disabled(session.phase != .connected)
            }
            if session.map({ SessionCommand.quality.isOffered(by: $0) }) ?? true {
                Section {
                    ForEach(SessionQuality.allCases) { quality in
                        WithPerceptionTracking {
                            Toggle(isOn: Binding(get: { session?.quality == quality }, set: { _ in session?.setQuality(quality) })) {
                                Text(String(localized: quality.title))
                            }
                            .modifier(ActionShortcut(action: ShortcutAction.quality(quality)))
                        }
                    }
                    .disabled(session == nil)
                }
            }
            Section {
                Menu("Resolution") {
                    if let session {
                        ResolutionOptions(controller: session)
                    }
                }
                .disabled(!(session?.offersResolution ?? false) || !(session?.isControlling ?? false))
                Toggle("High Dynamic Range", isOn: Binding(get: { session?.hdrEnabled ?? false }, set: { session?.setHDR($0) }))
                    .modifier(ActionShortcut(action: .hdr))
                    .disabled(!(session?.canUseHDR ?? false))
            }
            Section {
                #if os(iOS)
                Button(session?.isToolbarVisible == true ? "Hide Toolbar" : "Show Toolbar") { session?.toggleToolbar() }
                    .modifier(ActionShortcut(action: .toolbar))
                    .disabled(session == nil || session?.isToolbarDocked == true)
                #endif
                Button("Customize Toolbar…") { session?.isCustomizingToolbar = true }
                    .modifier(ActionShortcut(action: .customizeToolbar))
                    .disabled(session == nil)
            }
        }
    }
}

private struct SoundCommandItems: View {
    let session: SessionController?

    var body: some View {
        WithPerceptionTracking {
            Toggle("Receive Audio", isOn: Binding(get: { session?.receivesAudio ?? false }, set: { session?.setReceivesAudio($0) }))
                .modifier(ActionShortcut(action: .receiveAudio))
                .disabled(session.map { !SessionCommand.audio.isOffered(by: $0) } ?? true)
            Toggle("Send Audio", isOn: Binding(get: { session?.sendsAudio ?? false }, set: { session?.setSendsAudio($0) }))
                .modifier(ActionShortcut(action: .sendAudio))
                .disabled(session.map { !SessionCommand.sendAudio.isOffered(by: $0) } ?? true)
        }
    }
}

private struct ControlCommandItems: View {
    let session: SessionController?

    private var controlling: Bool { session?.isControlling ?? false }

    var body: some View {
        WithPerceptionTracking {
            Section {
                #if os(iOS)
                if let session, SessionCommand.nativeTouch.isOffered(by: session) {
                    Toggle("Native Touch", isOn: Binding(get: { session.isNativeTouchOn }, set: { session.setNativeTouch($0) }))
                        .disabled(!controlling)
                }
                #endif
                Toggle("Observe Mode", isOn: Binding(get: { session?.mode == .observe }, set: { session?.setMode($0 ? .observe : .control) }))
                    .modifier(ActionShortcut(action: .observe))
                    .disabled(session.map { !SessionCommand.observe.isOffered(by: $0) || !SessionCommand.observe.isEnabled(in: $0) } ?? true)
                Toggle("Pointer Lock", isOn: Binding(get: { session?.isPointerLockOn ?? false }, set: { session?.setPointerLock($0) }))
                    .modifier(ActionShortcut(action: .pointerLock))
                    .disabled(session.map { !SessionCommand.pointerLock.isOffered(by: $0) || !$0.canLockPointer } ?? true)
                #if os(iOS)
                Button(session?.isKeyboardVisible == true ? "Hide Keyboard" : "Show Keyboard") { session?.toggleKeyboard() }
                    .modifier(ActionShortcut(action: .keyboard))
                    .disabled(!controlling)
                #endif
            }
            if session?.platform == .iOS {
                Section {
                    deviceButton(.home, shortcut: .home) { $0.perform(.showDesktop) }
                    deviceButton(.appSwitcher, shortcut: .appSwitcher) { $0.perform(.missionControl) }
                    deviceButton(.lock, shortcut: .lock) { $0.sendChord(.sideButton) }
                }
            } else if session?.platform != .pc {
                Section {
                    ForEach(SystemCommand.allCases) { command in
                        WithPerceptionTracking {
                            Button(String(localized: command.title)) { session?.perform(command) }
                                .modifier(ActionShortcut(action: ShortcutAction.system(command)))
                                .disabled(!controlling || !(session?.canPerform(command) ?? false))
                        }
                    }
                }
            }
        }
    }

    private func deviceButton(_ command: SessionCommand, shortcut: ShortcutAction, action: @escaping (SessionController) -> Void) -> some View {
        Button(String(localized: command.title)) {
            if let session { action(session) }
        }
        .modifier(ActionShortcut(action: shortcut))
        .disabled(session.map { !command.isOffered(by: $0) || !command.isEnabled(in: $0) } ?? true)
    }
}

private struct DebugInfoToggle: View {
    private let settings = AppSettings.shared

    var body: some View {
        WithPerceptionTracking {
            Toggle("Debug Panel", isOn: Binding(get: { settings.showsDebugInfo }, set: { settings.showsDebugInfo = $0 }))
                .modifier(ActionShortcut(action: .debugPanel))
        }
    }
}
