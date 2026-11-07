// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

nonisolated enum NetworkQuality: String, Codable, Sendable {
    case localNetwork
    /// The mode-5 reply sets 6 Mbit/s maximum and 0.333 minimum (observed on iPad17,1, iPadOS 27.2 24B5099f).
    case internet
}

nonisolated enum ChromaSampling: Sendable {
    case yuv420
    case yuv444

    // AVConference mode 7 picks 444f from {420f, 444f}, and 420f from {420f}, in HDR modes 0 and 3
    // (AVConference 2235.63.5.2, macOS 27.0.1 26A434, UUID 93D8C8C0-8B9C-3A5E-A47D-01B5FAF73E1B,
    // -[AVCMediaStreamNegotiator pickBestPixelFormatFromSet:forPayload:] 0x1c12e22a0..0x1c12e24bc,
    // _AVCPixelFormatPreferenceListIPadCompanion 0x1e577943c, _AVCPixelFormatPreferenceListIPadCompanionHDR 0x1e5779444;
    // AVConference 2260.14.1, macOS 27.2 26B5101f, UUID EDFB99EF-2F5E-35DD-8E63-089CBD102EFE,
    // -[AVCMediaStreamNegotiator pickBestPixelFormatFromSet:forPayload:] 0x1c0956090..0x1c09562ac,
    // _AVCPixelFormatPreferenceListIPadCompanion 0x1ec938d74, _AVCPixelFormatPreferenceListIPadCompanionHDR 0x1ec938d7c).
    func pixelFormats(available: Int32) -> Int32 {
        switch self {
        case .yuv420:
            return available & 0x07
        case .yuv444:
            return available
        }
    }
}

nonisolated enum MaximumFrameRate: Int, Codable, CaseIterable, Identifiable, Sendable {
    case thirty = 30
    case sixty = 60

    var id: Self { self }
}

nonisolated struct NetworkConfiguration: Equatable, Sendable {
    var quality: NetworkQuality = .localNetwork
    var internetMaximumFrameRate: MaximumFrameRate = .sixty

    var usesCoreDevice: Bool { quality == .internet }

    var bands: Int { usesCoreDevice ? 1 : 4 }

    var schedulesPresentation: Bool { quality == .localNetwork }

    var maximumFrameRate: MaximumFrameRate {
        quality == .localNetwork ? .sixty : internetMaximumFrameRate
    }

    /// Mode 5 negotiated 4:2:0 (observed on iPad17,1, iPadOS 27.2 24B5099f).
    var chroma: ChromaSampling { usesCoreDevice ? .yuv420 : .yuv444 }
}
