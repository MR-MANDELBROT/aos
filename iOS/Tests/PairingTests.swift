import Foundation
import Testing
@testable import aOS

/// Reference values computed independently (Python hmac/hashlib, ssh-keygen); see the final report.
enum Vectors {
    static let code = Data(0..<16)
    static let codeBase64URL = "AAECAwQFBgcICQoLDA0ODw"
    /// P-256 generator point as a public key.
    static let p256Key = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU="
    static let p256Fingerprint = "SHA256:SFMVDOrhOSBssOVH9hIcK/Z2XVf1oSVMjNCL8u2aICY"
    static let device = "Max\u{2019}s iPhone"
    static let proof = "mrui6J5uTrdDd7yaEdlJQU6kWIO77PVkB04oYtW2SAQ="
    /// A throwaway ed25519 key and what `ssh-keygen -lf` printed for it.
    static let ed25519Key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN8Rl2qwv75VjkzLHaW5OyZu4CaxGsZU2+cYoDrSFSrY"
    static let ed25519Fingerprint = "SHA256:IKIpT5qrBHciGB6LMk+7fuTQHDnNluSkoLBSGY4SWMQ"

    static let generatorX963 = Data([0x04]) + Data(hex: "6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296")
        + Data(hex: "4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5")
}

extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}

struct PairingLinkTests {
    let full = "aos-pair://v1?n=Max%E2%80%99s%20MacBook%20Pro&h=Maxs-MacBook-Pro.local,192.168.1.20,maxs-mbp.tail1234.ts.net&p=50123&s=22&u=max&k=SHA256%3AIKIpT5qrBHciGB6LMk%2B7fuTQHDnNluSkoLBSGY4SWMQ&c=AAECAwQFBgcICQoLDA0ODw"

    @Test func parsesAllFields() throws {
        let link = try PairingLink(full)
        #expect(link.macName == "Max\u{2019}s MacBook Pro")
        #expect(link.hosts == ["Maxs-MacBook-Pro.local", "192.168.1.20", "maxs-mbp.tail1234.ts.net"])
        #expect(link.pairingPort == 50123)
        #expect(link.sshPort == 22)
        #expect(link.user == "max")
        #expect(link.hostKeyFingerprint == Vectors.ed25519Fingerprint)
        #expect(link.code == Vectors.code)
    }

    @Test func toleratesWhitespaceEncodedCommasAndDefaults() throws {
        // Comma percent-encoded, no "s", fingerprint with padding, "+" left unencoded, surrounding white space
        let text = "  aos-pair://v1?h=mac.local%2C10.0.0.5&p=4000&u=max&k=SHA256:IKIpT5qrBHciGB6LMk+7fuTQHDnNluSkoLBSGY4SWMQ=&c=AAECAwQFBgcICQoLDA0ODw\n"
        let link = try PairingLink(text)
        #expect(link.hosts == ["mac.local", "10.0.0.5"])
        #expect(link.sshPort == 22)
        #expect(link.hostKeyFingerprint == Vectors.ed25519Fingerprint)
        #expect(link.macName == "mac.local")
    }

    @Test func roundTripsThroughItsURL() throws {
        let link = PairingLink(macName: "Studio & Co / 2", hosts: ["studio.local", "fe80::1"], pairingPort: 61000,
                               sshPort: 2222, user: "max.m", hostKeyFingerprint: Vectors.p256Fingerprint, code: Vectors.code)
        let parsed = try PairingLink(link.url.absoluteString)
        #expect(parsed == link)
    }

    @Test func plainSpacesInAPastedLink() throws {
        let link = try PairingLink("aos-pair://v1?n=Max MacBook&h=mac.local&p=1&u=max&k=\(Vectors.ed25519Fingerprint)&c=\(Vectors.codeBase64URL)")
        #expect(link.macName == "Max MacBook")
    }

