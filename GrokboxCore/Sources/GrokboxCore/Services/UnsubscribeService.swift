import Foundation
import Network
import Synchronization

/// RFC 8058 one-click unsubscribe.
///
/// **This is one of only two places Grokbox makes a network connection to
/// anything other than your mail server** (the other is Ollama on loopback).
/// It POSTs to a URL the *sender* put in their own message headers, and it
/// only does so when the user clicks Unsubscribe on that sender. The sender
/// already has your address; this tells them to stop using it.
public enum UnsubscribeService {
    public enum Outcome: Sendable, Equatable {
        /// The sender's server answered with a 2xx, either to the POST or, after
        /// one redirect, at the page it led to. That acknowledges the request;
        /// it does not prove their mail will stop.
        case accepted
        /// No one-click support; the user should open this URL themselves.
        case openInBrowser(URL)
        /// Only a mailto: option exists. Grokbox does not send mail.
        case requiresEmail(String)
        /// The request went out and the server answered without accepting it:
        /// an error status, or a redirect Grokbox would not follow.
        case notAccepted(status: Int, page: URL)
        /// Nothing was sent.
        case failed(String)
        /// The request went out but no answer came back, so it may or may not
        /// have arrived. It is not sent again here.
        case unknown(String)

        /// Where the user can finish by hand, when Grokbox did not.
        public var manualPage: URL? {
            switch self {
            case .openInBrowser(let url), .notAccepted(_, let url): url
            default: nil
            }
        }
    }

