import Foundation
import Testing
@testable import GrokboxCore

/// End-to-end: the real client against a scripted server on loopback.
@Suite(.serialized)
struct IMAPClientTests {
    /// Parallel suites each open loopback listeners; the kernel occasionally
    /// hands out a port still settling, so connecting gets one quick retry.
    private func connectedClient(_ server: FakeIMAPServer) async throws -> IMAPClient {
        let client = try await connect(to: Int(server.port))
        try await client.login(username: "me@gmail.example", password: "app-password")
        return client
    }

    private func connect(to port: Int) async throws -> IMAPClient {
        var lastError: Error?
        for attempt in 0..<3 {
            let client = IMAPClient()
            do {
                try await client.connect(host: "127.0.0.1", port: port, security: .none)
                return client
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
            }
        }
        throw lastError!
    }

    @Test func logsInAndReadsCapabilities() async throws {
        let server = try FakeIMAPServer(script: GmailFixture.script)
        try await server.start()
        defer { server.stop() }

        let client = try await connectedClient(server)
        let caps = await client.capabilities
        #expect(caps.supportsGmailExtensions)
        #expect(caps.supportsMove)
        #expect(caps.supportsUIDPlus)
        await client.logout()

        #expect(server.commands.first?.hasPrefix("LOGIN \"me@gmail.example\" \"app-password\"") == true)
    }

    @Test func discoversSpecialUseMailboxes() async throws {
        let server = try FakeIMAPServer(script: GmailFixture.script)
        try await server.start()
        defer { server.stop() }

        let client = try await connectedClient(server)
        let mailboxes = try await client.listMailboxes().filter(\.isSelectable)
        await client.logout()

        #expect(mailboxes.primaryArchive?.name == "[Gmail]/All Mail")
        #expect(mailboxes.sentMailbox?.name == "[Gmail]/Sent Mail")
        #expect(mailboxes.contains { $0.name == "[Gmail]" } == false, "\\Noselect nodes are filtered")
    }

    @Test func fetchesHeadersThroughLiterals() async throws {
        let server = try FakeIMAPServer(script: GmailFixture.script)
        try await server.start()
        defer { server.stop() }

        let client = try await connectedClient(server)
        let status = try await client.examine("[Gmail]/All Mail")
        #expect(status.exists == 3)
        #expect(status.uidValidity == 1)

        let headers = try await client.fetchHeaders(from: 1, to: 3)
        await client.logout()

        #expect(headers.count == 3)

        let promo = try #require(headers.first { $0.uid == 10 })
        #expect(promo.subject == "50% off everything", "Q-encoded subject decoded")
        #expect(promo.senderName == "Schön News", "B-encoded display name decoded")
        #expect(promo.senderAddress == "news@shop.example")
        #expect(promo.isUnread)
        #expect(promo.listUnsubscribe?.contains("https://shop.example/unsub") == true)
        #expect(promo.listUnsubscribePost?.contains("One-Click") == true)

        let alice = try #require(headers.first { $0.uid == 20 })
        #expect(alice.senderName == "Alice Adams")
        #expect(alice.senderAddress == "alice@friend.example")

        let bill = try #require(headers.first { $0.uid == 30 })
        #expect(bill.isUnread == false, "\\Seen flag respected")
        #expect(bill.senderAddress == "billing@utility.example")
    }

    @Test func fetchesBodyExcerpt() async throws {
        let server = try FakeIMAPServer(script: GmailFixture.script)
        try await server.start()
        defer { server.stop() }

        let client = try await connectedClient(server)
        _ = try await client.examine("[Gmail]/All Mail")
        let body = try await client.fetchBodyExcerpt(uid: 20)
        await client.logout()

        let text = BodyExtractor.plainText(from: try #require(body))
        #expect(text.contains("Please reply by Friday"))
    }

    @Test func indexingIsStructurallyReadOnly() async throws {
        let server = try FakeIMAPServer(script: GmailFixture.script)
        try await server.start()
        defer { server.stop() }

        let client = try await connectedClient(server)
        _ = try await client.listMailboxes()
        _ = try await client.examine("[Gmail]/Sent Mail")
        _ = try await client.fetchHeaders(from: 1, to: 1)
        _ = try await client.examine("[Gmail]/All Mail")
        _ = try await client.fetchHeaders(from: 1, to: 3)
        _ = try await client.fetchBodyExcerpt(uid: 20)
        await client.logout()

        let sent = server.commands.map { $0.uppercased() }
        #expect(sent.contains { $0.hasPrefix("SELECT") } == false, "indexing must use EXAMINE")
        #expect(sent.contains { $0.contains("STORE") } == false)
        #expect(sent.contains { $0.contains("EXPUNGE") } == false)
        #expect(sent.contains { $0.contains("BODY[") && !$0.contains("BODY.PEEK[") } == false, "must never use non-PEEK BODY")
    }

    @Test func archiveSendsGmailLabelRemoval() async throws {
        let server = try FakeIMAPServer(script: GmailFixture.script)
        try await server.start()
        defer { server.stop() }

        let client = try await connectedClient(server)
        _ = try await client.select("[Gmail]/All Mail")
        try await client.storeGmailLabels(uids: [10, 20, 30, 50], .remove, labels: ["\\Inbox"])
        try await client.storeGmailLabels(uids: [10], .add, labels: ["Grokbox/Swept"])
        try await client.store(uids: [10, 20], .add, flags: ["\\Seen"])
        await client.logout()

        let sent = server.commands
        #expect(sent.contains("UID STORE 10,20,30,50 -X-GM-LABELS.SILENT (\\Inbox)"))
        #expect(sent.contains("UID STORE 10 +X-GM-LABELS.SILENT (\"Grokbox/Swept\")"))
        #expect(sent.contains("UID STORE 10,20 +FLAGS.SILENT (\\Seen)"))
        #expect(sent.contains { $0.uppercased().contains("DELETED") } == false, "never sets \\Deleted")
    }

    @Test func uidSetsCompressRanges() {
        #expect(IMAPClient.uidSets([1, 2, 3, 5, 7, 8]) == ["1:3,5,7:8"])
        #expect(IMAPClient.uidSets([9]) == ["9"])
        #expect(IMAPClient.uidSets([3, 1, 2, 2]) == ["1:3"], "sorted and de-duplicated")
        let big = Array(1...1200).map(UInt32.init)
        #expect(IMAPClient.uidSets(big).count == 3, "chunked at 500")
    }

    @Test func rejectsBadLogin() async throws {
        let server = try FakeIMAPServer(script: [("LOGIN", "{tag} NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n")])
        try await server.start()
        defer { server.stop() }

        let client = try await connect(to: Int(server.port))
        await #expect(throws: IMAPError.self) {
            try await client.login(username: "x", password: "wrong")
        }
    }
}
