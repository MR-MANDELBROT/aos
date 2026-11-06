import AppKit
import SwiftUI
import Virtualization

/// The workspace screen inside the app (Apple's VZVirtualMachineView): the user can look and work in it directly.
struct VMDisplay: NSViewRepresentable {
    let machine: VZVirtualMachine?
    var capturesKeys = true
    var onCoordinator: ((Coordinator) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = capturesKeys
        view.automaticallyReconfiguresDisplay = false
        view.virtualMachine = machine
        context.coordinator.view = view
        onCoordinator?(context.coordinator)
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== machine { view.virtualMachine = machine }
        view.capturesSystemKeys = capturesKeys
        context.coordinator.view = view
    }

    @MainActor
    final class Coordinator {
        weak var view: VZVirtualMachineView?

        /// Types letters, digits and Return as key presses on a US/ABC layout (the workspace uses ABC).
        /// Checked against the guest: AbCdEf xyZ QW 123 Mm arrives unchanged.
        func type(_ text: String) {
            guard let view, let window = view.window else { return }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            var delay = 0.0
            for ch in text {
                guard let (code, shifted) = Self.keyCode(for: ch) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                    guard let view else { return }
                    Self.press(code: code, shift: shifted, in: view)
                }
                delay += 0.05
            }
        }

        private static func event(_ type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags,
                                  chars: String, in view: NSView) -> NSEvent? {
            if type == .flagsChanged {
                return NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
            }
            return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                    characters: chars, charactersIgnoringModifiers: chars.lowercased(),
                                    isARepeat: false, keyCode: code)
        }

        /// A real left Shift as macOS reports it: the device-independent .shift plus NX_DEVICELSHIFTKEYMASK (0x2) and
        /// 0x100. The VM view goes by the device bits: with .shift alone, Shift never reaches the guest and capitals
        /// arrive as small letters (measured, Tools: aosctl typev).
        static let shiftDown = NSEvent.ModifierFlags(rawValue: 0x20102)
        static let shiftUp = NSEvent.ModifierFlags(rawValue: 0x100)

        private static func press(code: UInt16, shift: Bool, in view: NSView) {
            let flags = shift ? shiftDown : shiftUp
            if shift, let e = event(.flagsChanged, code: 0x38, flags: shiftDown, chars: "", in: view) { view.flagsChanged(with: e) }
            if let down = event(.keyDown, code: code, flags: flags, chars: "", in: view) { view.keyDown(with: down) }
            if let up = event(.keyUp, code: code, flags: flags, chars: "", in: view) { view.keyUp(with: up) }
            if shift, let e = event(.flagsChanged, code: 0x38, flags: shiftUp, chars: "", in: view) { view.flagsChanged(with: e) }
        }

        static let letters: [Character: UInt16] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
            "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
            "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
            "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
            "\n": 0x24,
        ]

        static func keyCode(for ch: Character) -> (UInt16, Bool)? {
            if let c = letters[ch] { return (c, false) }
            let lower = Character(ch.lowercased())
            if ch.isUppercase, let c = letters[lower] { return (c, true) }
            return nil
        }
    }
}
