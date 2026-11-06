import UIKit
import UniformTypeIdentifiers

/// Copying text that isn't secret (a public key, terminal output): only on this device, no Universal Clipboard.
enum Clipboard {
    static func copyPlain(_ text: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
    }
}
