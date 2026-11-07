// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

#if os(iOS)
import GameController
import ObjectiveC
import Perception
import SwiftUI
import UIKit

enum PointerLock {
    private static let requests = NSHashTable<UIWindowScene>.weakObjects()
    private static let receivers = NSHashTable<ScreenInput>.weakObjects()
    private static var isInstalled = false

    static func request(_ locked: Bool, in scene: UIWindowScene) {
        install()
        guard locked != requests.contains(scene) else { return }
        if locked {
            requests.add(scene)
        } else {
            requests.remove(scene)
        }
        update(scene)
    }

    static func addReceiver(_ receiver: ScreenInput) {
        install()
        receivers.add(receiver)
    }

    static func isLocked(_ scene: UIWindowScene?) -> Bool {
        scene?.pointerLockState?.isLocked == true
    }

    static var hasMouse: Bool {
        install()
        return mice.isConnected
    }

    static let mice = ConnectedMice()

    private static func prefersLock(_ scene: UIWindowScene) -> Bool {
        requests.contains(scene) && !GCMouse.mice().isEmpty
    }

    private static func update(_ scene: UIWindowScene) {
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfPrefersPointerLocked()
                controller = current.presentedViewController
            }
        }
    }

    private static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        let selector = #selector(getter: UIViewController.prefersPointerLocked)
        if let method = class_getInstanceMethod(UIViewController.self, selector) {
            typealias Getter = @convention(c) (UIViewController, Selector) -> Bool
            let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            let getter: @convention(block) (UIViewController) -> Bool = { controller in
                if let scene = controller.viewIfLoaded?.window?.windowScene, prefersLock(scene) { return true }
                return original(controller, selector)
            }
            method_setImplementation(method, imp_implementationWithBlock(getter))
        }
        GCMouse.mice().forEach(attach)
        NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                GCMouse.mice().forEach(attach)
                mice.isConnected = !GCMouse.mice().isEmpty
                requests.allObjects.forEach(update)
            }
        }
        NotificationCenter.default.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                mice.isConnected = !GCMouse.mice().isEmpty
                requests.allObjects.forEach(update)
            }
        }
    }

    private static func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = { _, deltaX, deltaY in
            MainActor.assumeIsolated {
                receivers.allObjects.forEach { $0.lockedMouseMoved(by: CGPoint(x: CGFloat(deltaX), y: -CGFloat(deltaY))) }
            }
        }
        let buttons: [(GCControllerButtonInput?, PointerButtons)] = [
            (input.leftButton, .primary), (input.rightButton, .secondary), (input.middleButton, .middle),
        ]
        for case (let input?, let button) in buttons {
            input.pressedChangedHandler = { _, _, pressed in
                MainActor.assumeIsolated {
                    receivers.allObjects.forEach { $0.lockedMouseButton(button, pressed: pressed) }
                }
            }
        }
    }
}

@Perceptible
final class ConnectedMice {
    fileprivate(set) var isConnected = !GCMouse.mice().isEmpty
}

struct PointerLockRequest: UIViewRepresentable {
    let locked: Bool

    func makeUIView(context: Context) -> RequestView {
        RequestView()
    }

    func updateUIView(_ view: RequestView, context: Context) {
        view.locked = locked
    }

    final class RequestView: UIView {
        private weak var scene: UIWindowScene?

        var locked = false {
            didSet {
                if locked != oldValue { report() }
            }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) {
            fatalError()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        private func report() {
            let current = window?.windowScene
            if let scene, scene !== current {
                PointerLock.request(false, in: scene)
            }
            scene = current
            if let current {
                PointerLock.request(locked, in: current)
            }
        }
    }
}
#endif
