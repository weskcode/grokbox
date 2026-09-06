import Foundation

/// IMAP's "modified UTF-7" for mailbox names (RFC 3501 §5.1.3). Servers send
/// names in this encoding; a German Drafts folder arrives as `Entw&APw-rfe`.
/// Grokbox decodes for display and encodes anything it creates.
public enum IMAPUTF7 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+,")
    private static let reverse: [Character: UInt32] = {
        var m: [Character: UInt32] = [:]
        for (i, c) in alphabet.enumerated() { m[c] = UInt32(i) }
        return m
    }()

    public static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "&" else { out.append(c); i = s.index(after: i); continue }
            guard let end = s[i...].firstIndex(of: "-") else { return s }   // malformed: return as-is
            let payload = s[s.index(after: i)..<end]
            if payload.isEmpty { out.append("&") }
            else if let text = decodeBase64UTF16(String(payload)) { out.append(text) }
            else { return s }
            i = s.index(after: end)
        }
        return out
    }

    public static func encode(_ s: String) -> String {
        var out = ""
        var run: [UInt16] = []
        func flush() {
            guard !run.isEmpty else { return }
            out.append("&"); out.append(encodeBase64(run)); out.append("-"); run.removeAll()
        }
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v == 0x26 { flush(); out.append("&-") }
            else if (0x20...0x7E).contains(v) { flush(); out.unicodeScalars.append(scalar) }
            else { run.append(contentsOf: Array(String(scalar).utf16)) }
        }
        flush()
        return out
    }

    private static func decodeBase64UTF16(_ payload: String) -> String? {
        var bits: UInt32 = 0, count = 0
        var units: [UInt16] = []
        var pending: UInt8? = nil
        for c in payload {
            guard let v = reverse[c] else { return nil }
            bits = (bits << 6) | v; count += 6
            while count >= 8 {
                count -= 8
                let byte = UInt8((bits >> UInt32(count)) & 0xFF)
                if let hi = pending { units.append(UInt16(hi) << 8 | UInt16(byte)); pending = nil } else { pending = byte }
            }
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    private static func encodeBase64(_ units: [UInt16]) -> String {
        var bytes: [UInt8] = []
        for u in units { bytes.append(UInt8(u >> 8)); bytes.append(UInt8(u & 0xFF)) }
        var out = "", bits: UInt32 = 0, count = 0
        for b in bytes {
            bits = (bits << 8) | UInt32(b); count += 8
            while count >= 6 { count -= 6; out.append(alphabet[Int((bits >> UInt32(count)) & 0x3F)]) }
        }
        if count > 0 { out.append(alphabet[Int((bits << UInt32(6 - count)) & 0x3F)]) }
        return out
    }
}
