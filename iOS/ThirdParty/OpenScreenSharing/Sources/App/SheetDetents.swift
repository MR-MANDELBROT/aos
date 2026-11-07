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

extension View {
    @ViewBuilder
    func phonePresentationDetents(_ detents: Set<SheetDetent>) -> some View {
        if #available(iOS 16, *) {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                presentationDetents(Set(detents.map(\.presentationDetent)))
            } else {
                self
            }
            #else
            self
            #endif
        } else {
            self
        }
    }

    @ViewBuilder
    func phonePresentationDetents(_ detents: Set<SheetDetent>, selection: Binding<SheetDetent>) -> some View {
        if #available(iOS 16, *) {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                presentationDetents(
                    Set(detents.map(\.presentationDetent)),
                    selection: Binding(
                        get: { selection.wrappedValue.presentationDetent },
                        set: { selection.wrappedValue = $0 == .large ? .large : .medium }
                    )
                )
            } else {
                self
            }
            #else
            self
            #endif
        } else {
            self
        }
    }
}
