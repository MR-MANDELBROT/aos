// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

#if os(iOS)
import UIKit
import UniformTypeIdentifiers

final class ScreenDrop: NSObject, UIDropInteractionDelegate {
    private unowned let view: RemoteScreenUIView
    private unowned let controller: SessionController
    private unowned let drag: ScreenDrag

    init(view: RemoteScreenUIView, controller: SessionController, drag: ScreenDrag) {
        self.view = view
        self.controller = controller
        self.drag = drag
        super.init()
        view.addInteraction(UIDropInteraction(delegate: self))
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        if let local = session.localDragSession { return drag.owns(local) }
        return controller.canTransferFiles && session.hasItemsConforming(toTypeIdentifiers: [UTType.item.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
        guard session.localDragSession == nil else { return }
        let names = session.items.map { item in
            let provider = item.itemProvider
            let name = provider.suggestedName ?? String(localized: "Item")
            return provider.hasItemConformingToTypeIdentifier(UTType.folder.identifier) ? name + "/" : name
        }
        controller.dropEntered(names: names)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        let location = session.location(in: view)
        guard session.localDragSession == nil else { return drag.moved(to: location) }
        controller.dropMoved(to: view.imagePoint(for: location))
        return UIDropProposal(operation: controller.dropTarget == nil ? .forbidden : .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        guard session.localDragSession == nil else { return drag.exited() }
        controller.dropExited()
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard session.localDragSession == nil else { return drag.drop(at: session.location(in: view)) }
        controller.drop(session.items.map(\.itemProvider))
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        guard session.localDragSession == nil else { return }
        controller.dropExited()
    }
}
#endif
