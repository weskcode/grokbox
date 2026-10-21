import Foundation
import Testing
@testable import GrokboxCore

@Suite(.serialized)
struct UnsubscribeDestinationTests {
    @Test func disguisedLoopbackHostsAreNeverContacted() async throws {
        let server = try FakeHTTPServer { _ in (200, "ok") }
        try await server.start(); defer { server.stop() }
        for host in ["localhost.", "2130706433", "127.1", "0x7f.0.0.1"] {
            let url = try #require(URL(string: "https://\(host):\(server.port)/unsub"))
            let outcome = await UnsubscribeService.performOneClick(to: url)
            guard case .failed = outcome else { Issue.record("\(host): \(outcome)"); continue }
        }
        #expect(server.connections == 0, "a loopback listener was reached through a public-looking host")
    }
}
