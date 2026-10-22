import Foundation
import Network
import Synchronization
import Testing
@testable import GrokboxCore

@Suite(.serialized)
struct UnsubscribeDestinationTests {
    private func resolver(_ answers: [String: [String]]) -> HostResolver {
        HostResolver { host in (answers[host] ?? []).compactMap(PublicHostPolicy.literal) }
    }

    private func perform(_ url: String, loopback: Bool = false, resolver: HostResolver = .system,
                         timeout: Duration = .seconds(5)) async throws -> UnsubscribeService.Outcome {
        await UnsubscribeService.performOneClick(to: try #require(URL(string: url)), allowingLoopbackForTests: loopback,
                                                 resolver: resolver, timeout: timeout)
    }

    @Test func disguisedLoopbackHostsAreNeverContacted() async throws {
        let server = try FakeHTTPServer { _ in (200, "ok") }
        try await server.start(); defer { server.stop() }
        for host in ["localhost.", "2130706433", "127.1", "0x7f.0.0.1"] {
            let url = try #require(URL(string: "https://\(host):\(server.port)/unsub"))
            let outcome = await UnsubscribeService.performOneClick(to: url)
            #expect(outcome == .failed(UnsubscribeService.explain(.loopback)), Comment(rawValue: host))
        }
        #expect(server.connections == 0, "a loopback listener was reached through a public-looking host")
    }

    @Test func aPrivateDNSAnswerIsRefusedBeforeConnecting() async throws {
        let server = try FakeHTTPServer { _ in (200, "ok") }
        try await server.start(); defer { server.stop() }
        let hostile = resolver(["news.example": ["127.0.0.1"], "lan.example": ["0.0.0.0"]])
        let loop = try await perform("https://news.example:\(server.port)/u", resolver: hostile)
        #expect(loop == .failed(UnsubscribeService.explain(.loopback)))
        let lan = try await perform("http://lan.example:\(server.port)/u", loopback: true, resolver: hostile)
        #expect(lan == .failed(UnsubscribeService.explain(.privateNetwork)), "the loopback hook does not excuse other private addresses")
        #expect(server.connections == 0)
    }

    @Test func oneHostileAnswerAmongGoodOnesIsRefused() async throws {
        let server = try FakeHTTPServer { _ in (200, "ok") }
        try await server.start(); defer { server.stop() }
        let mixed = resolver(["mixed.example": ["127.0.0.1", "0.0.0.0"]])
        let outcome = try await perform("http://mixed.example:\(server.port)/u", loopback: true, resolver: mixed)
        #expect(outcome == .failed(UnsubscribeService.explain(.privateNetwork)))
        #expect(server.connections == 0)
    }

    @Test func theCheckedAnswerIsTheOneConnectedTo() async throws {
        let server = try FakeHTTPServer { _ in (200, "ok") }
        try await server.start(); defer { server.stop() }
        let lookups = Mutex(0)
        let rebinding = HostResolver { _ in
            let n = lookups.withLock { $0 += 1; return $0 }
            return [PublicHostPolicy.literal(n == 1 ? "127.0.0.1" : "0.0.0.0")].compactMap { $0 }
        }
        let outcome = try await perform("http://rebind.example:\(server.port)/u", loopback: true, resolver: rebinding)
        #expect(outcome == .accepted)
        #expect(lookups.withLock { $0 } == 1)
        let request = try #require(server.recorded.first)
        #expect(request.contains("Host: rebind.example:\(server.port)\r\n"), "the Host header names the link's host, not the address")
    }

    @Test func aRedirectIsResolvedAndCheckedBeforeItIsFollowed() async throws {
        let trap = try FakeHTTPServer { _ in (200, "never") }
        try await trap.start(); defer { trap.stop() }
        let first = try FakeHTTPServer { _ in (302, "") }
        try await first.start(); defer { first.stop() }
        first.redirectLocation = "http://inner.example:\(trap.port)/x"
        let outcome = try await perform("http://127.0.0.1:\(first.port)/u", loopback: true,
                                        resolver: resolver(["inner.example": ["0.0.0.0"]]))
        #expect(outcome == .notAccepted(status: 302, page: URL(string: "http://127.0.0.1:\(first.port)/u")!))
        #expect(trap.connections == 0)
    }

    @Test func aSafeRedirectIsFollowedOnceWithoutTheBody() async throws {
        let landing = try FakeHTTPServer { _ in (200, "you're unsubscribed") }
        try await landing.start(); defer { landing.stop() }
        let first = try FakeHTTPServer { _ in (303, "") }
        try await first.start(); defer { first.stop() }
        first.redirectLocation = "http://127.0.0.1:\(landing.port)/done"
        let outcome = try await perform("http://127.0.0.1:\(first.port)/u", loopback: true)
        #expect(outcome == .accepted)
        let followed = try #require(landing.recorded.first)
        #expect(followed.hasPrefix("GET /done HTTP/1.1"))
        #expect(!followed.contains("List-Unsubscribe=One-Click"))
    }

    @Test func aSecondRedirectIsNotFollowed() async throws {
        let first = try FakeHTTPServer { _ in (307, "") }
        try await first.start(); defer { first.stop() }
        first.redirectLocation = "/again"
        let url = "http://127.0.0.1:\(first.port)/u"
        let outcome = try await perform(url, loopback: true)
        #expect(outcome == .notAccepted(status: 307, page: URL(string: url)!))
        #expect(first.recorded.count == 2, "the original and one redirect, then stop")
        #expect(first.recorded.last?.hasPrefix("POST /again HTTP/1.1") == true, "307 keeps the method and body")
    }

