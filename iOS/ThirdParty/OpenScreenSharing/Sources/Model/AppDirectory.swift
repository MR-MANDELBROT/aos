// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import Foundation
import os

nonisolated enum AppDirectory {
    #if os(macOS)
    static let group = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as! String)!
    static let caches: URL = {
        var caches = group.appendingPathComponent("Library/Caches", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try caches.setResourceValues(values)
        } catch {
            StorageNotice.logger.error("exclude caches from backup: \(error, privacy: .public)")
        }
        return caches
    }()
    #else
    // aOS: a folder of its own in aOS's caches, so "Clear Cache" removes only the screen's files.
    static let caches: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        return caches
    }()
    #endif

    static func cacheSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: caches, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else {
            return 0
        }
        var size: Int64 = 0
        for case let url as URL in enumerator {
            size += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return size
    }

    static func clearCaches() throws {
        for item in try FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: item)
        }
    }
}