    @Test func rejectsBrokenLinks() {
        let k = "k=SHA256%3AIKIpT5qrBHciGB6LMk%2B7fuTQHDnNluSkoLBSGY4SWMQ"
        let c = "c=AAECAwQFBgcICQoLDA0ODw"
        #expect(throws: PairingLink.ParseError.notAPairingLink) { try PairingLink("https://example.com/?h=a") }
        #expect(throws: PairingLink.ParseError.newerVersion) { try PairingLink("aos-pair://v2?h=a&p=1&u=m&\(k)&\(c)") }
        #expect(throws: PairingLink.ParseError.missing("h")) { try PairingLink("aos-pair://v1?p=1&u=m&\(k)&\(c)") }
        #expect(throws: PairingLink.ParseError.missing("u")) { try PairingLink("aos-pair://v1?h=a&p=1&\(k)&\(c)") }
        #expect(throws: PairingLink.ParseError.invalid("p")) { try PairingLink("aos-pair://v1?h=a&p=70000&u=m&\(k)&\(c)") }
        #expect(throws: PairingLink.ParseError.invalid("k")) { try PairingLink("aos-pair://v1?h=a&p=1&u=m&k=MD5:aa&\(c)") }
        // 15 bytes only
        #expect(throws: PairingLink.ParseError.invalid("c")) { try PairingLink("aos-pair://v1?h=a&p=1&u=m&\(k)&c=AAECAwQFBgcICQoLDA0O") }
        #expect(throws: PairingLink.ParseError.invalid("h")) { try PairingLink("aos-pair://v1?h=a/b&p=1&u=m&\(k)&\(c)") }
        #expect(throws: PairingLink.ParseError.invalid("u")) { try PairingLink("aos-pair://v1?h=a&p=1&u=a%0Ab&\(k)&\(c)") }
    }
}

struct PairingProofTests {
    @Test func proofMatchesTheReference() {
        #expect(PairingRequest.proof(code: Vectors.code, key: Vectors.p256Key, device: Vectors.device) == Vectors.proof)
    }

    @Test func requestLineIsOneJSONObject() throws {
        let request = PairingRequest(device: Vectors.device, key: Vectors.p256Key, code: Vectors.code)
        let line = try request.line()
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        let text = String(decoding: line, as: UTF8.self)
        #expect(text == "{\"device\":\"Max\u{2019}s iPhone\",\"key\":\"\(Vectors.p256Key)\",\"proof\":\"\(Vectors.proof)\",\"v\":1}\n")
        let decoded = try JSONDecoder().decode(PairingRequest.self, from: line)
        #expect(decoded == request)
    }

    @Test func deviceNamesAreOneLine() {
        #expect(PairingRequest.sanitizedDeviceName("Max\n iPhone\u{0007}") == "Max iPhone")
        #expect(PairingRequest.sanitizedDeviceName("   ") == "iPhone")
        #expect(PairingRequest.sanitizedDeviceName(String(repeating: "x", count: 100)).count == 64)
    }

    @Test func decodesTheAnswer() throws {
        let ok = try JSONDecoder().decode(PairingResponse.self, from: Data(#"{"ok":true,"user":"max","companion":"/Applications/aOS.app/Contents/MacOS/aos-companion"}"#.utf8))
        #expect(ok.ok && ok.user == "max" && ok.companion?.hasSuffix("aos-companion") == true)
        let failed = try JSONDecoder().decode(PairingResponse.self, from: Data(#"{"ok":false,"error":"wrong code"}"#.utf8))
        #expect(!failed.ok && failed.error == "wrong code")
    }
}

struct SSHKeyFormatTests {
    @Test func p256PublicKeyInOpenSSHForm() {
        #expect(SSHKeyFormat.openSSHP256(x963: Vectors.generatorX963) == Vectors.p256Key)
    }

    @Test func fingerprintsLikeSSHKeygen() {
        #expect(SSHKeyFormat.fingerprint(openSSHKey: Vectors.ed25519Key) == Vectors.ed25519Fingerprint)
        #expect(SSHKeyFormat.fingerprint(openSSHKey: Vectors.p256Key) == Vectors.p256Fingerprint)
        #expect(SSHKeyFormat.fingerprint(openSSHKey: Vectors.ed25519Key + " comment here") == Vectors.ed25519Fingerprint)
        // type text and blob disagree
        #expect(SSHKeyFormat.fingerprint(openSSHKey: "ssh-rsa " + Vectors.ed25519Key.split(separator: " ")[1]) == nil)
    }

    @Test func normalizesFingerprints() {
        #expect(SSHKeyFormat.normalizedFingerprint(Vectors.ed25519Fingerprint + "=") == Vectors.ed25519Fingerprint)
        #expect(SSHKeyFormat.normalizedFingerprint("SHA256:abc") == nil)
        #expect(SSHKeyFormat.fingerprintsEqual(Vectors.ed25519Fingerprint, Vectors.ed25519Fingerprint))
        #expect(!SSHKeyFormat.fingerprintsEqual(Vectors.ed25519Fingerprint, Vectors.p256Fingerprint))
    }

    @Test func base64URL() {
        #expect(SSHKeyFormat.base64URLDecode(Vectors.codeBase64URL) == Vectors.code)
        #expect(SSHKeyFormat.base64URLEncode(Data([0xfb, 0xff])) == "-_8")
        #expect(SSHKeyFormat.base64URLDecode("-_8") == Data([0xfb, 0xff]))
        #expect(SSHKeyFormat.base64URLDecode("a+b") == nil)
    }
}