    @Test func theTestHookNeverAllowsCleartextToAPublicAddress() async throws {
        let outcome = try await perform("http://public.example/u", loopback: true,
                                        resolver: resolver(["public.example": ["8.8.8.8"]]))
        #expect(outcome == .failed(UnsubscribeService.explain(.notHTTPS)))
    }

    @Test func statusesOtherThan2xxAreNotAcceptance() async throws {
        for (status, expected) in [(204, true), (202, true), (404, false), (302, false), (500, false)] {
            let server = try FakeHTTPServer { _ in (status, "") }
            try await server.start(); defer { server.stop() }
            let url = "http://127.0.0.1:\(server.port)/u"
            let outcome = try await perform(url, loopback: true)
            #expect(outcome == (expected ? .accepted : .notAccepted(status: status, page: URL(string: url)!)), "HTTP \(status)")
        }
    }

    @Test func noAnswerAfterSendingIsUnknownAndNotRetried() async throws {
        let silent = try FakeHTTPServer { _ in (200, "") }
        silent.withholdsReply = true
        try await silent.start(); defer { silent.stop() }
        let outcome = try await perform("http://127.0.0.1:\(silent.port)/u", loopback: true, timeout: .milliseconds(700))
        guard case .unknown = outcome else { Issue.record("\(outcome)"); return }
        #expect(silent.recorded.count == 1)

        let hangUp = try FakeHTTPServer { _ in (200, "") }
        hangUp.hangsUp = true
        try await hangUp.start(); defer { hangUp.stop() }
        let dropped = try await perform("http://127.0.0.1:\(hangUp.port)/u", loopback: true)
        guard case .unknown = dropped else { Issue.record("\(dropped)"); return }
        #expect(hangUp.recorded.count == 1, "sent once, never resent")
    }

    @Test func aRefusedConnectionSentNothing() async throws {
        let gone = try FakeHTTPServer { _ in (200, "") }
        try await gone.start()
        let port = gone.port
        gone.stop()
        let outcome = try await perform("http://127.0.0.1:\(port)/u", loopback: true)
        guard case .failed(let why) = outcome else { Issue.record("\(outcome)"); return }
        #expect(why.hasSuffix("Nothing was sent."))
    }

    @Test func addressRuleAcceptsOnlyPublicUnicast() {
        func refusal(_ s: String) -> PublicHostPolicy.Refusal? { PublicHostPolicy.check(PublicHostPolicy.literal(s)!) }
        for allowed in ["8.8.8.8", "172.32.0.1", "2606:4700::1111", "64:ff9b::808:808", "2002:808:808::1", "3fff:1000::1"] {
            #expect(refusal(allowed) == nil, Comment(rawValue: allowed))
        }
        for loop in ["127.0.0.1", "::1", "::ffff:7f00:1"] {
            #expect(refusal(loop) == .loopback, Comment(rawValue: loop))
        }
        for blocked in ["0.0.0.0", "10.1.2.3", "100.64.0.1", "169.254.169.254", "192.168.0.1", "198.18.0.1", "224.0.0.1",
                        "255.255.255.255", "::", "fe80::1", "fc00::1", "fec0::1", "ff02::1", "2001:db8::1", "2001::1",
                        "2001:2::1", "2001:10::1", "2001:20::1", "3fff::1",
                        "64:ff9b::a00:1", "2002:a00:1::1", "::ffff:192.168.1.1"] {
            #expect(refusal(blocked) == .privateNetwork, Comment(rawValue: blocked))
        }
    }

    @Test func internationalHostsGoOutAsPunycode() throws {
        let url = try #require(URL(string: "https://münchen.example/u"))
        let host = try #require(PublicHostPolicy.hostName(of: url))
        let request = try #require(UnsubscribeService.requestBytes("POST", for: url, host: host))
        #expect(String(decoding: request, as: UTF8.self).contains("Host: xn--mnchen-3ya.example\r\n"))
    }

    @Test func replyHeadsAreReadWithoutTheBody() {
        func head(_ s: String) -> UnsubscribeService.Exchange? { UnsubscribeService.parseHead(Data(s.utf8)) }
        #expect(head("HTTP/1.1 200 OK\r\nContent-Length: 5") == nil, "headers not finished yet")
        #expect(head("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n") == .answered(status: 204, location: nil))
        #expect(head("HTTP/1.1 302 Found\r\nLOCATION:  https://x.example/a \r\n\r\nbody") == .answered(status: 302, location: "https://x.example/a"))
        #expect(head("HTTP/1.1 200 OK\nContent-Length: 0\n\n") == .answered(status: 200, location: nil), "bare LF line endings")
        guard case .noAnswer = head("SSH-2.0-OpenSSH\r\n\r\n") else { Issue.record("garbage read as an answer"); return }
    }
}

struct UnsubscribeTLSTrustTests {
    private func handshake(_ address: NWEndpoint.Host, serverName: String) async -> Bool {
        let connection = NWConnection(to: .hostPort(host: address, port: 993),
                                      using: NWParameters(tls: UnsubscribeService.tlsOptions(serverName: serverName)))
        let latch = OneShotLatch()
        return await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if latch.claim() { connection.cancel(); continuation.resume(returning: true) }
                case .failed, .waiting: if latch.claim() { connection.cancel(); continuation.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: .global())
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func pinnedAddressStillVerifiesTheHostName() async throws {
        guard let address = try? await HostResolver.system.lookup("imap.gmail.com").first(where: { PublicHostPolicy.check($0) == nil }),
              await handshake(address, serverName: "imap.gmail.com") else {
            try Test.cancel("Offline: no TLS server to check the host name against.")
        }
        #expect(await handshake(address, serverName: "unsubscribe.example.com") == false,
                "a certificate for another name must not be trusted")
    }
}