    public static func unsubscribe(from cluster: SenderCluster) async -> Outcome {
        if let refusal = refusalWhenDemoOnly() { return refusal }
        guard let url = cluster.unsubscribeURL else {
            if let mailto = cluster.unsubscribeValue?
                .split(separator: ",")
                .map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: " <>")) })
                .first(where: { $0.hasPrefix("mailto:") }) {
                return .requiresEmail(mailto)
            }
            return .failed("No unsubscribe link in this sender's headers.")
        }

        // A message-supplied URL is never POSTed to unless it is HTTPS to a
        // public host. Anything else is handed to the browser, where the
        // user can see where it goes before it goes there.
        guard PublicHostPolicy.check(url) == nil, cluster.supportsOneClickUnsubscribe else {
            return .openInBrowser(url)
        }
        return await performOneClick(to: url)
    }

    /// The POST itself. Body is the RFC 8058 constant and nothing else: no
    /// cookies, no identifiers beyond what the sender already put in the URL.
    /// The host is resolved once, every answer must be public, and the
    /// connection goes to a checked address while TLS still verifies the
    /// certificate against the link's host name. Redirects are followed at
    /// most once, under the same rule, and the whole exchange is bounded.
    ///
    /// - Parameter allowingLoopbackForTests: the policy refuses loopback, which
    ///   is where the test server lives. Tests set this; the app never does.
    ///   It admits loopback addresses, and plain HTTP to them, and nothing else.
    public static func performOneClick(to url: URL, allowingLoopbackForTests: Bool = false) async -> Outcome {
        await performOneClick(to: url, allowingLoopbackForTests: allowingLoopbackForTests,
                              resolver: .system, timeout: .seconds(15))
    }

    static func performOneClick(to url: URL, allowingLoopbackForTests: Bool,
                                resolver: HostResolver, timeout: Duration) async -> Outcome {
        if let refusal = refusalWhenDemoOnly() { return refusal }
        let deadline = ContinuousClock.now + timeout
        var target = url
        var method = "POST"
        var redirectedBy: Int?
        for _ in 0...PublicHostPolicy.maximumRedirects {
            switch await send(method, to: target, allowingLoopback: allowingLoopbackForTests,
                              resolver: resolver, until: deadline) {
            case .notSent(let why):
                return redirectedBy.map { .notAccepted(status: $0, page: url) } ?? .failed(why)
            case .noAnswer(let why):
                return .unknown(why)
            case .answered(let status, _) where (200..<300).contains(status):
                return .accepted
            case .answered(let status, let location?) where [301, 302, 303, 307, 308].contains(status):
                guard let next = URL(string: location, relativeTo: target)?.absoluteURL else {
                    return .notAccepted(status: status, page: url)
                }
                if status != 307 && status != 308 { method = "GET" }
                target = next
                redirectedBy = status
            case .answered(let status, _):
                return .notAccepted(status: status, page: url)
            }
        }
        return .notAccepted(status: redirectedBy ?? 0, page: url)
    }

    /// Demo-only mode sends nothing: no lookup, no connection, no request.
    private static func refusalWhenDemoOnly() -> Outcome? {
        do { try LaunchIsolation.refuse(.unsubscribe); return nil } catch {
            return .failed(error.localizedDescription + " Nothing was sent.")
        }
    }

    enum Exchange: Equatable {
        case notSent(String)
        case noAnswer(String)
        case answered(status: Int, location: String?)
    }

    private static func send(_ method: String, to url: URL, allowingLoopback: Bool,
                             resolver: HostResolver, until deadline: ContinuousClock.Instant) async -> Exchange {
        let destination: Destination
        switch await checkedDestination(for: url, allowingLoopback: allowingLoopback, resolver: resolver, until: deadline) {
        case .success(let resolved): destination = resolved
        case .failure(let refusal): return .notSent(refusal.reason)
        }
        let portNumber = url.port ?? (destination.tls ? 443 : 80)
        guard let request = requestBytes(method, for: url, host: destination.host),
              (1...65_535).contains(portNumber), let port = NWEndpoint.Port(rawValue: UInt16(portNumber)) else {
            return .notSent("The unsubscribe link is malformed. Nothing was sent.")
        }
        return await sendToFirstReachableAddress(request, port: port, of: destination, until: deadline)
    }

    private static func sendToFirstReachableAddress(_ request: Data, port: NWEndpoint.Port, of destination: Destination,
                                                    until deadline: ContinuousClock.Instant) async -> Exchange {
        var lastReason = "No answer in time. Nothing was sent."
        for address in destination.addresses {
            let remaining = deadline - .now
            guard remaining > .zero else { break }
            let parameters = destination.tls ? NWParameters(tls: tlsOptions(serverName: destination.host)) : NWParameters.tcp
            if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcp.connectionTimeout = 10
            }
            let connection = NWConnection(to: .hostPort(host: address, port: port), using: parameters)
            let result = await HTTPExchange(connection: connection, request: request).run(within: remaining)
            guard case .notSent(let why) = result else { return result }
            lastReason = why
        }
        return .notSent(lastReason)
    }

    struct Destination {
        let host: String
        let addresses: [NWEndpoint.Host]
        let tls: Bool
    }

    struct Refused: Error {
        let reason: String
    }

    static func checkedDestination(for url: URL, allowingLoopback: Bool, resolver: HostResolver,
                                   until deadline: ContinuousClock.Instant) async -> Result<Destination, Refused> {
        let cleartext = allowingLoopback && url.scheme?.lowercased() == "http"
        if let refusal = PublicHostPolicy.check(url),
           !(allowingLoopback && (refusal == .loopback || (refusal == .notHTTPS && cleartext))) {
            return .failure(Refused(reason: explain(refusal)))
        }
        guard let host = PublicHostPolicy.hostName(of: url) else { return .failure(Refused(reason: explain(.noHost))) }
        let addresses: [NWEndpoint.Host]
        if let literal = PublicHostPolicy.literal(host) {
            addresses = [literal]
        } else {
            do {
                addresses = try await lookup(host, with: resolver, until: deadline)
            } catch {
                return .failure(Refused(reason: "Couldn't look up \(host): \(error.localizedDescription). Nothing was sent."))
            }
        }
        guard !addresses.isEmpty else {
            return .failure(Refused(reason: "\(host) has no address. Nothing was sent."))
        }
        for address in addresses {
            switch PublicHostPolicy.check(address) {
            case nil where cleartext: return .failure(Refused(reason: explain(.notHTTPS)))
            case nil: continue
            case .loopback? where allowingLoopback: continue
            case let refusal?: return .failure(Refused(reason: explain(refusal)))
            }
        }
        return .success(Destination(host: host, addresses: addresses, tls: !cleartext))
    }

    private static func lookup(_ host: String, with resolver: HostResolver,
                               until deadline: ContinuousClock.Instant) async throws -> [NWEndpoint.Host] {
        // getaddrinfo cannot be cancelled, so the deadline abandons it instead.
        let remaining = deadline - .now
        return try await withCheckedThrowingContinuation { continuation in
            let latch = OneShotLatch()
            let work = Task {
                do {
                    let addresses = try await resolver.lookup(host)
                    if latch.claim() { continuation.resume(returning: addresses) }
                } catch {
                    if latch.claim() { continuation.resume(throwing: error) }
                }
            }
            let timer = Task {
                try? await Task.sleep(for: remaining)
                if latch.claim() {
                    work.cancel()
                    continuation.resume(throwing: HostResolver.Failure(reason: "no answer in time"))
                }
            }
            Task {
                _ = await work.result
                timer.cancel()
            }
        }
    }

    static func explain(_ refusal: PublicHostPolicy.Refusal) -> String {
        let what = switch refusal {
        case .notHTTPS: "is not HTTPS"
        case .noHost: "has no host"
        case .loopback: "points at this device, not the sender"
        case .privateNetwork: "points at a private network address, not the sender's public server"
        case .tooManyRedirects: "redirects too many times"
        }
        return "Refused: the unsubscribe link \(what). Nothing was sent."
    }

    /// The connection goes to an address, so the certificate is checked
    /// against the link's host name explicitly rather than against whatever
    /// the endpoint happens to be.
    static func tlsOptions(serverName host: String) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        if PublicHostPolicy.literal(host) == nil {
            sec_protocol_options_set_tls_server_name(security, host)
        }
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let serverTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(serverTrust, SecPolicyCreateSSL(true, host as CFString))
            complete(SecTrustEvaluateWithError(serverTrust, nil))
        }, DispatchQueue.global(qos: .userInitiated))
        return options
    }

    static func requestBytes(_ method: String, for url: URL, host: String) -> Data? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        let target = path + (parts.percentEncodedQuery.map { "?\($0)" } ?? "")
        let authority = (host.contains(":") ? "[\(host)]" : host) + (url.port.map { ":\($0)" } ?? "")
        let unsafe = (target + authority).unicodeScalars.contains { $0.value <= 0x20 || $0.value >= 0x7f }
        guard !unsafe else { return nil }
        var head = "\(method) \(target) HTTP/1.1\r\nHost: \(authority)\r\nUser-Agent: Grokbox\r\nConnection: close\r\n"
        var body = ""
        if method == "POST" {
            body = "List-Unsubscribe=One-Click"
            head += "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: \(body.utf8.count)\r\n"
        }
        return Data((head + "\r\n" + body).utf8)
    }

    static let unreadableReply = "The server's reply could not be read, so the request may or may not have been accepted."

    static func parseHead(_ buffer: Data) -> Exchange? {
        var rest = Substring(decoding: buffer, as: UTF8.self)
        while let end = [rest.range(of: "\r\n\r\n"), rest.range(of: "\n\n")].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) {
            let lines = rest[..<end.lowerBound].split(whereSeparator: \.isNewline)
            let statusLine = lines.first?.split(separator: " ", maxSplits: 2) ?? []
            guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]) else {
                return .noAnswer(unreadableReply)
            }
            if (100..<200).contains(status) && status != 101 {
                rest = rest[end.upperBound...]
                continue
            }
            let location = lines.dropFirst().first { $0.lowercased().hasPrefix("location:") }
                .map { $0.dropFirst("location:".count).trimmingCharacters(in: .whitespaces) }
            return .answered(status: status, location: location)
        }
        return nil
    }
}

