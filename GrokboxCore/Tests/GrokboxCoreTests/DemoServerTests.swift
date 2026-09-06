import Foundation
import Testing
@testable import GrokboxCore

/// The demo server is real enough that the full client can index, read, and
/// sweep against it — and its state changes when swept.
@Suite(.serialized)
struct DemoServerTests {
    @Test func corpusIsDeterministicAndPlausible() {
        let a = DemoCorpus.generate(persona: .personal)["[Gmail]/All Mail"]!
        let b = DemoCorpus.generate(persona: .personal)["[Gmail]/All Mail"]!
        #expect(a.map(\.uid) == b.map(\.uid))
        #expect(a.count > 300 && a.count < 2_000, "got \(a.count)")
        #expect(a.contains { $0.listUnsubscribe != nil && $0.oneClick })
        #expect(a.contains { $0.flags.contains("\\Flagged") })
        #expect(a.contains { !$0.labels.contains("\\Inbox") }, "some mail already archived")
        #expect(Set(a.map(\.fromAddress)).count >= 20)
    }

    @Test func fullIndexRoundTrip() async throws {
        let server = try DemoMailServer()
        try await server.start()
        defer { server.stop() }

        let client = IMAPClient()
        try await client.connect(host: "127.0.0.1", port: Int(server.port), security: .none)
        try await client.login(username: server.username, password: DemoMailServer.password)
        #expect(await client.capabilities.supportsGmailExtensions)

        let mailboxes = try await client.listMailboxes().filter(\.isSelectable)
        let all = try #require(mailboxes.primaryArchive)
        #expect(all.name == "[Gmail]/All Mail")

        let status = try await client.examine(all.name)
        #expect(status.uidValidity == DemoMailServer.uidValidity)
        #expect(status.exists == server.messages(in: all.name).count)

        let headers = try await client.fetchHeaders(from: 1, to: min(250, status.exists))
        #expect(headers.count == min(250, status.exists))
        #expect(headers.allSatisfy { $0.gmailLabels != nil }, "labels come through on a Gmail-flavoured server")
        #expect(headers.contains { !$0.isInInbox })

        // Sent mailbox exists and names contacts.
        let sent = try #require(mailboxes.sentMailbox)
        let sentStatus = try await client.examine(sent.name)
        let sentHeaders = try await client.fetchHeaders(from: 1, to: sentStatus.exists)
        #expect(sentHeaders.contains { $0.recipients.contains("alice@adamsfamily.example") })

        // Body excerpt through the multipart path.
        _ = try await client.examine(all.name)
        let html = try #require(server.messages(in: all.name).first { $0.isHTML })
        let body = try await client.fetchBodyExcerpt(uid: html.uid)
        let text = BodyExtractor.plainText(from: try #require(body))
        #expect(!text.contains("<html>"))
        #expect(!text.isEmpty)
        await client.logout()
    }

    @Test func incrementalFetchReturnsOnlyNewerUIDs() async throws {
        let server = try DemoMailServer()
        try await server.start()
        defer { server.stop() }

        let client = IMAPClient()
        try await client.connect(host: "127.0.0.1", port: Int(server.port), security: .none)
        try await client.login(username: server.username, password: DemoMailServer.password)
        _ = try await client.examine("[Gmail]/All Mail")

        let all = server.messages(in: "[Gmail]/All Mail")
        let pivot = all[all.count - 10].uid
        let newer = try await client.fetchHeaders(uidsFrom: pivot + 1)
        #expect(newer.count == 9)
        #expect(newer.allSatisfy { $0.uid > pivot })

        let beyond = try await client.fetchHeaders(uidsFrom: (all.last!.uid) + 100)
        #expect(beyond.isEmpty, "n:* past the end must not return the last message")
        await client.logout()
    }

    @Test func sweepActuallyArchivesAndUndoRestores() async throws {
        let server = try DemoMailServer()
        try await server.start()
        defer { server.stop() }

        let client = IMAPClient()
        try await client.connect(host: "127.0.0.1", port: Int(server.port), security: .none)
        try await client.login(username: server.username, password: DemoMailServer.password)

        let target = try #require(server.messages(in: "[Gmail]/All Mail").first { $0.labels.contains("\\Inbox") && !$0.flags.contains("\\Seen") })
        let inboxBefore = server.messages(in: "INBOX").count

        _ = try await client.select("[Gmail]/All Mail")
        try await client.storeGmailLabels(uids: [target.uid], .add, labels: ["Grokbox/Swept"])
        try await client.storeGmailLabels(uids: [target.uid], .remove, labels: ["\\Inbox"])
        try await client.store(uids: [target.uid], .add, flags: ["\\Seen"])

        let after = try #require(server.messages(in: "[Gmail]/All Mail").first { $0.uid == target.uid })
        #expect(!after.labels.contains("\\Inbox"))
        #expect(after.labels.contains("Grokbox/Swept"))
        #expect(after.flags.contains("\\Seen"))
        #expect(server.messages(in: "INBOX").count == inboxBefore - 1)

        // Flags refresh sees the change.
        let count = server.messages(in: "[Gmail]/All Mail").count
        let updates = try await client.fetchFlags(from: 1, to: count)
        let refreshed = try #require(updates.first { $0.uid == target.uid })
        #expect(refreshed.isInInbox == false)

        // Undo.
        try await client.storeGmailLabels(uids: [target.uid], .add, labels: ["\\Inbox"])
        try await client.store(uids: [target.uid], .remove, flags: ["\\Seen"])
        let restored = try #require(server.messages(in: "[Gmail]/All Mail").first { $0.uid == target.uid })
        #expect(restored.labels.contains("\\Inbox"))
        #expect(!restored.flags.contains("\\Seen"))
        await client.logout()
    }

    @Test func rejectsWrongPassword() async throws {
        let server = try DemoMailServer()
        try await server.start()
        defer { server.stop() }
        let client = IMAPClient()
        try await client.connect(host: "127.0.0.1", port: Int(server.port), security: .none)
        await #expect(throws: IMAPError.self) {
            try await client.login(username: server.username, password: "nope")
        }
        await client.logout()
    }

