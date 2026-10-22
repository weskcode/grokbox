import Foundation
import SwiftData
import Testing
@testable import GrokboxCore

/// The 1.2.0 store. Version 1.3.0 only adds `ConversationCorrection`, so the
/// live types minus that one are the old shape exactly (ADR-0021).
enum GrokboxSchemaV1_2_0: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 2, 0) }
    static var models: [any PersistentModel.Type] {
        GrokboxSchemaV1.models.filter { ObjectIdentifier($0) != ObjectIdentifier(ConversationCorrection.self) }
    }
}

private let anchorDate = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
struct ConversationCorrectionTests {
    @Test func aVersion120StoreUpgradesInPlaceAndKeepsEverything() throws {
        let directory = URL.temporaryDirectory.appending(path: "grokbox-v120-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "default.store")
        let account: UUID

        do {
            let old = Schema(versionedSchema: GrokboxSchemaV1_2_0.self)
            let container = try ModelContainer(for: old, configurations: ModelConfiguration(schema: old, url: url))
            let context = ModelContext(container)
            let mail = MailAccount(displayName: "Me", username: "me@example.com", host: "imap.example.com", port: 993,
                                   kind: .generic, security: .tls)
            account = mail.id
            context.insert(mail)
            context.insert(SenderRule(address: "deals@x.example", decision: .sweep))
            context.insert(CleanupAction(accountID: account, kind: .archive, senderAddress: "deals@x.example", senderName: "Deals",
                                         mailbox: "INBOX", uids: [3, 4], isUndoable: true, uidValidity: 11))
            context.insert(MessageHeader(accountID: account, uid: 7, mailbox: "INBOX", subject: "Lunch", senderName: "Alice",
                                         senderAddress: "alice@friend.example", receivedAt: anchorDate, isUnread: true,
                                         isFlagged: false, listUnsubscribe: nil, listUnsubscribePost: nil, listID: nil,
                                         messageID: "<a0@friend.example>"))
            var sent = FetchedHeader(uid: 41, subject: "Re: Lunch", senderName: "", senderAddress: "me@example.com",
                                     recipients: ["alice@friend.example"], date: anchorDate, isUnread: false, isFlagged: false,
                                     gmailLabels: nil, listUnsubscribe: nil, listUnsubscribePost: nil, listID: nil,
                                     messageID: "<s41@example.com>")
            sent.inReplyTo = ["a0@friend.example"]
            context.insert(SentMessageHeader(accountID: account, mailbox: "Sent", uidValidity: 5, header: sent))
            context.insert(MailboxSnapshot(accountID: account, mailbox: "INBOX", uidValidity: 9, highestUID: 7, messageCountOnServer: 1))
            try context.save()
        }

        func openProduction() throws -> ModelContext {
            let schema = Schema(versionedSchema: GrokboxSchemaV1.self)
            return ModelContext(try ModelContainer(for: schema, migrationPlan: GrokboxMigrationPlan.self,
                                                   configurations: ModelConfiguration(schema: schema, url: url)))
        }

        do {
            let context = try openProduction()
            #expect(!FileManager.default.fileExists(atPath: url.path + ".unreadable"), "the old store was not set aside")
            #expect(try context.fetch(FetchDescriptor<SenderRule>()).map(\.address) == ["deals@x.example"])
            #expect(try context.fetch(FetchDescriptor<CleanupAction>()).first?.uids == [3, 4])
            #expect(try context.fetchCount(FetchDescriptor<MessageHeader>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<MailAccount>()) == 1)
            #expect(try context.fetch(FetchDescriptor<SentMessageHeader>()).first?.inReplyTo == "a0@friend.example",
                    "1.2.0 Sent history survives")
            #expect(try context.fetch(FetchDescriptor<MailboxSnapshot>()).first?.uidValidity == 9)
            #expect(try context.fetchCount(FetchDescriptor<ConversationCorrection>()) == 0)
            try ConversationCorrection.record(.resolved, accountID: account, conversationID: "headers|a0@friend.example",
                                              anchorMessageKey: "a0@friend.example", anchorDate: anchorDate, in: context)
        }

        let reopened = try openProduction()
        let rows = try reopened.fetch(FetchDescriptor<ConversationCorrection>())
        #expect(rows.count == 1, "a correction written after the upgrade survives a reopen")
        #expect(rows.first?.correction == .init(state: .resolved, anchorKey: "a0@friend.example", anchorDate: anchorDate))
        #expect(try reopened.fetchCount(FetchDescriptor<SenderRule>()) == 1)
        #expect(try reopened.fetchCount(FetchDescriptor<SentMessageHeader>()) == 1)
    }

