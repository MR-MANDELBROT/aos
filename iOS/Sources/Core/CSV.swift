import Foundation

/// RFC 4180 CSV: quoted fields with "" escapes and line breaks inside quotes, CRLF or LF rows, a UTF-8 BOM ignored.
enum CSV {
    enum ParseError: Error, Equatable { case unterminatedQuote(row: Int) }

    static func parse(_ text: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false
        var iterator = (text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text).unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        func endField() {
            row.append(field)
            field = ""
            fieldStarted = false
        }
        func endRow() {
            endField()
            // Skip completely empty lines
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let following = next() {
                        if following == "\"" { field.unicodeScalars.append("\"") } else { inQuotes = false; pending = following }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"" where !fieldStarted && field.isEmpty:
                inQuotes = true
                fieldStarted = true
            case ",":
                endField()
            case "\r":
                if let following = next(), following != "\n" { pending = following }
                endRow()
            case "\n":
                endRow()
            default:
                field.unicodeScalars.append(c)
                fieldStarted = true
            }
        }
        if inQuotes { throw ParseError.unterminatedQuote(row: rows.count + 1) }
        if fieldStarted || !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
