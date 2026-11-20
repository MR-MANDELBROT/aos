// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import SwiftUI

enum SheetDetent: Hashable {
    case medium
    case large

    @available(iOS 16, *)
    fileprivate var presentationDetent: PresentationDetent {
        switch self {
        case .medium: .medium
        case .large: .large
        }
    }
}

// aOS: the detents go by the room the window has (its horizontal size class), not by the device: a narrow iPad window
// gets the bottom sheet with its detents too, a wide window a form sheet without them.
extension View {
    func phonePresentationDetents(_ detents: Set<SheetDetent>) -> some View {
        modifier(CompactPresentationDetents(detents: detents, selection: nil))
    }

    func phonePresentationDetents(_ detents: Set<SheetDetent>, selection: Binding<SheetDetent>) -> some View {
        modifier(CompactPresentationDetents(detents: detents, selection: selection))
    }
}

private struct CompactPresentationDetents: ViewModifier {
    let detents: Set<SheetDetent>
    let selection: Binding<SheetDetent>?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if horizontalSizeClass == .regular {
            content
        } else if let selection {
            content.presentationDetents(
                Set(detents.map(\.presentationDetent)),
                selection: Binding(
                    get: { selection.wrappedValue.presentationDetent },
                    set: { selection.wrappedValue = $0 == .large ? .large : .medium }
                )
            )
        } else {
            content.presentationDetents(Set(detents.map(\.presentationDetent)))
        }
        #else
        content
        #endif
    }
}
