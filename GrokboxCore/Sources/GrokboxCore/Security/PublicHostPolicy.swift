import Foundation
import Network

/// Decides whether an outbound request a *message* asked for may be sent.
///
/// The only such request Grokbox makes is the RFC 8058 unsubscribe POST, to a
/// URL taken from a sender's own headers. A hostile header could point that
/// request at the local network — a router's admin page, a printer, a NAS on
/// the LAN — directly, through a host name whose DNS answer is private, or
/// through a redirect after a harmless first hop. `check(_:)` settles what the
/// URL alone can: HTTPS, and no local or private literal. `UnsubscribeService`
/// then holds every address the name resolves to to the same address rule,
/// connects only to one of those checked addresses, and follows at most one
/// redirect under all of it again.
public enum PublicHostPolicy {
    public enum Refusal: Sendable, Equatable {
        case notHTTPS
        case noHost
        case loopback
        case privateNetwork
        case tooManyRedirects
    }

    public static let maximumRedirects = 1

    /// What the URL alone settles. A name that passes still has to resolve
    /// to public addresses before anything is sent.
    public static func check(_ url: URL) -> Refusal? {
        guard url.scheme?.lowercased() == "https" else { return .notHTTPS }
        guard let host = hostName(of: url) else { return .noHost }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return .loopback }
        if let address = literal(host) { return check(address) }
        return nil
    }

    static func check(_ address: NWEndpoint.Host) -> Refusal? {
        switch address {
        case .ipv4(let v4): checkIPv4(Array(v4.rawValue))
        case .ipv6(let v6): checkIPv6(Array(v6.rawValue))
        default: .noHost
        }
    }

    static func hostName(of url: URL) -> String? {
        guard var host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    static func literal(_ host: String) -> NWEndpoint.Host? {
        if let v4 = IPv4Address(host) { return .ipv4(v4) }
        if let v6 = IPv6Address(host) { return .ipv6(v6) }
        return nil
    }

    private static func checkIPv4(_ b: [UInt8]) -> Refusal? {
        guard b.count == 4 else { return .noHost }
        switch (b[0], b[1], b[2]) {
        case (127, _, _): return .loopback
        case (0, _, _), (10, _, _), (192, 168, _): return .privateNetwork
        case (172, 16...31, _): return .privateNetwork
        case (169, 254, _): return .privateNetwork
        case (100, 64...127, _): return .privateNetwork
        case (198, 18...19, _): return .privateNetwork
        case (192, 0, 0), (192, 0, 2), (198, 51, 100), (203, 0, 113): return .privateNetwork
        case (224...255, _, _): return .privateNetwork
        default: return nil
        }
    }

    /// Only global unicast (2000::/3) is public, apart from the ranges that
    /// carry an IPv4 address, which are judged by that address. NAT64 has to
    /// pass: on an IPv6-only network it is how every IPv4 site is reached.
    private static func checkIPv6(_ b: [UInt8]) -> Refusal? {
        guard b.count == 16 else { return .noHost }
        if b == ipv6Loopback { return .loopback }
        if let v4 = embeddedIPv4(b) { return checkIPv4(v4) }
        guard b[0] & 0xe0 == 0x20 else { return .privateNetwork }
        let isIETFProtocolAssignment = b[0] == 0x20 && b[1] == 0x01 && b[2] & 0xfe == 0
        let isDocumentation = Array(b[0..<4]) == documentationPrefix || (b[0] == 0x3f && b[1] == 0xff && b[2] & 0xf0 == 0)
        return isIETFProtocolAssignment || isDocumentation ? .privateNetwork : nil
    }

    private static let ipv6Loopback = [UInt8](repeating: 0, count: 15) + [1]
    private static let ipv4MappedPrefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff]
    private static let nat64Prefix: [UInt8] = [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]
    private static let sixToFourPrefix: [UInt8] = [0x20, 0x02]
    private static let documentationPrefix: [UInt8] = [0x20, 0x01, 0x0d, 0xb8]

    private static func embeddedIPv4(_ b: [UInt8]) -> [UInt8]? {
        let first12 = Array(b[0..<12])
        if first12 == ipv4MappedPrefix || first12 == nat64Prefix { return Array(b[12..<16]) }
        if Array(b[0..<2]) == sixToFourPrefix { return Array(b[2..<6]) }
        return nil
    }
}

struct HostResolver: Sendable {
    let lookup: @Sendable (String) async throws -> [NWEndpoint.Host]

    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static let system = HostResolver { host in
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                hints.ai_flags = AI_ADDRCONFIG
                var list: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &list)
                guard status == 0, let list else {
                    continuation.resume(throwing: Failure(reason: String(cString: gai_strerror(status))))
                    return
                }
                defer { freeaddrinfo(list) }
                var addresses: [NWEndpoint.Host] = []
                for entry in sequence(first: list, next: { $0.pointee.ai_next }) {
                    guard let raw = entry.pointee.ai_addr else { continue }
                    switch entry.pointee.ai_family {
                    case AF_INET:
                        var a = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                        if let v4 = IPv4Address(Data(bytes: &a, count: 4)) { addresses.append(.ipv4(v4)) }
                    case AF_INET6:
                        var a = raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                        if let v6 = IPv6Address(Data(bytes: &a, count: 16)) { addresses.append(.ipv6(v6)) }
                    default:
                        continue
                    }
                }
                continuation.resume(returning: addresses)
            }
        }
    }
}
