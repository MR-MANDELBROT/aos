import Foundation
import Testing
@testable import aOS

struct BitwardenImportTests {
    /// Shaped like Bitwarden's "JSON" export (unencrypted), with a login, a note, a card, a login with custom fields
    /// and a passkey-only login.
    static let json = """
    {
      "encrypted": false,
      "folders": [{ "id": "f1", "name": "Uni" }],
      "items": [
        {
          "passwordHistory": null, "revisionDate": "2026-10-01T10:00:00.000Z", "creationDate": "2026-01-01T10:00:00.000Z",
          "id": "a1", "organizationId": null, "folderId": "f1", "type": 1, "reprompt": 0,
          "name": "TUMonline", "notes": "Matrikelnummer im Ausweis", "favorite": true,
          "fields": [{ "name": "PIN", "value": "1234", "type": 1, "linkedId": null },
                     { "name": "Linked", "value": null, "type": 3, "linkedId": 100 }],
          "login": {
            "fido2Credentials": [],
            "uris": [{ "match": null, "uri": "https://campus.tum.de/tumonline" }, { "match": 1, "uri": "login.tum.de" }],
            "username": "ge12abc", "password": "pa\\"ss/word", "totp": "otpauth://totp/TUM?secret=GEZDGNBV", "passwordRevisionDate": null
          },
          "collectionIds": null
        },
        { "id": "a2", "type": 2, "name": "Secret note", "notes": "x", "secureNote": { "type": 0 } },
        { "id": "a3", "type": 3, "name": "Visa", "card": { "number": "4111111111111111" } },
        { "id": "a4", "type": 1, "name": "", "login": { "uris": [{ "uri": "https://www.amazon.de/" }], "username": "max@example.com", "password": "hunter2", "totp": null } },
        { "id": "a5", "type": 1, "name": "Passkey only", "login": { "uris": [], "username": null, "password": null, "fido2Credentials": [{}] } }
      ]
    }
    """

    @Test func json() throws {
        let result = try BitwardenImport.parse(data: Data(Self.json.utf8), fileName: "bitwarden_export_20261106.json")
        #expect(result.skippedOther == 2)
        #expect(result.skippedEmpty == 1)
        #expect(result.logins.count == 2)
        let tum = result.logins[0]
        #expect(tum.title == "TUMonline")
        #expect(tum.username == "ge12abc")
        #expect(tum.password == "pa\"ss/word")
        #expect(tum.uris == ["https://campus.tum.de/tumonline", "login.tum.de"])
        #expect(tum.totp == "otpauth://totp/TUM?secret=GEZDGNBV")
        #expect(tum.notes == "Matrikelnummer im Ausweis\n\nPIN: 1234")
        // Without a name the host of the first URI names it
        #expect(result.logins[1].title == "www.amazon.de")
        #expect(result.logins[1].totp == "")
    }

    @Test func encryptedExportsAreRefused() {
        let passwordProtected = #"{"encrypted": true, "passwordProtected": true, "salt": "x", "kdfType": 0, "kdfIterations": 600000, "encKeyValidation_DO_NOT_EDIT": "2.x|y|z", "data": "2.a|b|c"}"#
        #expect(throws: BitwardenImport.ImportError.encrypted) {
            try BitwardenImport.parse(data: Data(passwordProtected.utf8), fileName: "export.json")
        }
        let accountRestricted = #"{"encrypted": true, "encKeyValidation_DO_NOT_EDIT": "2.x|y|z", "folders": [], "items": []}"#
        #expect(throws: BitwardenImport.ImportError.encrypted) {
            try BitwardenImport.parse(data: Data(accountRestricted.utf8), fileName: "export.json")
        }
        #expect(throws: BitwardenImport.ImportError.notBitwarden) {
            try BitwardenImport.parse(data: Data(#"{"hello": 1}"#.utf8), fileName: "x.json")
        }
        #expect(throws: BitwardenImport.ImportError.unreadable) {
            try BitwardenImport.parse(data: Data("{ not json".utf8), fileName: "x.json")
        }
    }

    /// Shaped like Bitwarden's "CSV" export: CRLF rows, quoted fields with commas, quotes and line breaks.
    static let csv = "\u{FEFF}folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\r\n"
        + "Uni,1,login,TUMonline,\"Zeile 1\nZeile 2\",\"PIN: 1234\",0,\"https://campus.tum.de,login.tum.de\",ge12abc,\"pa\"\"ss,word\",GEZDGNBV\r\n"
        + ",,note,Secret note,just a note,,0,,,,\r\n"
        + ",,login,GitHub,,,0,https://github.com,max,hunter2,\r\n"
        + ",,login,Empty,,,0,https://example.com,,,\r\n"

    @Test func csv() throws {
        let result = try BitwardenImport.parse(data: Data(Self.csv.utf8), fileName: "bitwarden_export.csv")
        #expect(result.skippedOther == 1)
        #expect(result.skippedEmpty == 1)
        #expect(result.logins.count == 2)
        let tum = result.logins[0]
        #expect(tum.title == "TUMonline")
        #expect(tum.notes == "Zeile 1\nZeile 2\n\nPIN: 1234")
        #expect(tum.uris == ["https://campus.tum.de", "login.tum.de"])
        #expect(tum.username == "ge12abc")
        #expect(tum.password == "pa\"ss,word")
        #expect(tum.totp == "GEZDGNBV")
        #expect(result.logins[1] == ImportedLogin(title: "GitHub", username: "max", password: "hunter2",
                                                  uris: ["https://github.com"], totp: "", notes: ""))
    }

    @Test func csvWithoutBitwardenColumns() {
        #expect(throws: BitwardenImport.ImportError.notBitwarden) {
            try BitwardenImport.parse(data: Data("url,username,password\nhttps://a.com,u,p\n".utf8), fileName: "passwords.csv")
        }
    }
}

struct CSVTests {
    @Test func quotingRules() throws {
        let rows = try CSV.parse("a,\"b,c\",\"d\"\"e\"\n\"multi\nline\",,x\r\nlast,row")
        #expect(rows == [["a", "b,c", "d\"e"], ["multi\nline", "", "x"], ["last", "row"]])
    }

    @Test func emptyLinesAreSkippedAndTrailingCommasKept() throws {
        #expect(try CSV.parse("a,b,\n\n\nc,d,e\n") == [["a", "b", ""], ["c", "d", "e"]])
    }

    @Test func unterminatedQuote() {
        #expect(throws: CSV.ParseError.self) { try CSV.parse("a,\"b\n") }
    }
}
