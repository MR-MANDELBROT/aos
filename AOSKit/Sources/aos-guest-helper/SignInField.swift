import Foundation

/// What a text field on a sign-in page asks for, from its accessible texts: "password", "code" or "username".
///
/// Words, not substrings: a field's DOM id is often generated (React's `_R_1ainkqsqppb6am_`, Instagram's login), and
/// a substring test found "pin" or "code" in such ids and asked the user for a one-time code instead of the sign-in.
/// The visible texts (label, title, placeholder, help) decide; the DOM id only counts with a whole code word in it
/// and nothing in the visible texts that names a user name, email or phone number.
enum SignInField {
    static func kind(secure: Bool, labels: [String], domIdentifier: String?) -> String {
        if secure { return "password" }
        let visible = words(labels.joined(separator: " "))
        if visible.contains(where: isPostal) { return "username" }
        if visible.contains(where: isCodeWord) { return "code" }
        if let id = domIdentifier, !visible.contains(where: isAccountWord),
           identifierWords(id).contains(where: { exactCodeWords.contains($0) }) {
            return "code"
        }
        return "username"
    }

    /// Lowercased words of a text (letters and digits; "E-Mail" gives "e" and "mail").
    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Words of a DOM id: split at separators and camel case ("otpInput", "verification-code").
    static func identifierWords(_ id: String) -> [String] {
        var out: [String] = []
        for part in id.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var word = ""
            for ch in part {
                if ch.isUppercase, !word.isEmpty, word.last?.isLowercase == true {
                    out.append(word.lowercased())
                    word = ""
                }
                word.append(ch)
            }
            if !word.isEmpty { out.append(word.lowercased()) }
        }
        return out
    }

    static let exactCodeWords: Set<String> = ["code", "otp", "totp", "2fa", "mfa", "pin", "passcode", "token",
                                              "authenticator", "verification", "verifizierung", "bestätigung"]

    /// A word of a visible label that means a one-time code ("Bestätigungscode", "Einmalpasswort" included).
    static func isCodeWord(_ w: String) -> Bool {
        if exactCodeWords.contains(w) { return true }
        if w.count > 4, w.hasSuffix("code"), !["postcode", "zipcode", "barcode", "qrcode", "countrycode"].contains(w) {
            return true
        }
        return w.hasPrefix("einmal") || w.hasPrefix("verification") || w.hasPrefix("bestätigung")
            || w.hasPrefix("sicherheitscode") || w.hasPrefix("authenticator")
    }

    /// A word that names the account: then the field is the user name, whatever its id says.
    static func isAccountWord(_ w: String) -> Bool {
        ["user", "username", "benutzer", "benutzername", "nutzername", "email", "mail", "phone", "telefon",
         "telefonnummer", "handy", "handynummer", "mobile", "mobil", "mobilnummer", "login", "anmeldename", "konto",
         "account", "kennung"].contains(w)
    }

    static func isPostal(_ w: String) -> Bool { ["postal", "zip", "plz", "postleitzahl", "postcode", "zipcode"].contains(w) }
}
