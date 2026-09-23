import Foundation
import Testing
@testable import GrokboxCore

/// The one outbound HTTP call this opt-in feature makes, exercised end to
/// end against a loopback fake — same pattern as `OllamaProviderTests`.
@Suite(.serialized)
struct JevCategorizerTests {
    private func request(hasUnsubscribeLink: Bool = true) -> CategorizeRequest {
        CategorizeRequest(displayName: "Weekly Deals", address: "deals@shop.example",
                          sampleSubjects: ["50% off everything", "Flash sale ends tonight"],
                          messageCount: 40, unreadRatio: 0.9, hasUnsubscribeLink: hasUnsubscribeLink)
    }

    @Test func sendsBearerAuthAndNoBodyContent() async throws {
        let server = try FakeHTTPServer { _ in
            (200, #"{"model":"jev-1.13.0","answers":{"category":{"type":"choice","choice":"promotion","probabilities":{"promotion":0.92},"confidence":0.92}}}"#)
        }
        try await server.start()
        defer { server.stop() }

        let categorizer = JevCategorizer(apiKey: "test-key", baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let result = try await categorizer.categorize(request())
        #expect(result.category == .promotion)
        #expect(result.reason.hasPrefix("Jev:"))

        let sent = try #require(server.recorded.first)
        #expect(sent.hasPrefix("POST"))
        #expect(sent.lowercased().contains("authorization: bearer test-key"))
        #expect(sent.contains("deals@shop.example"))
        #expect(!sent.contains("bodyExcerpt"), "never sends a message body — there is none in CategorizeRequest")
    }

    @Test func lowConfidenceIsTreatedAsUnknown() async throws {
        let server = try FakeHTTPServer { _ in
            (200, #"{"model":"jev-1.13.0","answers":{"category":{"type":"choice","choice":"newsletter","probabilities":{"newsletter":0.4},"confidence":0.4}}}"#)
        }
        try await server.start()
        defer { server.stop() }

        let categorizer = JevCategorizer(apiKey: "test-key", baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let result = try await categorizer.categorize(request())
        #expect(result.category == .unknown)
    }

    @Test func explicitUnknownChoiceIsHonoured() async throws {
        let server = try FakeHTTPServer { _ in
            (200, #"{"model":"jev-1.13.0","answers":{"category":{"type":"choice","choice":"unknown","probabilities":{"unknown":0.99},"confidence":0.99}}}"#)
        }
        try await server.start()
        defer { server.stop() }

        let categorizer = JevCategorizer(apiKey: "test-key", baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let result = try await categorizer.categorize(request())
        #expect(result.category == .unknown)
    }

    @Test func nonSuccessStatusThrows() async throws {
        let server = try FakeHTTPServer { _ in (401, #"{"error":"invalid api key"}"#) }
        try await server.start()
        defer { server.stop() }

        let categorizer = JevCategorizer(apiKey: "bad-key", baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        await #expect(throws: JevCategorizer.JevError.httpStatus(401)) {
            _ = try await categorizer.categorize(request())
        }
    }

    @Test func malformedResponseThrowsRatherThanCrashing() async throws {
        let server = try FakeHTTPServer { _ in (200, #"{"model":"jev-1.13.0","answers":{}}"#) }
        try await server.start()
        defer { server.stop() }

        let categorizer = JevCategorizer(apiKey: "test-key", baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        await #expect(throws: JevCategorizer.JevError.self) {
            _ = try await categorizer.categorize(request())
        }
    }
}
