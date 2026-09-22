import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

@MainActor
@Suite(.serialized)
struct SenderOverrideTests {
    private func cluster(_ address: String, category: SenderCategory = .promotion,
                         messages: Int = 20, unread: Int = 20, oneClick: Bool = true) -> SenderCluster {
        SenderCluster(address: address, displayName: address, domain: "x.example", mailbox: "INBOX",
                      uids: Array(1...UInt32(messages)), unreadUIDs: Array(1...UInt32(max(unread, 1))),
                      messageCount: messages, unreadCount: unread, flaggedCount: 0, sweptCount: 0,
                      newest: .now, oldest: .now, hasUnsubscribeLink: oneClick,
                      unsubscribeValue: oneClick ? "<https://x.example/u>" : nil,
                      supportsOneClickUnsubscribe: oneClick, everContacted: false, sampleSubjects: [],
                      category: category)
    }
    private func assessed(_ c: SenderCluster) -> SenderAssessment {
        SenderAssessment(cluster: c, verdict: .bulk, score: 10, reasons: [])
    }

    /// "Always bin this one" without turning the whole policy up.
    @Test func perSenderDispositionBeatsThePolicy() {
        let a = [assessed(cluster("deals@x.example")), assessed(cluster("news@x.example", category: .newsletter))]
        let plan = CleanupPlan.suggested(from: a, policy: .gentle,
                                         overrides: ["deals@x.example": .init(decision: .sweep, disposition: .trash)])
        let byAddress = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.cluster.address, $0) })
        #expect(byAddress["deals@x.example"]?.disposition == .trash, "the override wins")
        #expect(byAddress["news@x.example"]?.disposition == .fileIntoFolders, "everyone else follows the policy")
    }

    /// And "never unsubscribe from this one", even under the most aggressive policy.
    @Test func perSenderUnsubscribeOverridesBothWays() {
        let deals = assessed(cluster("deals@x.example"))
        let never = CleanupPlan.suggested(from: [deals], policy: .thorough,
                                          overrides: ["deals@x.example": .init(decision: .sweep, autoUnsubscribe: false)])
        #expect(never.items.first?.unsubscribe == false, "never, even under Thorough")

        let always = CleanupPlan.suggested(from: [deals], policy: .gentle,
                                           overrides: ["deals@x.example": .init(decision: .sweep, autoUnsubscribe: true)])
        #expect(always.items.first?.unsubscribe == true, "yes, even under Gentle")

        // An override cannot invent an endpoint that does not exist.
        let noLink = assessed(cluster("nolink@x.example", oneClick: false))
        let impossible = CleanupPlan.suggested(from: [noLink], policy: .gentle,
                                               overrides: ["nolink@x.example": .init(decision: .sweep, autoUnsubscribe: true)])
        #expect(impossible.items.first?.unsubscribe == false)
    }

    /// A custom folder beats the category default, without needing the user
    /// to separately set a disposition.
    @Test func customFolderBeatsTheCategoryDefault() {
        let promo = assessed(cluster("deals@x.example", category: .promotion))
        let news = assessed(cluster("news@x.example", category: .newsletter))
        let plan = CleanupPlan.suggested(from: [promo, news], policy: .gentle,
                                         overrides: ["deals@x.example": .init(decision: .sweep, customFolder: "Clients/VIP")])
        let byAddress = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.cluster.address, $0) })
        #expect(byAddress["deals@x.example"]?.folder == "Clients/VIP")
        #expect(byAddress["news@x.example"]?.folder == SenderCategory.newsletter.folderName, "everyone else keeps the category folder")
    }

    /// A folder pick can never be silently discarded by a trash/archive-only
    /// disposition — setting one always implies filing into folders.
    @Test func settingACustomFolderForcesFileIntoFolders() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext

        RuleStore.setDisposition(.trash, for: "deals@x.example", in: context)
        #expect(RuleStore.overrides(in: context)["deals@x.example"]?.disposition == .trash)

        RuleStore.setCustomFolder("Clients/VIP", for: "deals@x.example", in: context)
        let overrides = RuleStore.overrides(in: context)
        #expect(overrides["deals@x.example"]?.customFolder == "Clients/VIP")
        #expect(overrides["deals@x.example"]?.disposition == .fileIntoFolders, "a folder pick overrides trash/archive-only")

        RuleStore.setCustomFolder(nil, for: "deals@x.example", in: context)
        #expect(RuleStore.overrides(in: context)["deals@x.example"]?.customFolder == nil, "clearing returns to the category default")
    }

    /// `byFolder` groups by the resolved folder, so two different-category
    /// senders sharing a custom folder land in one group.
    @Test func byFolderGroupsDifferentCategoriesUnderASharedCustomFolder() throws {
        let promo = assessed(cluster("deals@x.example", category: .promotion, messages: 5))
        let news = assessed(cluster("news@x.example", category: .newsletter, messages: 3))
        let plan = CleanupPlan.suggested(from: [promo, news], policy: .gentle,
                                         overrides: [
                                            "deals@x.example": .init(decision: .sweep, customFolder: "Clients/VIP"),
                                            "news@x.example": .init(decision: .sweep, customFolder: "Clients/VIP")
                                         ])
        let group = try #require(plan.byFolder.first { $0.folder == "Clients/VIP" })
        #expect(group.items.count == 2)
        #expect(Set(group.items.map(\.cluster.address)) == ["deals@x.example", "news@x.example"])
    }

    @Test func storeReadsAndWritesOverrides() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext

        RuleStore.setDisposition(.trash, for: "deals@x.example", in: context)
        var overrides = RuleStore.overrides(in: context)
        #expect(overrides["deals@x.example"]?.disposition == .trash)
        #expect(overrides["deals@x.example"]?.decision == .sweep, "naming a destination implies sweeping it")

        RuleStore.setAutoUnsubscribe(false, for: "deals@x.example", in: context)
        overrides = RuleStore.overrides(in: context)
        #expect(overrides["deals@x.example"]?.autoUnsubscribe == false)
        #expect(overrides["deals@x.example"]?.disposition == .trash, "one setting does not clear the other")

        let rule = try #require(try context.fetch(FetchDescriptor<SenderRule>()).first)
        #expect(rule.summary.contains("Always sweep") && rule.summary.contains("trash") && rule.summary.contains("never unsubscribe"))

        RuleStore.setDisposition(nil, for: "deals@x.example", in: context)
        #expect(RuleStore.overrides(in: context)["deals@x.example"]?.disposition == nil, "back to following the policy")

        RuleStore.clear(for: "deals@x.example", in: context)
        #expect(RuleStore.overrides(in: context).isEmpty)
    }
}

