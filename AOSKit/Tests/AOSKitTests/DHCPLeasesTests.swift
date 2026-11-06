@testable import AOSKit
import XCTest

final class DHCPLeasesTests: XCTestCase {
    func testFindsNewestLeaseForNormalizedMAC() {
        let text = """
        {
        \tname=old
        \tip_address=192.168.64.3
        \thw_address=1,a:2:3c:4:5:6
        \tlease=0x60000000
        }
        {
        \tname=guest
        \tip_address=192.168.64.7
        \thw_address=1,a:2:3c:4:5:6
        \tlease=0x70000000
        }
        {
        \tname=other
        \tip_address=192.168.64.9
        \thw_address=1,b:2:3c:4:5:6
        \tlease=0x80000000
        }
        """
        XCTAssertEqual(DHCPLeases.parse(text, mac: "0a:02:3c:04:05:06"), "192.168.64.7")
        XCTAssertNil(DHCPLeases.parse(text, mac: "0a:02:3c:04:05:07"))
    }

    func testRandomPasswordSurvivesKeyboardLayouts() {
        let p = GuestSecrets.randomPassword(length: 32)
        XCTAssertEqual(p.count, 32)
        // Keys that differ between US, German and French layouts must never appear.
        XCTAssertTrue(p.allSatisfy { $0.isLetter && !"aqwyzmAQWYZM".contains($0) }, p)
        XCTAssertEqual(Set(GuestSecrets.passwordAlphabet).count, 40)
    }
}
