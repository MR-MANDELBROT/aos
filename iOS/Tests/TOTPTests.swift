import Foundation
import Testing
@testable import Annex

struct TOTPTests {
    // RFC 6238, Appendix B: the seeds are ASCII "1234567890" repeated to 20, 32 and 64 bytes; 8 digits, 30 s.
    static let seed1 = Data("12345678901234567890".utf8)
    static let seed256 = Data("12345678901234567890123456789012".utf8)
    static let seed512 = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    static let vectors: [(time: TimeInterval, sha1: String, sha256: String, sha512: String)] = [
        (59, "94287082", "46119246", "90693936"),
        (1111111109, "07081804", "68084774", "25091201"),
        (1111111111, "14050471", "67062674", "99943326"),
        (1234567890, "89005924", "91819424", "93441116"),
        (2000000000, "69279037", "90698825", "38618901"),
        (20000000000, "65353130", "77737706", "47863826"),
    ]

    @Test(arguments: vectors.indices)
    func rfc6238(index: Int) {
        let v = Self.vectors[index]
        let date = Date(timeIntervalSince1970: v.time)
        #expect(TOTP(secret: Self.seed1, algorithm: .sha1, digits: 8).code(at: date) == v.sha1)
        #expect(TOTP(secret: Self.seed256, algorithm: .sha256, digits: 8).code(at: date) == v.sha256)
        #expect(TOTP(secret: Self.seed512, algorithm: .sha512, digits: 8).code(at: date) == v.sha512)
    }

    @Test func hotpRFC4226() {
        // RFC 4226 Appendix D, 6 digits
        let expected = ["755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"]
        let otp = TOTP(secret: Self.seed1)
        for (counter, code) in expected.enumerated() {
            #expect(otp.code(counter: UInt64(counter)) == code)
        }
    }

    @Test func otpauthURI() throws {
        let secret = Base32.encode(Self.seed256)
        let otp = try TOTP(parsing: "otpauth://totp/GitHub:max%40example.com?secret=\(secret)&issuer=GitHub&algorithm=SHA256&digits=8&period=60")
        #expect(otp.algorithm == .sha256)
        #expect(otp.digits == 8)
        #expect(otp.period == 60)
        #expect(otp.issuer == "GitHub")
        #expect(otp.account == "max@example.com")
        #expect(otp.secret == Self.seed256)
        // period 60: time 59 is still counter 0
        #expect(otp.code(at: Date(timeIntervalSince1970: 59)) == TOTP(secret: Self.seed256, algorithm: .sha256, digits: 8).code(counter: 0))
    }

    @Test func bareBase32WithSpacesAndLowercase() throws {
        // "12345678901234567890" in base32
        let otp = try TOTP(parsing: "gezd gnbv gy3t qojq gezd gnbv gy3t qojq")
        #expect(otp.secret == Self.seed1)
        #expect(otp.digits == 6 && otp.period == 30 && otp.algorithm == .sha1)
        #expect(otp.code(at: Date(timeIntervalSince1970: 59)) == "287082")
    }

    @Test func rejectsWhatIsNotTOTP() {
        #expect(throws: TOTP.ParseError.self) { try TOTP(parsing: "") }
        #expect(throws: TOTP.ParseError.self) { try TOTP(parsing: "not base32 !") }
        #expect(throws: TOTP.ParseError.unsupported("hotp")) { try TOTP(parsing: "otpauth://hotp/x?secret=GEZDGNBV&counter=1") }
        #expect(throws: TOTP.ParseError.invalidParameter("algorithm")) { try TOTP(parsing: "otpauth://totp/x?secret=GEZDGNBV&algorithm=MD5") }
    }

    @Test func steamGuard() throws {
        let otp = try TOTP(parsing: "steam://GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        let code = otp.code(at: Date(timeIntervalSince1970: 59))
        #expect(code.count == 5)
        #expect(code.allSatisfy { "23456789BCDFGHJKMNPQRTVWXY".contains($0) })
    }

    @Test func secondsRemaining() {
        let otp = TOTP(secret: Self.seed1)
        #expect(otp.secondsRemaining(at: Date(timeIntervalSince1970: 59)) == 1)
        #expect(otp.secondsRemaining(at: Date(timeIntervalSince1970: 60)) == 30)
    }

    @Test func base32RFC4648() {
        let cases = ["": "", "f": "MY", "fo": "MZXQ", "foo": "MZXW6", "foob": "MZXW6YQ", "fooba": "MZXW6YTB", "foobar": "MZXW6YTBOI"]
        for (plain, encoded) in cases where !plain.isEmpty {
            #expect(Base32.encode(Data(plain.utf8)) == encoded)
            #expect(Base32.decode(encoded) == Data(plain.utf8))
            #expect(Base32.decode(encoded + "======") == Data(plain.utf8))
        }
        #expect(Base32.decode("") == nil)
        #expect(Base32.decode("MZ1") == nil)
    }
}
