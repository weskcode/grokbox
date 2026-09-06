import Foundation

/// Decides whether an outbound request a *message* asked for may be sent.
///
/// The only such request Grokbox makes is the RFC 8058 unsubscribe POST, to a
/// URL taken from a sender's own headers. A hostile header could point that
/// request at the local network — a router's admin page, a printer, a NAS on
/// the LAN — and a redirect could do the same after a harmless first hop.
/// This policy refuses both: the destination must be HTTPS to a public host,
/// and at most one redirect is followed, checked by the same rule.
public enum PublicHostPolicy {
    public enum Refusal: Sendable, Equatable {
        case notHTTPS
        case noHost
        case loopback
        case privateNetwork
        case tooManyRedirects
    }

    public static let maximumRedirects = 1

    public static func check(_ url: URL) -> Refusal? {
        guard url.scheme?.lowercased() == "https" else { return .notHTTPS }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return .noHost }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return .loopback }
        if let refusal = checkLiteral(host) { return refusal }
        return nil
    }

    /// IP-literal hosts that must never be reached from a message-supplied URL.
    static func checkLiteral(_ host: String) -> Refusal? {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let v4 = ipv4(bare) {
            switch v4 {
            case (127, _, _, _): return .loopback
            case (10, _, _, _), (172, 16...31, _, _), (192, 168, _, _): return .privateNetwork
            case (169, 254, _, _): return .privateNetwork          // link-local, incl. cloud metadata
            case (100, 64...127, _, _): return .privateNetwork     // CGNAT
            case (0, _, _, _): return .privateNetwork
            default: return nil
            }
        }
        if bare.contains(":") {                                       // IPv6 literal
            let lower = bare.lowercased()
            if lower == "::1" || lower == "::" { return .loopback }
            if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return .privateNetwork }   // ULA
            if lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb") {
                return .privateNetwork                                // link-local
            }
            if lower.hasPrefix("::ffff:"), let v4 = ipv4(String(lower.dropFirst(7))) {
                return checkLiteral("\(v4.0).\(v4.1).\(v4.2).\(v4.3)")
            }
        }
        return nil
    }

    private static func ipv4(_ s: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return (octets[0], octets[1], octets[2], octets[3])
    }
}

/// Applies `PublicHostPolicy` to every redirect a task is offered. Refused
/// redirects are simply not followed; the original response is returned and
/// the caller sees the 3xx.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let hops = Counter()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard hops.increment() <= PublicHostPolicy.maximumRedirects else { return nil }
        guard let url = request.url, PublicHostPolicy.check(url) == nil else { return nil }
        var next = request
        next.httpShouldHandleCookies = false
        return next
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }
}
