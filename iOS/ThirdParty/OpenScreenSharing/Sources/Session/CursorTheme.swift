// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import Foundation
import ImageIO
import Libsharing
import Perception

final class CursorTheme: Identifiable {
    private static let previewCount = 8
    private static let previewRoles = ["default", "pointer", "text", "grab", "not-allowed", "wait", "crosshair", "move", "ew-resize", "zoom-in"]

    private struct Manifest: Decodable {
        var name: String
        var cursors: [String: [Frame]]
    }

    private struct Frame: Decodable {
        var file: String
        var scale: CGFloat
        var hotspotX: CGFloat
        var hotspotY: CGFloat
    }

    let id: String
    let name: String
    let directory: URL
    private let cursors: [String: [Frame]]
    private var images: [String: CGImage] = [:]
    private var previews: (scale: CGFloat, images: [(image: CGImage, scale: CGFloat)])?

    init(directory: URL) throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("theme.json")))
        id = directory.lastPathComponent
        name = manifest.name
        self.directory = directory
        cursors = manifest.cursors.mapValues { $0.sorted { $0.scale < $1.scale } }
    }

    func image(for cursor: StandardCursor, scale: CGFloat) -> (image: CGImage, hotspot: CGPoint, scale: CGFloat)? {
        let roles: [String] =
            switch cursor {
            case .arrow: []
            case .contextualMenu: ["context-menu"]
            case .pointingHand: ["pointer"]
            case .openHand: ["grab", "pointer"]
            case .closedHand: ["grabbing", "grab", "pointer"]
            case .dragLink: ["alias"]
            case .dragCopy: ["copy"]
            case .operationNotAllowed: ["not-allowed"]
            case .iBeam: ["text"]
            case .verticalIBeam: ["vertical-text", "text"]
            case .crosshair: ["crosshair"]
            case .zoomIn: ["zoom-in"]
            case .zoomOut: ["zoom-out"]
            case .resize(let directions):
                switch directions {
                case [.left, .right]: ["ew-resize", "col-resize"]
                case [.up, .down]: ["ns-resize", "row-resize"]
                case [.upLeft, .downRight]: ["nwse-resize"]
                case [.upRight, .downLeft]: ["nesw-resize"]
                case .left: ["w-resize", "ew-resize", "col-resize"]
                case .right: ["e-resize", "ew-resize", "col-resize"]
                case .up: ["n-resize", "ns-resize", "row-resize"]
                case .down: ["s-resize", "ns-resize", "row-resize"]
                case .upLeft: ["nw-resize", "nwse-resize"]
                case .downRight: ["se-resize", "nwse-resize"]
                case .upRight: ["ne-resize", "nesw-resize"]
                case .downLeft: ["sw-resize", "nesw-resize"]
                default: ["move", "all-scroll"]
                }
            }
        guard let role = (roles + ["default"]).first(where: { cursors[$0] != nil }), let frames = cursors[role],
            let frame = frames.first(where: { $0.scale >= scale }) ?? frames.last, let image = image(named: frame.file)
        else { return nil }
        return (image, CGPoint(x: frame.hotspotX / frame.scale, y: frame.hotspotY / frame.scale), frame.scale)
    }

    func previewImages(scale: CGFloat) -> [(image: CGImage, scale: CGFloat)] {
        if let previews, previews.scale == scale { return previews.images }
        let available = Self.previewRoles.compactMap { role -> (image: CGImage, scale: CGFloat)? in
            guard let frames = cursors[role], let frame = frames.first(where: { $0.scale >= scale }) ?? frames.last,
                let image = image(named: frame.file)
            else { return nil }
            return (Self.croppedToContent(image), frame.scale)
        }
        let images = Array(available.prefix(Self.previewCount))
        previews = (scale, images)
        return images
    }

    private func image(named file: String) -> CGImage? {
        if let image = images[file] { return image }
        guard let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(file) as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        images[file] = image
        return image
    }

    private static func croppedToContent(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return image }
        var content = CGRect.null
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
                content = content.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        guard !content.isNull else { return image }
        return image.cropping(to: content) ?? image
    }
}

@Perceptible
final class CursorThemeStore {
    static let shared = CursorThemeStore()

    private(set) var themes: [CursorTheme] = []
    private(set) var isImporting = false

    static let directory = Result<URL, any Error> {
        #if os(iOS)
        let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #else
        let parent = AppDirectory.group
        #endif
        let directory = parent.appendingPathComponent("CursorThemes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    init() {
        reload()
    }

    func theme(id: String) -> CursorTheme? {
        themes.first { $0.id == id }
    }

    func importFile(_ url: URL) async throws {
        let directory = try Self.directory.get()
        isImporting = true
        defer {
            isImporting = false
            reload()
        }
        try await Task.detached(priority: .userInitiated) {
            let staging = directory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            try url.withPickedFile(options: .forUploading) { source in
                var error: NSError?
                LibsharingImportCursorTheme(source.path, staging.path, &error)
                if let error { throw error }
            }
            for theme in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
                try FileManager.default.moveItem(at: theme, to: directory.appendingPathComponent(UUID().uuidString, isDirectory: true))
            }
        }.value
    }

    func delete(_ theme: CursorTheme) throws {
        try FileManager.default.removeItem(at: theme.directory)
        reload()
    }

    private func reload() {
        let entries =
            (try? Self.directory.get()).flatMap {
                try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            } ?? []
        let existing = Dictionary(themes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        themes = entries.compactMap { existing[$0.lastPathComponent] ?? (try? CursorTheme(directory: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if case .theme(let id) = AppSettings.shared.cursorStyle, theme(id: id) == nil {
            AppSettings.shared.cursorStyle = .system
        }
    }
}
