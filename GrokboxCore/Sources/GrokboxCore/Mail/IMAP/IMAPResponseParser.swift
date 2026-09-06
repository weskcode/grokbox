import Foundation

/// Parses the handful of IMAP server responses Grokbox actually needs.
///
/// This is intentionally narrow rather than a general IMAP grammar: fewer
/// moving parts, and every response shape it handles is covered by a test.
enum IMAPResponseParser {

    // MARK: - LIST

    /// `* LIST (\HasNoChildren \All) "/" "[Gmail]/All Mail"`
    static func parseListLine(_ text: String) -> IMAPMailbox? {
        guard text.hasPrefix("* LIST ") else { return nil }
        guard let attrOpen = text.firstIndex(of: "("),
              let attrClose = text[attrOpen...].firstIndex(of: ")") else { return nil }

        let attributes = text[text.index(after: attrOpen)..<attrClose]
            .split(separator: " ")
            .map(String.init)

        // The mailbox name is the final token: quoted, or bare if it has no spaces.
        let rest = text[text.index(after: attrClose)...].trimmingCharacters(in: .whitespaces)
        let name: String
        if rest.hasSuffix("\""),
           let lastQuoteOpen = rest.dropLast().lastIndex(of: "\"") {
            name = String(rest[rest.index(after: lastQuoteOpen)..<rest.index(before: rest.endIndex)])
        } else if let bare = rest.split(separator: " ").last {
            name = String(bare)
        } else {
            return nil
        }

        guard !name.isEmpty else { return nil }
        // The delimiter sits between the attributes and the name: `"/"`, `"."`, or NIL.
        let delimiter: String?
        if let q = rest.firstIndex(of: "\""), rest.hasPrefix("\""),
           let q2 = rest[rest.index(after: q)...].firstIndex(of: "\""), rest.index(after: q) < q2 {
            let d = String(rest[rest.index(after: q)..<q2]); delimiter = d == "\\\\" ? "\\" : d
        } else if rest.uppercased().hasPrefix("NIL") {
            delimiter = nil
        } else {
            delimiter = "/"
        }
        return IMAPMailbox(name: name, attributes: attributes, delimiter: delimiter)
    }

    // MARK: - COPYUID (RFC 4315)

    /// `a5 OK [COPYUID 1725000000 10,12:14 301:303] Success` → validity and the
    /// destination UIDs, expanded in order.
    static func parseCopyUID(_ text: String) -> (validity: UInt32, destination: [UInt32])? {
        guard let open = text.range(of: "[COPYUID ") else { return nil }
        guard let close = text[open.upperBound...].firstIndex(of: "]") else { return nil }
        let parts = text[open.upperBound..<close].split(separator: " ")
        guard parts.count == 3, let validity = UInt32(parts[0]) else { return nil }
        return (validity, expandUIDSet(String(parts[2])))
    }

    /// `10,12:14` → `[10, 12, 13, 14]`.
    static func expandUIDSet(_ set: String) -> [UInt32] {
        var out: [UInt32] = []
        for piece in set.split(separator: ",") {
            let bounds = piece.split(separator: ":")
            if bounds.count == 2, let a = UInt32(bounds[0]), let b = UInt32(bounds[1]) {
                out.append(contentsOf: min(a, b)...max(a, b))
            } else if let one = UInt32(piece) {
                out.append(one)
            }
        }
        return out
    }

    // MARK: - CAPABILITY

    /// `* CAPABILITY IMAP4rev1 UNSELECT IDLE NAMESPACE QUOTA ID XLIST CHILDREN X-GM-EXT-1 UIDPLUS MOVE`
    static func parseCapability(_ text: String) -> Set<String>? {
        guard text.hasPrefix("* CAPABILITY ") else { return nil }
        return Set(text.dropFirst("* CAPABILITY ".count).split(separator: " ").map { $0.uppercased() })
    }

    // MARK: - EXAMINE / SELECT

    /// `* OK [UIDVALIDITY 1725000000] UIDs valid`
    static func parseUIDValidity(_ text: String) -> UInt32? {
        guard let range = text.range(of: "[UIDVALIDITY ") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return UInt32(digits)
    }