private final class HTTPExchange: Sendable {
    private struct State {
        var requestHandedToNetwork = false
        var buffer = Data()
        var continuation: CheckedContinuation<UnsubscribeService.Exchange, Never>?
    }

    private static let maximumHeadBytes = 16_384
    private let connection: NWConnection
    private let request: Data
    private let queue = DispatchQueue(label: "grokbox.unsubscribe")
    private let state = Mutex(State())

    init(connection: NWConnection, request: Data) {
        self.connection = connection
        self.request = request
    }

    func run(within limit: Duration) async -> UnsubscribeService.Exchange {
        await withCheckedContinuation { continuation in
            state.withLock { $0.continuation = continuation }
            connection.stateUpdateHandler = { [self] update in
                switch update {
                case .ready: sendRequest()
                case .waiting(let error), .failed(let error): fail(error.localizedDescription)
                default: break
                }
            }
            let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
            queue.asyncAfter(deadline: .now() + seconds) { [self] in fail("No answer in time.") }
            connection.start(queue: queue)
        }
    }

    private func sendRequest() {
        state.withLock { $0.requestHandedToNetwork = true }
        connection.send(content: request, completion: .contentProcessed { [self] error in
            if let error { fail(error.localizedDescription) }
        })
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumHeadBytes) { [self] data, _, isComplete, error in
            let buffer = state.withLock { state in
                if let data { state.buffer.append(data) }
                return state.buffer
            }
            if let head = UnsubscribeService.parseHead(buffer) { return finish(head) }
            if buffer.count >= Self.maximumHeadBytes {
                return finish(.noAnswer(UnsubscribeService.unreadableReply))
            }
            if let error { return fail(error.localizedDescription) }
            if isComplete { return fail("The server closed the connection without answering.") }
            receive()
        }
    }

    private func fail(_ reason: String) {
        let mayHaveArrived = state.withLock { $0.requestHandedToNetwork }
        finish(mayHaveArrived
               ? .noAnswer("\(reason) The request was sent, so it may or may not have arrived.")
               : .notSent("Couldn't reach the sender's server: \(reason) Nothing was sent."))
    }

    private func finish(_ result: UnsubscribeService.Exchange) {
        let continuation = state.withLock { state in
            defer { state.continuation = nil }
            return state.continuation
        }
        guard let continuation else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: result)
    }
}
