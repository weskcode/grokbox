import Foundation

/// The checks a careful mail client makes before it lets you click.
///
/// Grokbox never renders HTML, so tracking pixels and scripts cannot run.
/// What it *can* do, on the body excerpt the reader already fetches, is
/// notice the classic phishing tells and say so on the row.
public enum LinkHygiene {
    public struct Report: Sendable, Equatable {
        public var warnings: [String]
        public var linkHosts: [String]
        public var isSuspicious: Bool { !warnings.isEmpty }
    }

    public static func inspect(rawBody: Data, senderDomain: String) -> Report {
        let text = String(decoding: rawBody, as: UTF8.self)
        var warnings: [String] = []
        var hosts: [String] = []

        // href="..." with its anchor text, for text/href mismatch.
        for (href, anchor) in anchors(in: text) {
            guard let host = hostName(of: href) else { continue }
            hosts.append(host)
            if let shown = hostName(of: anchor), registrable(shown) != registrable(host) {
                warnings.append("a link's text shows \(shown) but goes to \(host)")
            }
        }
        // Bare URLs in plain text.
        for url in bareURLs(in: text) {
            if let host = hostName(of: url) { hosts.append(host) }
        }

        let unique = Array(Set(hosts)).sorted()
        let sender = registrable(senderDomain.lowercased())

        for host in unique {
            if host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) {
                warnings.append("a link uses lookalike (punycode) characters: \(host)")
            }
            if isIPAddress(host) {
                warnings.append("a link goes to a bare IP address: \(host)")
            }
        }

        // Every link off the sender's domain is a signal only when *none* match:
        // newsletters legitimately link out, but a bank that never links to itself is odd.
        if !unique.isEmpty, !sender.isEmpty, !unique.contains(where: { registrable($0) == sender }),
           looksLikeAccountMail(text) {
            warnings.append("asks you to act, but no link goes to \(senderDomain)")
        }

        return Report(warnings: Array(Set(warnings)).sorted(), linkHosts: unique)
    }

    // MARK: - Pieces

    static func anchors(in html: String) -> [(href: String, text: String)] {
        var out: [(String, String)] = []
        var remainder = Substring(html)
        while let open = remainder.range(of: "<a ", options: .caseInsensitive) {
            let tag = remainder[open.lowerBound...]
            guard let close = tag.firstIndex(of: ">") else { break }
            let attrs = tag[..<close]
            guard let hrefRange = attrs.range(of: "href=", options: .caseInsensitive) else { remainder = tag[close...]; continue }
            var value = attrs[hrefRange.upperBound...]
            let quote = value.first
            if quote == "\"" || quote == "'" {
                value = value.dropFirst()
                if let end = value.firstIndex(of: quote!) { value = value[..<end] }
            } else {
                value = value.prefix { !$0.isWhitespace }
            }
            let afterTag = tag[tag.index(after: close)...]
            let text = afterTag.range(of: "</a>", options: .caseInsensitive).map { String(afterTag[..<$0.lowerBound]) } ?? ""
            let plain = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            out.append((String(value), plain))
            remainder = afterTag
        }
        return out
    }

    static func bareURLs(in text: String) -> [String] {
        var out: [String] = []
        var remainder = Substring(text)
        while let range = remainder.range(of: #"https?://[^\s"'<>)]+"#, options: .regularExpression) {
            out.append(String(remainder[range]))
            remainder = remainder[range.upperBound...]
        }
        return out
    }

    static func hostName(of urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let host = url.host, url.scheme?.hasPrefix("http") == true {
            return host.lowercased()
        }
        // Anchor text like "paypal.com/secure" or "www.bank.com"
        let candidate = trimmed.split(whereSeparator: { "/ ?".contains($0) }).first.map(String.init) ?? ""
        let labels = candidate.split(separator: ".")
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }),
              let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        return candidate.lowercased()
    }

    /// `mail.google.com` → `google.com`; `bbc.co.uk` → `bbc.co.uk`.
    static func registrable(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host }
        let secondLevel = ["co", "com", "net", "org", "gov", "ac", "edu"]
        if labels.count >= 3, secondLevel.contains(labels[labels.count - 2]), labels.last!.count == 2 {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    static func isIPAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    static func looksLikeAccountMail(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["verify", "confirm", "suspended", "unusual sign", "reset your password", "update your payment", "your account", "click here", "log in", "sign in"]
            .contains { lower.contains($0) }
    }
}