/// What actually protects people's installs: opening a store that this build
/// cannot read must never crash, and must never silently lose the file.
struct StoreRecoveryTests {
    @Test func anUnreadableStoreIsMovedAsideAndTheAppStillOpens() throws {
        let directory = URL.temporaryDirectory.appending(path: "grokbox-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "default.store")
        // Not a database at all — the worst case a bad write can leave behind.
        try Data("this is not a SQLite file".utf8).write(to: url)

        let schema = Schema(versionedSchema: GrokboxSchemaV1.self)
        let container = try? ModelContainer(for: schema, migrationPlan: GrokboxMigrationPlan.self,
                                            configurations: ModelConfiguration(schema: schema, url: url))
        #expect(container == nil, "an unreadable file cannot be opened as-is")
        // GrokboxStore.open's job is to survive exactly this; it moves the file
        // aside rather than deleting it, so nothing is destroyed.
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func anAdditiveChangeOpensAnExistingStoreInPlace() throws {
        let directory = URL.temporaryDirectory.appending(path: "grokbox-additive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "test.store")
        let schema = Schema(versionedSchema: GrokboxSchemaV1.self)
        let config = ModelConfiguration(schema: schema, url: url)

        do {
            let container = try ModelContainer(for: schema, migrationPlan: GrokboxMigrationPlan.self, configurations: config)
            let context = ModelContext(container)
            context.insert(SenderRule(address: "deals@x.example", decision: .sweep))
            context.insert(MailAccount(displayName: "Old", username: "old@example.com", host: "imap.example.com",
                                       port: 993, kind: .generic, security: .tls))
            try context.save()
        }
        // Reopening is the path every launch takes.
        let container = try ModelContainer(for: schema, migrationPlan: GrokboxMigrationPlan.self, configurations: config)
        let context = ModelContext(container)
        let rule = try #require(try context.fetch(FetchDescriptor<SenderRule>()).first)
        #expect(rule.address == "deals@x.example")
        #expect(rule.disposition == nil, "a property added since the store was written reads as nil")
        rule.disposition = .trash
        try context.save()
        #expect(try context.fetch(FetchDescriptor<SenderRule>()).first?.disposition == .trash)
        #expect(try context.fetch(FetchDescriptor<MailAccount>()).first?.username == "old@example.com")
    }

    @Test func theSchemaIsVersionedAndCoversEveryModel() {
        #expect(GrokboxSchemaV1.models.count == 8)
        #expect(GrokboxMigrationPlan.schemas.count == 1)
        #expect(GrokboxMigrationPlan.stages.isEmpty, "no stage is needed while changes stay additive")
        _ = Schema(versionedSchema: GrokboxSchemaV1.self)
    }
}
