import Foundation
import Observation
import os

private let log = Logger(subsystem: "dev.marquart.aos.ios", category: "screen")

/// The last picture of each screen, for the Screen tab's cards: Open Screen Sharing's thumbnail (JPEG, at most 1280
/// pixels wide) from when a session let go of it. What was on a screen can be private, so the pictures stay in the
/// app's container, readable only while the iPhone is unlocked (complete file protection) and outside of backups;
/// unpairing a Mac deletes its pictures.
@MainActor @Observable
final class ScreenPictures {
    /// The demo puts one in memory only in its place.
    static var shared = ScreenPictures(directory: ScreenPictures.defaultDirectory)

    /// Application Support/Screen Pictures.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen Pictures", isDirectory: true)
    }

    /// Nil: in memory only (the demo).
    let directory: URL?
    /// Changes with every saved or forgotten picture (the cards read it, so they show the new one).
    private(set) var revision = 0
    @ObservationIgnored private var cache: [UUID: Data] = [:]

    init(directory: URL?) {
        self.directory = directory
    }

    func picture(for screen: UUID) -> Data? {
        _ = revision
        if let cached = cache[screen] { return cached }
        guard let url = url(for: screen), let data = try? Data(contentsOf: url) else { return nil }
        cache[screen] = data
        return data
    }

    func save(_ picture: Data, for screen: UUID) {
        cache[screen] = picture
        revision += 1
        guard let directory, let url = url(for: screen) else { return }
        do {
            try prepare(directory)
            try picture.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            log.error("The screen's picture couldn't be kept: \(String(describing: error), privacy: .public)")
        }
    }

    func forget(_ screen: UUID) {
        cache[screen] = nil
        revision += 1
        if let url = url(for: screen) { try? FileManager.default.removeItem(at: url) }
    }

    private func url(for screen: UUID) -> URL? {
        directory?.appendingPathComponent("\(screen.uuidString).jpg")
    }

    /// The folder, complete file protection and out of backups (for the folder and what is in it).
    private func prepare(_ directory: URL) throws {
        var folder = directory
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }
}
