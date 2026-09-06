import Foundation

/// A parsed RFC 5322 header block, with case-insensitive lookup.
struct MIMEHeaders: Sendable {
    private var fields: [String: String] = [:]

    init(raw: Data) {
        // Headers may be any charset; UTF-8 with replacement is the safe read,
        // and RFC 2047 encoded-words carry their own charset anyway.
        let text = String(decoding: raw, as: UTF8.self)
        var currentKey: String?
        var currentValue = ""

        func flush() {
            if let key = currentKey {
                fields[key] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            currentKey = nil
            currentValue = ""
        }

        // Swift treats "\r\n" as a single Character, so split on any newline
        // rather than on "\n" — the latter silently never matches CRLF.
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.isEmpty { continue }

            // A line beginning with whitespace is a folded continuation (RFC 5322 §2.2.3).
            if line.first == " " || line.first == "\t" {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }

            flush()
            guard let colon = line.firstIndex(of: ":") else { continue }
            currentKey = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            currentValue = String(line[line.index(after: colon)...])
        }
        flush()
    }

    subscript(key: String) -> String? {
        let value = fields[key.lowercased()]
        return (value?.isEmpty == false) ? value : nil
    }

    /// Header value with RFC 2047 encoded-words expanded to plain text.
    func decoded(_ key: String) -> String? {
        self[key].map(RFC2047.decode)
    }
}

/// Decoder for RFC 2047 encoded-words — the `=?UTF-8?B?...?=` blobs that show up
/// in Subject and From lines. Without this, a large share of real subjects render
/// as unreadable base64.
enum RFC2047 {
    static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }

        var output = ""
        var remainder = Substring(input)

        while let start = remainder.range(of: "=?") {
            output += remainder[..<start.lowerBound]
            let afterMarker = remainder[start.upperBound...]

            // charset ? encoding ? text ?=
            guard let charsetEnd = afterMarker.firstIndex(of: "?") else {
                output += remainder[start.lowerBound...]
                return output
            }
            let charset = String(afterMarker[..<charsetEnd])
            let afterCharset = afterMarker[afterMarker.index(after: charsetEnd)...]

            guard let encodingEnd = afterCharset.firstIndex(of: "?") else {
                output += remainder[start.lowerBound...]
                return output
            }
            let encoding = afterCharset[..<encodingEnd].uppercased()
            let afterEncoding = afterCharset[afterCharset.index(after: encodingEnd)...]

            guard let terminator = afterEncoding.range(of: "?=") else {
                output += remainder[start.lowerBound...]
                return output
            }
            let payload = String(afterEncoding[..<terminator.lowerBound])

            if let decoded = decodePayload(payload, encoding: encoding, charset: charset) {
                output += decoded
            } else {
                output += payload
            }
            remainder = afterEncoding[terminator.upperBound...]

            // Whitespace strictly between two encoded-words is not content (RFC 2047 §6.2).
            let trimmed = remainder.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("=?") { remainder = trimmed }
        }

        output += remainder
        return output
    }

    private static func decodePayload(_ payload: String, encoding: String, charset: String) -> String? {
        let bytes: Data?
        switch encoding {
        case "B":
            bytes = Data(base64Encoded: payload)
        case "Q":
            bytes = decodeQuotedPrintable(payload)
        default:
            return nil
        }
        guard let bytes else { return nil }
        return String(data: bytes, encoding: stringEncoding(for: charset)) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Q-encoding: like quoted-printable, but `_` also means space.
    private static func decodeQuotedPrintable(_ input: String) -> Data? {
        var bytes: [UInt8] = []
        var iterator = Array(input.utf8).makeIterator()
        var pending: [UInt8] = []

        while let byte = iterator.next() {
            pending.append(byte)
        }

        var index = 0
        while index < pending.count {
            let byte = pending[index]
            if byte == UInt8(ascii: "_") {
                bytes.append(UInt8(ascii: " "))
                index += 1
            } else if byte == UInt8(ascii: "="), index + 2 < pending.count,
                      let high = hexValue(pending[index + 1]), let low = hexValue(pending[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(byte)
                index += 1
            }
        }
        return Data(bytes)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }

    private static func stringEncoding(for charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "utf-8", "utf8": .utf8
        case "iso-8859-1", "latin1": .isoLatin1
        case "iso-8859-2": .isoLatin2
        case "windows-1252", "cp1252": .windowsCP1252
        case "us-ascii", "ascii": .ascii
        default: .utf8
        }
    }
}

/// Pulls addresses out of RFC 5322 address lists.
enum AddressParser {
    struct Address: Sendable {
        var name: String
        var address: String
    }

    /// The first address in a header value, with its display name if present.
    static func first(in value: String) -> Address {
        let decoded = RFC2047.decode(value)

        if let open = decoded.firstIndex(of: "<"), let close = decoded[open...].firstIndex(of: ">") {
            let address = String(decoded[decoded.index(after: open)..<close])
            let name = decoded[..<open]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return Address(name: name, address: normalize(address))
        }

        let bare = decoded.split(separator: ",").first.map(String.init) ?? decoded
        return Address(name: "", address: normalize(bare))
    }

    /// Every address in a header value. Used to build the "people I write to" set.
    static func all(in value: String) -> [String] {
        let decoded = RFC2047.decode(value)
        var found: [String] = []

        // Angle-bracketed forms first.
        var remainder = Substring(decoded)
        while let open = remainder.firstIndex(of: "<"),
              let close = remainder[open...].firstIndex(of: ">") {
            let candidate = normalize(String(remainder[remainder.index(after: open)..<close]))
            if isPlausible(candidate) { found.append(candidate) }
            remainder = remainder[remainder.index(after: close)...]
        }

        // Then any bare addresses that were not inside brackets.
        for token in decoded.split(whereSeparator: { ", ;\t\n\r".contains($0) }) {
            guard !token.contains("<") else { continue }
            let candidate = normalize(String(token))
            if isPlausible(candidate) { found.append(candidate) }
        }

        return Array(Set(found))
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>\"' "))
            .lowercased()
    }

    private static func isPlausible(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !parts[0].isEmpty
    }
}
