import Foundation

/// Turns a message excerpt into text a model, a reader, or a link check can use.
///
/// Input is a MIME entity: the message's own `Content-Type` and
/// `Content-Transfer-Encoding` lines, a blank line, then the start of the body
/// (what `MailProvider.bodyExcerpt` returns). A body with no header block at
/// all is still accepted, and its structure sniffed from the first line.
///
/// Small, not a full MIME parser: it walks nested multiparts, skips
/// attachments, keeps the first text/plain and first text/html part, undoes
/// quoted-printable and base64, and decodes each part in its declared charset.
/// Bodies are cut at 8 KB on the wire, so every step tolerates a part that
/// simply stops.
public enum BodyExtractor {
    /// The readable parts of one message. Either may be missing.
    public struct Extracted: Sendable, Equatable {
        public var plain: String?
        public var html: String?
    }

    public static func plainText(from raw: Data, maxCharacters: Int = 3_000) -> String {
        plainText(from: extract(from: raw), maxCharacters: maxCharacters)
    }

    public static func plainText(from parts: Extracted, maxCharacters: Int = 3_000) -> String {
        let plain = parts.plain ?? parts.html.map(stripHTML) ?? ""
        return collapseWhitespace(plain).prefix(maxCharacters).description
    }

    public static func extract(from raw: Data) -> Extracted {
        // ISO-8859-1 maps every byte to one scalar and back, so structure can be
        // found with string operations and each part's bytes recovered intact
        // for decoding in its own charset.
        let latin = String(data: raw, encoding: .isoLatin1) ?? ""
        var out = Extracted()
        if let entity = Entity(parsing: latin) {
            collect(entity, into: &out, depth: 0)
        } else {
            collectHeaderless(latin, into: &out)
        }
        return out
    }

    // MARK: - Structure

    /// One MIME entity, held as ISO-8859-1 text.
    private struct Entity {
        var mediaType: String          // lowercased, e.g. "text/plain"
        var parameters: [String: String]
        var transferEncoding: String?
        var isAttachment: Bool
        var body: String

        /// Nil when the text does not start with a header block (or an empty
        /// one), so the caller can fall back to sniffing.
        init?(parsing text: String) {
            // An empty header block: the entity starts with its blank line.
            if text.hasPrefix("\r\n") || text.hasPrefix("\n") {
                self.init(headers: "", body: text.dropFirst())
                return
            }
            guard Self.startsWithHeaderField(text) else { return nil }
            if let end = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n") {
                self.init(headers: text[..<end.lowerBound], body: text[end.upperBound...])
            } else {
                // Header block cut off by the excerpt limit: no body to read.
                self.init(headers: Substring(text), body: "")
            }
        }

        init(headers: Substring, body: Substring) {
            let fields = MIMEHeaders(raw: headers.data(using: .isoLatin1) ?? Data())
            let (type, parameters) = BodyExtractor.parseContentType(fields["content-type"])
            mediaType = type
            self.parameters = parameters
            transferEncoding = fields["content-transfer-encoding"]?.lowercased().trimmingCharacters(in: .whitespaces)
            isAttachment = fields["content-disposition"]?.lowercased().hasPrefix("attachment") == true
            self.body = String(body)
        }

        private static func startsWithHeaderField(_ text: String) -> Bool {
            let firstLine = text.prefix { $0 != "\r\n" && $0 != "\n" }
            guard let colon = firstLine.firstIndex(of: ":"), colon != firstLine.startIndex else { return false }
            return firstLine[..<colon].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    private static func collect(_ entity: Entity, into out: inout Extracted, depth: Int) {
        guard !entity.isAttachment, depth < 8 else { return }
        if entity.mediaType.hasPrefix("multipart/") {
            let boundary = entity.parameters["boundary"] ?? sniffedBoundary(entity.body)
            guard let boundary else { return }
            for part in split(entity.body, boundary: boundary) {
                let child = Entity(parsing: part) ?? Entity(headers: "", body: Substring(part))
                collect(child, into: &out, depth: depth + 1)
            }
        } else if entity.mediaType == "text/plain" || entity.mediaType.isEmpty {
            // RFC 2045 §5.2: no Content-Type means text/plain; charset=us-ascii.
            if out.plain == nil { out.plain = decode(entity) }
        } else if entity.mediaType == "text/html" {
            if out.html == nil { out.html = decode(entity) }
        }
    }

    /// No header block: a multipart body whose first line is its boundary, or
    /// a single part that is HTML or text by the look of it.
    private static func collectHeaderless(_ text: String, into out: inout Extracted) {
        if let boundary = sniffedBoundary(text) {
            var entity = Entity(headers: "", body: Substring(text))
            entity.mediaType = "multipart/mixed"
            entity.parameters = ["boundary": boundary]
            collect(entity, into: &out, depth: 0)
            if out.plain != nil || out.html != nil { return }
        }
        let decoded = string(from: text.data(using: .isoLatin1) ?? Data(), charset: nil)
        if looksLikeHTML(decoded) { out.html = decoded } else { out.plain = decoded }
    }

    /// The first `--boundary` line, for a multipart whose header was not seen.
    private static func sniffedBoundary(_ text: String) -> String? {
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).prefix(20)
        guard let line = lines.first(where: { $0.hasPrefix("--") && $0.count > 4 }) else { return nil }
        let boundary = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return boundary.isEmpty ? nil : boundary
    }

