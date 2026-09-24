import Foundation

/// The checks a careful mail client makes before it lets you click.
///
/// Grokbox never renders HTML, so tracking pixels and scripts cannot run.
/// What it *can* do, on the body the reader fetches, is notice the classic
/// phishing tells and say so above the message. The checks follow
/// Thunderbird's phishing detector (`PhishingDetector.sys.mjs`): link text
/// that names one site but goes to another, hosts written as IP addresses in
/// any of their disguises, and forms that post what you type somewhere.
public enum LinkHygiene {
    public struct Report: Sendable, Equatable {
        public var warnings: [String]
        public var linkHosts: [String]
        public var isSuspicious: Bool { !warnings.isEmpty }
    }

    /// Inspects a MIME entity (or a bare body), decoded first so links inside
    /// quoted-printable or base64 parts are seen.
    public static func inspect(rawBody: Data, senderDomain: String) -> Report {
        inspect(BodyExtractor.extract(from: rawBody), senderDomain: senderDomain)
    }

    public static func inspect(_ body: BodyExtractor.Extracted, senderDomain: String) -> Report {
        // The HTML part carries anchors; the plain part only bare URLs.
        let text = body.html ?? body.plain ?? ""
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

        for action in formActions(in: text) {
            if let host = hostName(of: action) {
                warnings.append("contains a form that sends what you type to \(host)")
            } else {
                warnings.append("contains a form asking you to type something in")
            }
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
        let secondLevel = ["co", "com", "net", "org", "gov", "ac", "edu", "ne", "or", "go", "gob", "mil", "nic", "ltd", "plc"]
        if labels.count >= 3, secondLevel.contains(labels[labels.count - 2]), labels.last!.count == 2 {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// Dotted-quad, but also the disguises browsers still accept: one big
    /// decimal (`3232235777`), hex (`0xC0A80001`, `0xC0.0xA8.0.1`), octal
    /// (`0300.0250.0.1`), and IPv6 literals.
    static func isIPAddress(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.contains(":") { return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return false }
        return parts.allSatisfy { numericComponent($0) != nil }
    }

    private static func numericComponent(_ part: Substring) -> UInt64? {
        let lower = part.lowercased()
        if lower.hasPrefix("0x") { return lower.count > 2 ? UInt64(lower.dropFirst(2), radix: 16) : nil }
        if lower.count > 1, lower.hasPrefix("0") { return UInt64(lower.dropFirst(), radix: 8) }
        return UInt64(lower)
    }

    /// The `action` of every `<form>`. A form in mail has no honest use.
    static func formActions(in html: String) -> [String] {
        var out: [String] = []
        var remainder = Substring(html)
        while let open = remainder.range(of: "<form", options: .caseInsensitive) {
            let tag = remainder[open.upperBound...]
            let close = tag.firstIndex(of: ">") ?? tag.endIndex
            let attrs = tag[..<close]
            if let actionRange = attrs.range(of: "action=", options: .caseInsensitive) {
                var value = attrs[actionRange.upperBound...]
                if let quote = value.first, quote == "\"" || quote == "'" {
                    value = value.dropFirst()
                    value = value.prefix { $0 != quote }
                } else {
                    value = value.prefix { !$0.isWhitespace }
                }
                out.append(String(value))
            } else {
                out.append("")
            }
            remainder = tag[close...]
        }
        return out
    }

    static func looksLikeAccountMail(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["verify", "confirm", "suspended", "unusual sign", "reset your password", "update your payment", "your account", "click here", "log in", "sign in"]
            .contains { lower.contains($0) }
    }
}
