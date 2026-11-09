@testable import aos_guest_helper
import XCTest

final class SignInFieldTests: XCTestCase {
    func testGeneratedIdsDontMakeACodeField() {
        // Instagram (2026-11-09): a generated React id with "pin" or "code" inside asked for a code.
        XCTAssertEqual(SignInField.kind(secure: false, labels: ["Telefonnummer, Benutzername oder E-Mail-Adresse"],
                                        domIdentifier: "_R_1ainkqsqppb6am_"), "username")
        XCTAssertEqual(SignInField.kind(secure: false, labels: [], domIdentifier: "_r_spinx_"), "username")
        XCTAssertEqual(SignInField.kind(secure: false, labels: ["Phone number, username, or email"],
                                        domIdentifier: "otp"), "username")
    }

    func testCodeFields() {
        XCTAssertEqual(SignInField.kind(secure: false, labels: ["Bestätigungscode"], domIdentifier: nil), "code")
        XCTAssertEqual(SignInField.kind(secure: false, labels: ["Enter the code we sent to your email"], domIdentifier: nil), "code")
        XCTAssertEqual(SignInField.kind(secure: false, labels: ["Authentication code"], domIdentifier: "app_totp"), "code")
        XCTAssertEqual(SignInField.kind(secure: false, labels: ["6-digit code"], domIdentifier: nil), "code")
        XCTAssertEqual(SignInField.kind(secure: false, labels: [], domIdentifier: "otpInput"), "code")
        XCTAssertEqual(SignInField.kind(secure: false, labels: [], domIdentifier: "verification-code"), "code")
        XCTAssertEqual(SignInField.kind(secure: false, labels: ["Einmalpasswort"], domIdentifier: nil), "code")
        XCTAssertEqual(SignInField.kind(secure: false, labels: ["PIN"], domIdentifier: nil), "code")
    }

    func testOtherFields() {
        XCTAssertEqual(SignInField.kind(secure: true, labels: ["Code"], domIdentifier: nil), "password")
        XCTAssertEqual(SignInField.kind(secure: false, labels: ["Postleitzahl"], domIdentifier: "zip-code"), "username")
        XCTAssertEqual(SignInField.kind(secure: false, labels: ["Email or phone"], domIdentifier: "identifierId"), "username")
        XCTAssertEqual(SignInField.kind(secure: false, labels: ["Shipping address"], domIdentifier: nil), "username")
    }
}
