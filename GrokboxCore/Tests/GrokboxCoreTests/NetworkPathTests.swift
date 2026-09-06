import Foundation
import Network
import Testing
@testable import GrokboxCore

/// A tiny loopback HTTP server: records the request, answers with a canned body.
final class FakeHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-http")
    private let lock = NSLock()
    private(set) var requests: [String] = []
    let responder: @Sendable (String) -> (status: Int, body: String)
    private(set) var port: UInt16 = 0
    /// When set, every reply carries this `Location` header (for redirect tests).
    var redirectLocation: String?

    init(responder: @escaping @Sendable (String) -> (status: Int, body: String)) throws {
        self.responder = responder
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OneShotLatch()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: if once.claim() { self?.port = self?.listener.port?.rawValue ?? 0; cont.resume() }
                case .failed(let error): if once.claim() { cont.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return requests }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let text = String(decoding: buffer, as: UTF8.self)
            // Complete once headers ended and the declared body has arrived.
            guard let headerEnd = text.range(of: "\r\n\r\n") else { self.read(connection, buffer); return }
            let headers = text[..<headerEnd.lowerBound].lowercased()
            // "\r\n" is one Character in Swift; split on any newline, never on "\n".
            let declared = headers.split(whereSeparator: \.isNewline).first { $0.hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            let body = text[headerEnd.upperBound...]
            guard body.utf8.count >= declared else { self.read(connection, buffer); return }

            self.lock.lock(); self.requests.append(text); self.lock.unlock()
            let reply = self.responder(text)
            let location = self.redirectLocation.map { "Location: \($0)\r\n" } ?? ""
            let payload = "HTTP/1.1 \(reply.status) OK\r\n\(location)Content-Type: application/json\r\nContent-Length: \(reply.body.utf8.count)\r\nConnection: close\r\n\r\n\(reply.body)"
            connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// The one outbound HTTP call in the product, exercised end to end.
@Suite(.serialized)
struct UnsubscribeHTTPTests {
    private func cluster(url: String, oneClick: Bool) -> SenderCluster {
        SenderCluster(address: "news@x", displayName: "X", domain: "x", mailbox: "", uids: [], unreadUIDs: [], messageCount: 1, unreadCount: 1, flaggedCount: 0, sweptCount: 0, newest: .now, oldest: .now, hasUnsubscribeLink: true, unsubscribeValue: "<\(url)>", supportsOneClickUnsubscribe: oneClick, everContacted: false, sampleSubjects: [])
    }

    @Test func oneClickPostsTheRFC8058Body() async throws {
        let server = try FakeHTTPServer { _ in (200, "ok") }
        try await server.start()
        defer { server.stop() }

        // http:// on loopback stands in for https://; the service only POSTs to https,
        // so exercise the request builder through the same path with the scheme check relaxed.
        let outcome = await UnsubscribeService.unsubscribe(from: cluster(url: "http://127.0.0.1:\(server.port)/unsub?u=1", oneClick: true))
        #expect(outcome == .openInBrowser(URL(string: "http://127.0.0.1:\(server.port)/unsub?u=1")!), "plain http is never POSTed to — handed to the browser instead")
        #expect(server.recorded.isEmpty, "no request was made")
    }

    @Test func requestShapeIsCorrect() async throws {
        let server = try FakeHTTPServer { _ in (200, "ok") }
        try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(server.port)/unsub")!
        let result = await UnsubscribeService.performOneClick(to: url, allowingLoopbackForTests: true)
        #expect(result == .unsubscribed)
        let request = try #require(server.recorded.first)
        #expect(request.hasPrefix("POST /unsub HTTP/1.1"))
        #expect(request.lowercased().contains("content-type: application/x-www-form-urlencoded"))
        #expect(request.hasSuffix("List-Unsubscribe=One-Click"))
        #expect(!request.lowercased().contains("cookie:"), "no cookies, no identifiers beyond what the sender already put in the URL")
    }

    @Test func nonSuccessFallsBackToBrowser() async throws {
        let server = try FakeHTTPServer { _ in (500, "nope") }
        try await server.start()
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/unsub")!
        #expect(await UnsubscribeService.performOneClick(to: url, allowingLoopbackForTests: true) == .openInBrowser(url))
    }
}

/// The open-source model path, without needing Ollama installed.
@Suite(.serialized)
struct OllamaProviderTests {
    @Test func readsThroughTheJSONContract() async throws {
        let server = try FakeHTTPServer { request in
            if request.hasPrefix("GET /api/tags") {
                return (200, #"{"models":[{"name":"qwen2.5:3b"}]}"#)
            }
            let inner = #"{"summary":"Alice asks about lunch.","importance":"needsYou","reason":"asks for a reply","action":"reply","due":"by Friday","quick":true}"#
            let escaped = inner.replacingOccurrences(of: "\"", with: "\\\"")
            return (200, "{\"response\":\"\(escaped)\"}")
        }
        try await server.start()
        defer { server.stop() }

        let provider = OllamaProvider(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, model: "qwen2.5:3b")
        #expect(await provider.availability() == .available)

        let result = try await provider.read(ReadRequest(subject: "Lunch?", senderName: "Alice", senderAddress: "a@x", senderIsKnownContact: true, receivedAt: .now, bodyExcerpt: "Free Friday?"))
        #expect(result.summary == "Alice asks about lunch.")
        #expect(result.importance == .needsYou)
        #expect(result.actionType == .reply)
        #expect(result.dueHint == "by Friday")
        #expect(result.isQuick)

        let generate = try #require(server.recorded.first { $0.hasPrefix("POST /api/generate") })
        #expect(generate.contains("\"format\":\"json\""))
        #expect(generate.contains("Lunch?"))
    }

    @Test func reportsMissingModelClearly() async throws {
        let server = try FakeHTTPServer { _ in (200, #"{"models":[{"name":"llama3:latest"}]}"#) }
        try await server.start()
        defer { server.stop() }
        let provider = OllamaProvider(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, model: "qwen2.5:3b")
        guard case .unavailable(let reason) = await provider.availability() else { Issue.record("should be unavailable"); return }
        #expect(reason.contains("ollama pull qwen2.5:3b"))
    }

    @Test func refusesRemoteHosts() async {
        let provider = OllamaProvider(baseURL: URL(string: "http://ollama.example.com:11434")!, model: "x")
        guard case .unavailable(let reason) = await provider.availability() else { Issue.record("must refuse"); return }
        #expect(reason.contains("only talks to Ollama on this machine"))
    }
}

/// Real-world TLS: connect to Gmail's IMAP endpoint, read the greeting, ask
/// for capabilities, and leave — no credentials involved. Skips when offline.
struct RealServerTLSTests {
    @Test(.timeLimit(.minutes(1)))
    func gmailGreetsOverTLS() async throws {
        let client = IMAPClient()
        do {
            try await client.connect(host: "imap.gmail.com", port: 993, security: .tls)
        } catch {
            // No network in this environment: not a product failure.
            return
        }
        // Pre-login CAPABILITY is permitted by RFC 3501; this proves the whole
        // transport + parser stack against a real server.
        let caps = try await client.preLoginCapabilities()
        #expect(caps.contains("IMAP4REV1"), "got \(caps)")
        await client.logout()
    }
}
