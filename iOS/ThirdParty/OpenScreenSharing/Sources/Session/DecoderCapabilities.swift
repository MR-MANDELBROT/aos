// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import CoreMedia
import Foundation
import VideoToolbox

nonisolated struct DecoderCapabilities: Sendable {
    static let current = DecoderCapabilities()

    let supportsHEVC: Bool
    let supportsH264: Bool
    let supportsFullChroma: Bool
    let supportsHDR: Bool
    let maximumPixelRate: Int64

    private init() {
        supportsHEVC = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        supportsH264 = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
        supportsFullChroma = supportsHEVC && Self.decodesInHardware(
            parameterSets: [
                "40010c01ffff0408000003009e2800000300001eba0240",
                "4201010408000003009e2800000300001e90041020b2dd49265780b4040000030004000003000420",
                "4401c172860c0224",
            ],
            frame: "0000000c2801af78ebaefbfe7557cb4f")
        supportsHDR = supportsHEVC && Self.decodesInHardware(
            parameterSets: [
                "40010c01ffff0408000003009c0800000300001e959809",
                "4201010408000003009c0800000300001e900410209b2cacd24995e02d010000030001000003000108",
                "4401c172860c4224",
            ],
            frame: "0000000e2801af1380e668e3ff1cfc7f6cf0")
        maximumPixelRate = supportsHEVC ? Self.decoderMaximumPixelRate() : 0
    }

    var pixelFormats: Int32 {
        var formats: Int32 = (1 << 0) | (1 << 1)
        if supportsFullChroma { formats |= (1 << 3) | (1 << 4) }
        if supportsHDR { formats |= 1 << 5 }
        return formats
    }

    private static func decoderMaximumPixelRate() -> Int64 {
        // ScreenSharing's GetHEVCDecoderMaxSupportedFrameRate probes this 113-byte hvcC at 3840×2160
        // (ScreenSharing 776.27, macOS 27.0.1 26A434, UUID EC0B2C20-F816-3FCE-822D-F9403C09EB50,
        // _GetHEVCDecoderMaxSupportedFrameRate 0x1cc0fb880..0x1cc0fb930, _dummy_hvcc_mem 0x1cc1b62f8).
        let hvcc = hexData(
            "010160000000b0000000000099f000fcfdf8f800000f03a00001001840010c01ffff016000000300b000000300000300991b0240"
                + "a10001002c420101016000000300b00000030000030099a001e020021c5881bb9148cb9fc4fc2fe86fd4a6a04040548040"
                + "a2000100074401c072f05b24"
        )
        let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["hvcC": hvcc]] as CFDictionary
        var description: CMVideoFormatDescription?
        guard
            CMVideoFormatDescriptionCreate(
                allocator: nil, codecType: kCMVideoCodecType_HEVC, width: 3840, height: 2160,
                extensions: extensions, formatDescriptionOut: &description
            ) == noErr,
            let description, let session = hardwareSession(description)
        else { return 0 }
        defer { VTDecompressionSessionInvalidate(session) }
        var value: Unmanaged<CFTypeRef>?
        guard VTSessionCopyProperty(session, key: "MaxDecoderPixelRate" as CFString, allocator: nil, valueOut: &value) == noErr,
            let number = value?.takeRetainedValue() as? NSNumber, number.int64Value > 0
        else { return 0 }
        return number.int64Value
    }

    private static func decodesInHardware(parameterSets: [String], frame: String) -> Bool {
        guard
            let description = try? VideoDecoder.makeFormatDescription(
                VideoFormat(codec: .hevc, parameterSets: parameterSets.map(hexData), bands: 1)),
            let sample = VideoDecoder.makeSampleBuffer(hexData(frame), time: .zero, format: description),
            let session = hardwareSession(description)
        else { return false }
        defer { VTDecompressionSessionInvalidate(session) }
        let decoded = LockedState(initialState: false)
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
            let succeeded = status == noErr && imageBuffer != nil
            decoded.withLock { $0 = succeeded }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return status == noErr && decoded.withLock { $0 }
    }

    private static let hardwareSpecification = ["RequireHardwareAcceleratedVideoDecoder": true]

    private static func hardwareSession(_ description: CMVideoFormatDescription) -> VTDecompressionSession? {
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: description, decoderSpecification: hardwareSpecification as CFDictionary,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session
        )
        return status == noErr ? session : nil
    }

    private static func hexData(_ hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}
