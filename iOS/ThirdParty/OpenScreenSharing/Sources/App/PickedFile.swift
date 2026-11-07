// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import Foundation

extension URL {
    nonisolated func withPickedFile<T>(options: NSFileCoordinator.ReadingOptions = [], _ body: (URL) throws -> T) throws -> T {
        let isScoped = startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                stopAccessingSecurityScopedResource()
            }
        }
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: self, options: options, error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw MessageError("Couldn’t read \(lastPathComponent)")
        }
        return try result.get()
    }

    func pickedFileContents() async throws -> Data {
        try await Task.detached(priority: .userInitiated) { [self] in
            try withPickedFile { try Data(contentsOf: $0) }
        }.value
    }
}
