import Foundation

/// Groups messages that belong to one conversation without needing the
/// server's thread IDs: same sender, same subject once reply and forward
/// prefixes are stripped. Good enough for the Brief, where two rows for one
/// invoice is noise and noise is the enemy.
public enum ThreadKey {
    private static let prefixes = ["re", "fw", "fwd", "aw", "wg", "tr", "sv", "vs", "antw", "rif", "res"]

    /// `"Re: RE: [Fwd] Invoice for March"` → `"invoice for march"`.
    public static func normalizedSubject(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            let lower = s.lowercased()
            for p in prefixes {
                for form in ["\(p):", "\(p) :", "[\(p)]", "\(p)[", "\(p)^"] where lower.hasPrefix(form) {
                    var rest = s.dropFirst(form.count)
                    // "Re[2]:" / "Re^2:" style counters
                    if form.hasSuffix("[") || form.hasSuffix("^") {
                        rest = rest.drop { $0.isNumber || $0 == "]" }
                        if rest.hasPrefix(":") { rest = rest.dropFirst() }
                    }
                    s = rest.trimmingCharacters(in: .whitespacesAndNewlines); changed = true
                }
            }
        }
        return s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func key(accountID: UUID, senderAddress: String, subject: String) -> String {
        "\(accountID.uuidString)|\(senderAddress.lowercased())|\(normalizedSubject(subject))"
    }
}
