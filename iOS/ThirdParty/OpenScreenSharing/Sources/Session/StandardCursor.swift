// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import Foundation

nonisolated enum StandardCursor: Equatable, Sendable {
    case arrow
    case contextualMenu
    case pointingHand
    case openHand
    case closedHand
    case dragLink
    case dragCopy
    case operationNotAllowed
    case iBeam
    case verticalIBeam
    case crosshair
    case zoomIn
    case zoomOut
    case resize(ResizeDirections)

    nonisolated struct ResizeDirections: OptionSet, Hashable, Sendable {
        let rawValue: UInt8

        static let up = ResizeDirections(rawValue: 1 << 0)
        static let down = ResizeDirections(rawValue: 1 << 1)
        static let left = ResizeDirections(rawValue: 1 << 2)
        static let right = ResizeDirections(rawValue: 1 << 3)
        static let upLeft = ResizeDirections(rawValue: 1 << 4)
        static let upRight = ResizeDirections(rawValue: 1 << 5)
        static let downLeft = ResizeDirections(rawValue: 1 << 6)
        static let downRight = ResizeDirections(rawValue: 1 << 7)
    }

    // Cursor images the Mac sends for the AppKit cursors of macOS 27.0.1 26A434: ScreensharingAgent passes the
    // CGSGetGlobalCursorData image and hotspot to screensharingd unscaled (ScreensharingAgent 756.36.5.2,
    // UUID DA1CD9BA-97A1-3758-B425-00FA34B428A3, sub_100029818 0x100029860..0x10002991c).
    private static let known: [UInt64: StandardCursor] = [
        0x550c_f3e1_2f82_e290: .arrow,
        0xa1d0_4e5d_7b36_38c1: .contextualMenu,
        0x794a_89c5_f925_811d: .pointingHand,
        0x5064_4df7_03aa_9698: .openHand,
        0xbee3_f9de_b429_0ac6: .closedHand,
        0xc45e_03a9_8e56_c597: .dragLink,
        0x404d_0f11_c243_6172: .dragCopy,
        0x95ad_88c4_cc9e_3d42: .operationNotAllowed,
        0x892a_7ece_621a_c8c5: .iBeam,
        0x9ae3_c16e_5e50_bde8: .verticalIBeam,
        0xbb6e_1a08_616b_a322: .crosshair,
        0x099f_7efb_ca83_ccba: .zoomIn,
        0x1343_3771_90e9_03aa: .zoomOut,
        0xd39b_94f8_38be_4e58: .resize(.left),
        0x42d8_bbc7_a95a_09ca: .resize(.right),
        0x95e8_7116_9704_c06d: .resize([.left, .right]),
        0xc462_9ef7_e72b_4692: .resize(.up),
        0xddef_b65d_0e8d_7aa3: .resize(.down),
        0x99fa_f011_b1d1_672a: .resize([.up, .down]),
        0xc272_dbe8_fb06_c3b0: .resize([.up, .down]),
        0x8d1c_c66a_b524_f521: .resize(.up),
        0x2168_3648_e46f_acfc: .resize(.down),
        0xbf87_b07e_efdd_81bf: .resize([.left, .right]),
        0x96f9_141f_df6a_48f0: .resize(.left),
        0x248f_9773_6835_ac0d: .resize(.right),
        0x36a3_3a21_5de7_2d90: .resize([.upLeft, .downRight]),
        0xe533_934d_212c_e831: .resize(.upLeft),
        0x1427_a75f_c243_7d9a: .resize(.downRight),
        0x8c24_bd91_dffa_9649: .resize([.upRight, .downLeft]),
        0x5764_40b0_b8e8_5e5b: .resize(.upRight),
        0x1653_1b30_a60c_ab6b: .resize(.downLeft),
        0x355b_7cb0_1599_7adc: .resize([.upLeft, .downRight]),
        0x6f4f_0072_c53c_6f0a: .resize([.upLeft, .downRight]),
        0xd739_435c_b04b_b4c2: .resize([.upRight, .downLeft]),
        0x7659_61df_f520_bfd4: .resize([.upRight, .downLeft]),
        // RDP pointer updates from Windows 11 26200 for the IDC_* cursors at desktop scale 200.
        0xb2f7_1b96_3f1e_d1e4: .arrow,
        0x067a_adb2_834f_6e3b: .iBeam,
        0xc5c5_8c55_5943_12a3: .crosshair,
        0x0813_db11_b868_f101: .pointingHand,
        0xa196_06bd_3c41_0ec1: .operationNotAllowed,
        0x8898_abd5_9d4e_c795: .resize([.upLeft, .downRight]),
        0x0155_8509_6f91_42dd: .resize([.upRight, .downLeft]),
        0xca86_7364_a1e8_0c4c: .resize([.left, .right]),
        0x42df_45dc_09d5_4621: .resize([.up, .down]),
        0x5047_ed4a_7be5_e306: .resize([.up, .down, .left, .right]),
    ]

    static func fingerprint(width: Int, height: Int, hotspotX: Int, hotspotY: Int, pixels: Data) -> UInt64? {
        guard pixels.count >= width * height * 4 else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        for value in [width, height, hotspotX, hotspotY] {
            mix(UInt8(truncatingIfNeeded: value))
            mix(UInt8(truncatingIfNeeded: value >> 8))
        }
        pixels.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: width * height * 4, by: 4) {
                let alpha = bytes[offset + 3]
                mix(alpha)
                if alpha == 255 {
                    mix(Int(bytes[offset]) + 2 * Int(bytes[offset + 1]) + Int(bytes[offset + 2]) >= 512 ? 1 : 0)
                }
            }
        }
        return hash
    }

    init?(fingerprint: UInt64) {
        guard let cursor = Self.known[fingerprint] else { return nil }
        self = cursor
    }
}
