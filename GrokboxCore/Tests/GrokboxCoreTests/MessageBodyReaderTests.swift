import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

/// `MessageBodyReader` wraps `MailProvider.openReadOnly`/`bodyExcerpt`, which
/// `IMAPClientTests.fetchesBodyExcerpt`/`indexingIsStructurallyReadOnly`
/// already prove map to EXAMINE and BODY.PEEK and never SELECT/STORE/EXPUNGE.
/// These tests cover what is actually new here: the reader's own uid/mailbox
/// routing through `MailProviderFactory`, and its empty-body error path —
/// exercised against an in-process demo mailbox, the same no-socket pattern
/// `GenericServerFlowTests` uses for whole-feature flows.
@MainActor
@Suite(.serialized)
struct MessageBodyReaderTests {
    private func setUp() -> (ModelContainer, MailAccount, DemoMailbox) {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let mailbox = DemoMailbox(persona: .personal, flavor: .gmail)
        let account = MailAccount(displayName: "Demo", username: mailbox.username, host: "127.0.0.1",
                                  port: 0, kind: .demo, security: .none)
        context.insert(account); try! context.save()
        DemoRegistry.shared.register(mailbox, for: account.id)
        return (container, account, mailbox)
    }

    @Test func readsTheSameBodyTheServerHolds() async throws {
        let (container, account, mailbox) = setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        _ = container

        let message = try #require(mailbox.messages(in: "INBOX").first)
        let expected = BodyExtractor.plainText(from: try #require(mailbox.body(in: "INBOX", uid: message.uid)))

        let reading = try await MessageBodyReader.read(uid: message.uid, mailbox: "INBOX", account: account,
                                                       senderDomain: "grokbox.demo")
        #expect(reading.text == expected)
        #expect(!reading.text.isEmpty)
    }

    @Test func aMissingMessageThrowsADedicatedErrorRatherThanShowingBlankText() async throws {
        let (container, account, _) = setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        _ = container

        await #expect(throws: MessageBodyReader.ReaderError.empty) {
            _ = try await MessageBodyReader.read(uid: 999_999, mailbox: "INBOX", account: account, senderDomain: "grokbox.demo")
        }
    }
}
