import Foundation

/// Turns a raw body excerpt into plain text a model can read.
///
/// Best-effort, not a MIME parser: it finds the first text/plain part if the
/// body is multipart, decodes quoted-printable or base64 if declared, strips
/// tags if what remains is HTML, and truncates. Good enough for a summary,
/// which is all it is for.
public enum BodyExtractor {
    public static func plainText(from raw: Data, maxCharacters: Int = 3_000) -> String {
        let text = String(decoding: raw, as: UTF8.self)
        let part = preferredPart(of: text)
        let decoded = decodeTransferEncoding(part.body, encoding: part.transferEncoding)
        let plain = part.isHTML ? stripHTML(decoded) : decoded
        return collapseWhitespace(plain).prefix(maxCharacters).description
    }

    private struct Part {
        var body: String
        var transferEncoding: String?
        var isHTML: Bool
    }

    /// If the body is multipart, return the first text/plain part; failing that
    /// the first text/html part; failing that the body as-is.
    private static func preferredPart(of text: String) -> Part {
        // Multipart bodies start with a boundary line: `--something`.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard let boundaryLine = lines.first(where: { $0.hasPrefix("--") && $0.count > 4 }) else {
            return Part(body: text, transferEncoding: nil, isHTML: looksLikeHTML(text))
        }
        let boundary = boundaryLine.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !boundary.isEmpty else {
            return Part(body: text, transferEncoding: nil, isHTML: looksLikeHTML(text))
        }

        let sections = text.components(separatedBy: "--\(boundary)")
        var plainCandidate: Part?
        var htmlCandidate: Part?

        for section in sections.dropFirst() {
            guard let headerEnd = section.range(of: "\r\n\r\n") ?? section.range(of: "\n\n") else { continue }
            let headers = section[..<headerEnd.lowerBound].lowercased()
            let body = String(section[headerEnd.upperBound...])
            let encoding = headers.components(separatedBy: "content-transfer-encoding:").dropFirst().first?
                .split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces)

            if headers.contains("text/plain"), plainCandidate == nil {
                plainCandidate = Part(body: body, transferEncoding: encoding, isHTML: false)
            } else if headers.contains("text/html"), htmlCandidate == nil {
                htmlCandidate = Part(body: body, transferEncoding: encoding, isHTML: true)
            }
        }

        return plainCandidate ?? htmlCandidate ?? Part(body: text, transferEncoding: nil, isHTML: looksLikeHTML(text))
    }

    private static func looksLikeHTML(_ text: String) -> Bool {
        let head = text.prefix(600).lowercased()
        return head.contains("<html") || head.contains("<body") || head.contains("<div") || head.contains("<table")
    }

    private static func decodeTransferEncoding(_ body: String, encoding: String?) -> String {
        switch encoding?.lowercased() {
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        case "base64":
            let stripped = body.filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: stripped) else { return body }
            return String(decoding: data, as: UTF8.self)
        default:
            return body
        }
    }

    private static func decodeQuotedPrintable(_ input: String) -> String {
        // Soft line breaks first, then =XX escapes.
        let joined = input.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "")
        var bytes: [UInt8] = []
        let source = Array(joined.utf8)
        var index = 0
        while index < source.count {
            if source[index] == UInt8(ascii: "="), index + 2 < source.count,
               let high = hex(source[index + 1]), let low = hex(source[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }

    static func stripHTML(_ html: String) -> String {
        var text = html
        // Drop script and style blocks wholesale.
        for tag in ["script", "style", "head"] {
            while let open = text.range(of: "<\(tag)", options: .caseInsensitive),
                  let close = text.range(of: "</\(tag)>", options: .caseInsensitive, range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        // Block-level closers become line breaks so paragraphs survive.
        for tag in ["</p>", "</div>", "</tr>", "</li>", "<br>", "<br/>", "<br />", "</h1>", "</h2>", "</h3>"] {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        // Everything else between angle brackets goes.
        var result = ""
        var insideTag = false
        for char in text {
            if char == "<" { insideTag = true; continue }
            if char == ">" { insideTag = false; continue }
            if !insideTag { result.append(char) }
        }
        return decodeEntities(result)
    }

    private static func decodeEntities(_ text: String) -> String {
        let map = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&rsquo;": "'", "&lsquo;": "'", "&rdquo;": "\"", "&ldquo;": "\"", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        var out = text
        for (entity, char) in map { out = out.replacingOccurrences(of: entity, with: char) }
        return out
    }

    private static func collapseWhitespace(_ text: String) -> String {
        var out = ""
        var pendingNewlines = 0
        var pendingSpace = false
        for char in text {
            if char == "\n" || char == "\r" {
                pendingNewlines = min(pendingNewlines + 1, 2)
                pendingSpace = false
            } else if char.isWhitespace {
                pendingSpace = true
            } else {
                if pendingNewlines > 0 {
                    out += String(repeating: "\n", count: pendingNewlines)
                    pendingNewlines = 0
                    pendingSpace = false
                } else if pendingSpace {
                    out += " "
                    pendingSpace = false
                }
                out.append(char)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