    /// The parts between `--boundary` delimiter lines, preamble and epilogue dropped.
    private static func split(_ body: String, boundary: String) -> [String] {
        var parts: [String] = []
        for chunk in body.components(separatedBy: "--\(boundary)").dropFirst() {
            if chunk.hasPrefix("--") { break }   // the closing delimiter
            // Drop the rest of the delimiter line, and the line break that
            // belongs to the next delimiter.
            var part = Substring(chunk)
            if let lineEnd = part.firstIndex(where: { $0 == "\r\n" || $0 == "\n" }) {
                part = part[part.index(after: lineEnd)...]
            } else {
                continue
            }
            if part.hasSuffix("\r\n") || part.hasSuffix("\n") { part = part.dropLast() }
            parts.append(String(part))
        }
        return parts
    }

    /// `text/html; charset="utf-8"` → ("text/html", ["charset": "utf-8"]).
    static func parseContentType(_ value: String?) -> (String, [String: String]) {
        guard let value else { return ("", [:]) }
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        for char in value {
            if char == "\"" { inQuotes.toggle(); continue }
            if char == ";" && !inQuotes { pieces.append(current); current = ""; continue }
            current.append(char)
        }
        pieces.append(current)
        let type = pieces.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var parameters: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { parameters[key] = value }
        }
        return (type, parameters)
    }

    // MARK: - Decoding

    private static func decode(_ entity: Entity) -> String {
        let bytes = entity.body.data(using: .isoLatin1) ?? Data()
        let raw: Data = switch entity.transferEncoding {
        case "quoted-printable": decodeQuotedPrintable(bytes)
        case "base64": decodeBase64(bytes)
        default: bytes
        }
        var charset = entity.parameters["charset"]
        if charset == nil, entity.mediaType == "text/html" { charset = metaCharset(in: raw) }
        return string(from: raw, charset: charset)
    }

    /// Bytes in the named charset as a string. Unknown or missing charsets
    /// read as UTF-8 with replacement. A multi-byte sequence cut by the
    /// excerpt limit can make a strict decode fail, so the last few bytes are
    /// dropped and it is tried again before giving up.
    static func string(from data: Data, charset: String?) -> String {
        if let charset, let encoding = encoding(named: charset), encoding != .utf8 {
            for trim in 0...3 where data.count > trim {
                if let decoded = String(data: data.dropLast(trim), encoding: encoding) { return decoded }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func encoding(named name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name.trimmingCharacters(in: .whitespaces) as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// `<meta charset="...">` or `<meta ... content="text/html; charset=...">`
    /// near the top of an HTML part that declared no charset in its header.
    private static func metaCharset(in data: Data) -> String? {
        let head = String(decoding: data.prefix(1_024), as: UTF8.self).lowercased()
        guard let range = head.range(of: #"charset\s*=\s*["']?[a-z0-9_\-:.]+"#, options: .regularExpression) else { return nil }
        let match = head[range]
        return match.split(separator: "=").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
    }

    private static func looksLikeHTML(_ text: String) -> Bool {
        let head = text.prefix(600).lowercased()
        return head.contains("<html") || head.contains("<body") || head.contains("<div") || head.contains("<table")
    }

    private static func decodeBase64(_ data: Data) -> Data {
        let stripped = data.filter { !($0 == 0x0D || $0 == 0x0A || $0 == 0x20 || $0 == 0x09) }
        // A cut-off excerpt ends mid-quantum; decode the whole quanta only.
        let whole = stripped.prefix(stripped.count - stripped.count % 4)
        return Data(base64Encoded: whole) ?? data
    }

    private static func decodeQuotedPrintable(_ input: Data) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(input.count)
        let source = Array(input)
        var index = 0
        while index < source.count {
            guard source[index] == UInt8(ascii: "=") else {
                bytes.append(source[index])
                index += 1
                continue
            }
            // Soft line break: `=` at the end of a line joins it to the next.
            if index + 1 < source.count, source[index + 1] == 0x0A { index += 2; continue }
            if index + 2 < source.count, source[index + 1] == 0x0D, source[index + 2] == 0x0A { index += 3; continue }
            if index + 2 < source.count, let high = hex(source[index + 1]), let low = hex(source[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        return Data(bytes)
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