    @Test func choosingAgainReplacesTheOneRow() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let account = UUID()
        try ConversationCorrection.record(.waiting, accountID: account, conversationID: "c1", anchorMessageKey: "m1",
                                          anchorDate: anchorDate, in: context)
        try ConversationCorrection.record(.resolved, accountID: account, conversationID: "c1", anchorMessageKey: "m2",
                                          anchorDate: anchorDate.addingTimeInterval(60), in: context)
        let rows = try context.fetch(FetchDescriptor<ConversationCorrection>())
        #expect(rows.count == 1)
        #expect(rows.first?.correction?.state == .resolved)
        #expect(rows.first?.anchorMessageKey == "m2")
    }

    @Test func refusesWhatIsNotAChoice() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        #expect(throws: ConversationCorrection.RecordError.noConversation) {
            try ConversationCorrection.record(.resolved, accountID: UUID(), conversationID: "", anchorMessageKey: "m",
                                              anchorDate: anchorDate, in: context)
        }
        #expect(throws: ConversationCorrection.RecordError.notAChoice) {
            try ConversationCorrection.record(.uncertain, accountID: UUID(), conversationID: "c", anchorMessageKey: "m",
                                              anchorDate: anchorDate, in: context)
        }
        #expect(try context.fetchCount(FetchDescriptor<ConversationCorrection>()) == 0)
    }

    @Test func aStoredChoiceDrivesTheRules() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let row = try ConversationCorrection.record(.resolved, accountID: UUID(), conversationID: "c", anchorMessageKey: "b",
                                                    anchorDate: anchorDate, in: context)
        let messages = [
            ConversationResponsibility.Message(key: "a", date: anchorDate.addingTimeInterval(-60), author: "priya@example.com",
                                               isFromUser: false, isAddressedToUser: true, parent: .root, automation: .human,
                                               reading: .read(.needsYou, .reply)),
            ConversationResponsibility.Message(key: "b", date: anchorDate, author: "me@example.com", isFromUser: true,
                                               isAddressedToUser: nil, parent: .message("a"), automation: .human, reading: .notRead),
        ]
        let conversation = ConversationResponsibility.Conversation(identity: .headers, sentCoverage: .since(.distantPast),
                                                                   messages: messages)
        #expect(ConversationResponsibility.derive(conversation, correction: row.correction)?.state == .resolved)
    }

    @Test func unknownStoredStateIsIgnored() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let row = try ConversationCorrection.record(.waiting, accountID: UUID(), conversationID: "c", anchorMessageKey: "m",
                                                    anchorDate: anchorDate, in: context)
        row.stateRaw = "someFutureState"
        #expect(row.correction == nil)
    }

    @Test func removingAnAccountRemovesOnlyItsChoices() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let kept = UUID(), removed = UUID()
        for account in [kept, removed] {
            try ConversationCorrection.record(.waiting, accountID: account, conversationID: "c", anchorMessageKey: "m",
                                              anchorDate: anchorDate, in: context)
        }
        try ConversationCorrection.deleteAll(accountID: removed, in: context)
        #expect(try context.fetch(FetchDescriptor<ConversationCorrection>()).map(\.accountID) == [kept])
        try ConversationCorrection.deleteAll(in: context)
        #expect(try context.fetchCount(FetchDescriptor<ConversationCorrection>()) == 0)
    }

    @Test func exportCarriesChoicesAndImportRestoresKnownAccounts() throws {
        let sourceContainer = ModelContainer.grokboxTestContainer()
        let source = sourceContainer.mainContext
        let mail = MailAccount(displayName: "Me", username: "me@example.com", host: "imap.example.com", port: 993,
                               kind: .generic, security: .tls)
        source.insert(mail)
        try ConversationCorrection.record(.resolved, accountID: mail.id, conversationID: "headers|a0@x.example",
                                          anchorMessageKey: "a0@x.example", anchorDate: anchorDate, in: source)
        try ConversationCorrection.record(.waiting, accountID: UUID(), conversationID: "headers|gone", anchorMessageKey: "g",
                                          anchorDate: anchorDate, in: source)
        let document = try DataExport.decode(DataExport.encode(DataExport.document(from: source)))
        #expect(document.version == 2)
        #expect(document.corrections?.count == 2)
        #expect(document.corrections?.contains { $0.conversationID == "headers|a0@x.example" && $0.state == "resolved" } == true)

        let targetContainer = ModelContainer.grokboxTestContainer()
        let target = targetContainer.mainContext
        let sameAccount = MailAccount(displayName: "Me", username: "me@example.com", host: "imap.example.com", port: 993,
                                      kind: .generic, security: .tls)
        sameAccount.id = mail.id
        target.insert(sameAccount)
        #expect(try DataExport.importCorrections(from: document, into: target) == 1, "unknown accounts are skipped")
        #expect(try DataExport.importCorrections(from: document, into: target) == 1)
        let rows = try target.fetch(FetchDescriptor<ConversationCorrection>())
        #expect(rows.count == 1, "re-import keeps one row")
        #expect(rows.first?.key == ConversationCorrection.key(accountID: mail.id, conversationID: "headers|a0@x.example"))
        #expect(rows.first?.correction == .init(state: .resolved, anchorKey: "a0@x.example", anchorDate: anchorDate))
    }

    @Test func importSkipsEntriesItCannotAcceptAndSavesOnce() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let mail = MailAccount(displayName: "Me", username: "me@example.com", host: "imap.example.com", port: 993,
                               kind: .generic, security: .tls)
        context.insert(mail)
        try context.save()
        func entry(_ id: String, _ state: String) -> DataExport.Document.Correction {
            .init(accountID: mail.id, conversationID: id, state: state, anchorMessageKey: "m", anchorDate: anchorDate,
                  correctedAt: anchorDate)
        }
        let document = DataExport.Document(exportedAt: anchorDate, accounts: [], rules: [], actions: [], digests: [],
                                           corrections: [entry("ok", "waiting"), entry("bad", "uncertain"),
                                                         entry("", "resolved"), entry("future", "someFutureState")])
        #expect(try DataExport.importCorrections(from: document, into: context) == 1)
        #expect(try context.fetch(FetchDescriptor<ConversationCorrection>()).map(\.key)
                == [ConversationCorrection.key(accountID: mail.id, conversationID: "ok")])
    }

    @Test func versionOneExportsStillDecodeAndImportRules() throws {
        let json = """
        {"format":"grokbox-export","version":1,"exportedAt":"2026-10-01T00:00:00Z","accounts":[],
         "rules":[{"address":"a@x.example","decision":"keep","createdAt":"2026-10-01T00:00:00Z","timesApplied":0}],
         "actions":[],"digests":[]}
        """
        let document = try DataExport.decode(Data(json.utf8))
        #expect(document.corrections == nil)
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        #expect(try DataExport.importRules(from: document, into: context) == 1)
        #expect(try DataExport.importCorrections(from: document, into: context) == 0)
    }
}