    @Test func personasDiffer() {
        let personal = DemoCorpus.generate(persona: .personal)["[Gmail]/All Mail"]!
        let work = DemoCorpus.generate(persona: .work)["[Gmail]/All Mail"]!
        let neglected = DemoCorpus.generate(persona: .neglected)["[Gmail]/All Mail"]!
        #expect(work.contains { $0.fromAddress.hasSuffix("taskflow.example") })
        #expect(!personal.contains { $0.fromAddress.hasSuffix("taskflow.example") })
        #expect(neglected.count > personal.count, "the neglected inbox is the big one")
        let humanShare = { (m: [DemoMailServer.Message]) -> Double in
            Double(m.filter { $0.labels.contains("\\Important") }.count) / Double(m.count)
        }
        #expect(humanShare(neglected) < humanShare(personal))
    }

    @Test func parsesSequenceSets() {
        #expect(DemoMailServer.parseSet("1:3,7", max: 10) == [1, 2, 3, 7])
        #expect(DemoMailServer.parseSet("8:*", max: 10) == [8, 9, 10])
        #expect(DemoMailServer.parseSet("*", max: 10) == [10])
        #expect(DemoMailServer.parseList("(\\Inbox \"Grokbox/Swept\")") == ["\\Inbox", "Grokbox/Swept"])
    }
}

struct ConnectionSafetyTests {
    @Test func insecureModesRefuseRemoteHosts() async {
        let client = IMAPClient()
        await #expect(throws: IMAPError.self) {
            try await client.connect(host: "imap.gmail.com", port: 993, security: .none)
        }
        await #expect(throws: IMAPError.self) {
            try await client.connect(host: "imap.gmail.com", port: 993, security: .tlsSelfSignedLoopback)
        }
    }
}
