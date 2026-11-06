import Foundation

/// A login read from an export file, before it goes into the vault.
struct ImportedLogin: Equatable, Sendable {
    var title: String
    var username: String
    var password: String
    var uris: [String]
    var totp: String
    var notes: String
}

struct ImportResult: Equatable, Sendable {
    var logins: [ImportedLogin]
    /// Items that are not logins (secure notes, cards, identities, SSH keys); Annex keeps logins only.
    var skippedOther: Int
    /// Logins without user name and password (passkey-only entries, for example).
    var skippedEmpty: Int
}

/// Reads Bitwarden's unencrypted exports: "JSON" and "CSV" (Bitwarden: Tools > Export vault).
/// Encrypted exports can't be read here; the error says so.
enum BitwardenImport {
    enum ImportError: Error, Equatable {
        case encrypted
        case notBitwarden
        case unreadable
        case empty
    }

    static func parse(data: Data, fileName: String) throws -> ImportResult {
        let name = fileName.lowercased()
        let text = String(decoding: data, as: UTF8.self)
        let start = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }.first
        if name.hasSuffix(".json") || start == "{" {
            return try parseJSON(data)
        }
        return try parseCSV(text)
    }

    // MARK: JSON

    private struct Export: Decodable {
        var encrypted: Bool?
        var passwordProtected: Bool?
        var items: [Item]?
    }

    private struct Item: Decodable {
        var type: Int?
        var name: String?
        var notes: String?
        var fields: [Field]?
        var login: Login?
    }

    private struct Field: Decodable {
        var name: String?
        var value: String?
        var type: Int?
    }

    private struct Login: Decodable {
        var username: String?
        var password: String?
        var totp: String?
        var uris: [URI]?
    }

    private struct URI: Decodable { var uri: String? }

    static func parseJSON(_ data: Data) throws -> ImportResult {
        let export: Export
        do { export = try JSONDecoder().decode(Export.self, from: data) } catch { throw ImportError.unreadable }
        if export.encrypted == true || export.passwordProtected == true { throw ImportError.encrypted }
        guard let items = export.items else { throw ImportError.notBitwarden }

        var result = ImportResult(logins: [], skippedOther: 0, skippedEmpty: 0)
        for item in items {
            guard item.type == 1, let login = item.login else { result.skippedOther += 1; continue }
            let fields = (item.fields ?? []).compactMap { field -> String? in
                // 0 text, 1 hidden, 2 boolean; 3 (linked) only points at another field
                guard field.type != 3, let name = field.name, !name.isEmpty else { return nil }
                return "\(name): \(field.value ?? "")"
            }
            let entry = makeLogin(title: item.name, username: login.username, password: login.password,
                                  uris: (login.uris ?? []).compactMap(\.uri), totp: login.totp,
                                  notes: item.notes, extraNotes: fields)
            guard let entry else { result.skippedEmpty += 1; continue }
            result.logins.append(entry)
        }
        if result.logins.isEmpty && result.skippedOther == 0 && result.skippedEmpty == 0 { throw ImportError.empty }
        return result
    }

    // MARK: CSV

    /// Columns of Bitwarden's CSV: folder (or collections), favorite, type, name, notes, fields, reprompt, login_uri,
    /// login_username, login_password, login_totp.
    static func parseCSV(_ text: String) throws -> ImportResult {
        let rows: [[String]]
        do { rows = try CSV.parse(text) } catch { throw ImportError.unreadable }
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else { throw ImportError.empty }
        guard let iName = header.firstIndex(of: "name"),
              let iPassword = header.firstIndex(of: "login_password") else { throw ImportError.notBitwarden }
        let iType = header.firstIndex(of: "type")
        let iNotes = header.firstIndex(of: "notes")
        let iFields = header.firstIndex(of: "fields")
        let iURI = header.firstIndex(of: "login_uri")
        let iUser = header.firstIndex(of: "login_username")
        let iTOTP = header.firstIndex(of: "login_totp")

        var result = ImportResult(logins: [], skippedOther: 0, skippedEmpty: 0)
        for row in rows.dropFirst() {
            func value(_ index: Int?) -> String? {
                guard let index, index < row.count else { return nil }
                return row[index]
            }
            let type = value(iType)?.trimmingCharacters(in: .whitespaces).lowercased() ?? "login"
            guard type == "login" || type.isEmpty else { result.skippedOther += 1; continue }
            // Several URIs are written comma separated (Bitwarden joins them that way) or one per line.
            let uris = (value(iURI) ?? "").split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let fields = (value(iFields) ?? "").split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            let entry = makeLogin(title: value(iName), username: value(iUser), password: value(iPassword),
                                  uris: uris, totp: value(iTOTP), notes: value(iNotes), extraNotes: fields)
            guard let entry else { result.skippedEmpty += 1; continue }
            result.logins.append(entry)
        }
        if result.logins.isEmpty && result.skippedOther == 0 && result.skippedEmpty == 0 { throw ImportError.empty }
        return result
    }

    // MARK: Shared

    private static func makeLogin(title: String?, username: String?, password: String?, uris: [String], totp: String?,
                                  notes: String?, extraNotes: [String]) -> ImportedLogin? {
        let username = (username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password ?? ""
        guard !username.isEmpty || !password.isEmpty else { return nil }
        let uris = uris.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = uris.first.flatMap(HostMatching.host(ofURI:)) ?? username }
        var allNotes = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !extraNotes.isEmpty {
            allNotes += (allNotes.isEmpty ? "" : "\n\n") + extraNotes.joined(separator: "\n")
        }
        return ImportedLogin(title: title, username: username, password: password, uris: uris,
                             totp: (totp ?? "").trimmingCharacters(in: .whitespacesAndNewlines), notes: allNotes)
    }
}