    /// `X-GM-LABELS (\Inbox "Grokbox/Swept" \Important)` → the labels.
    static func parseGmailLabels(in text: String) -> [String]? {
        guard let start = text.range(of: "X-GM-LABELS (") else { return nil }
        var labels: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for char in text[start.upperBound...] {
            if escaped { current.append(char); escaped = false; continue }
            if char == "\\" && inQuotes { escaped = true; continue }
            if char == "\"" { inQuotes.toggle(); continue }
            if !inQuotes && char == ")" { break }
            if !inQuotes && char == " " {
                if !current.isEmpty { labels.append(current) }
                current = ""
                continue
            }
            current.append(char)
        }
        if !current.isEmpty { labels.append(current) }
        return labels
    }

    /// `* 12 FETCH (UID 340 FLAGS (\Seen) X-GM-LABELS (\Inbox))` — no literal.
    static func parseFlagsLine(_ text: String) -> FlagUpdate? {
        guard text.hasPrefix("* "), text.contains(" FETCH ") else { return nil }
        guard let uid = scanUInt32(after: "UID ", in: text), uid > 0 else { return nil }
        let flags = scanDelimited(after: "FLAGS (", until: ")", in: text) ?? ""
        return FlagUpdate(
            uid: uid,
            isUnread: !flags.localizedCaseInsensitiveContains("\\Seen"),
            isFlagged: flags.localizedCaseInsensitiveContains("\\Flagged"),
            gmailLabels: parseGmailLabels(in: text)
        )
    }

    /// `* 40000 EXISTS`
    static func parseExists(_ text: String) -> Int? {
        let parts = text.split(separator: " ")
        guard parts.count >= 3, parts[0] == "*", parts[2].uppercased() == "EXISTS" else { return nil }
        return Int(parts[1])
    }

    // MARK: - FETCH

    /// `* 1 FETCH (UID 42 FLAGS (\Seen) INTERNALDATE "05-Sep-2026 10:00:00 +0000" BODY[...] {87}`
    /// followed by the 87-byte header block in `line.literals[0]`.
    static func parseFetchLine(_ line: IMAPLine) -> FetchedHeader? {
        let text = line.text
        guard text.hasPrefix("* "), text.contains(" FETCH ") else { return nil }
        guard let headerData = line.literals.first else { return nil }

        let uid = scanUInt32(after: "UID ", in: text) ?? 0
        guard uid > 0 else { return nil }

        let flags = scanDelimited(after: "FLAGS (", until: ")", in: text) ?? ""
        let isUnread = !flags.localizedCaseInsensitiveContains("\\Seen")
        let isFlagged = flags.localizedCaseInsensitiveContains("\\Flagged")

        let internalDate = scanDelimited(after: "INTERNALDATE \"", until: "\"", in: text)
            .flatMap(parseInternalDate)

        let headers = MIMEHeaders(raw: headerData)
        let from = AddressParser.first(in: headers["from"] ?? "")
        let recipients = AddressParser.all(in: [headers["to"], headers["cc"]].compactMap(\.self).joined(separator: ","))

        // Prefer the server's INTERNALDATE: it is authoritative and always
        // well-formed, where a client-supplied Date: header may be neither.
        let date = internalDate ?? headers["date"].flatMap(parseRFC2822Date) ?? .distantPast

        return FetchedHeader(
            uid: uid,
            subject: headers.decoded("subject") ?? "(no subject)",
            senderName: from.name.isEmpty ? headers.decoded("from") ?? "" : from.name,
            senderAddress: from.address,
            recipients: recipients,
            date: date,
            isUnread: isUnread,
            isFlagged: isFlagged,
            gmailLabels: parseGmailLabels(in: text),
            listUnsubscribe: headers["list-unsubscribe"],
            listUnsubscribePost: headers["list-unsubscribe-post"],
            listID: headers["list-id"],
            messageID: headers["message-id"]
        )
    }

    // MARK: - Scanning helpers

    static func scanUInt32(after prefix: String, in text: String) -> UInt32? {
        guard let range = text.range(of: prefix) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return UInt32(digits)
    }

    static func scanDelimited(after prefix: String, until terminator: Character, in text: String) -> String? {
        guard let range = text.range(of: prefix) else { return nil }
        let tail = text[range.upperBound...]
        guard let end = tail.firstIndex(of: terminator) else { return nil }
        return String(tail[..<end])
    }

    // MARK: - Dates

    /// IMAP INTERNALDATE: `05-Sep-2026 10:00:00 +0000`
    static func parseInternalDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }

    /// RFC 2822 `Date:` header, with and without the leading day name.
    static func parseRFC2822Date(_ value: String) -> Date? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z",
            "d MMM yyyy HH:mm Z"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }
}
