import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

/// A store that refuses every save, to stand in for a full disk or a locked
/// database. The second container reads the same file with saving switched off.
@MainActor
private struct RefusingStore {
    let writable: ModelContext
    let refusing: ModelContext
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rule-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("test.store")
        let schema = Schema(versionedSchema: GrokboxSchemaV1.self)
        let open = try ModelContainer(for: schema, migrationPlan: GrokboxMigrationPlan.self,
                                      configurations: ModelConfiguration(schema: schema, url: url))
        writable = ModelContext(open)
        let closed = try ModelContainer(for: schema, migrationPlan: GrokboxMigrationPlan.self,
                                        configurations: ModelConfiguration(schema: schema, url: url, allowsSave: false))
        refusing = ModelContext(closed)
        keepAlive = [open, closed]
    }

    private let keepAlive: [ModelContainer]

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func storedRules() -> [String: SenderOverride] {
        RuleStore.overrides(in: ModelContext(keepAlive[0]))
    }
}

@MainActor
@Suite(.serialized)
struct RuleSaveFailureTests {
    @Test func aRefusedSaveThrowsAndLeavesNoRuleBehind() throws {
        let store = try RefusingStore()
        defer { store.remove() }

        #expect(throws: RuleSaveError.self) {
            try RuleStore.set(.sweep, for: "news@x.example", in: store.refusing)
        }
        #expect(RuleStore.all(in: store.refusing).isEmpty, "the screen must not show a rule the store never took")
        #expect(store.storedRules().isEmpty)
    }

    @Test func aRefusedEditKeepsTheRuleAsItWas() throws {
        let store = try RefusingStore()
        defer { store.remove() }
        try RuleStore.set(.sweep, for: "news@x.example", in: store.writable)
        try RuleStore.setDisposition(.archiveOnly, for: "news@x.example", in: store.writable)

        #expect(throws: RuleSaveError.self) {
            try RuleStore.setDisposition(.trash, for: "news@x.example", in: store.refusing)
        }
        #expect(throws: RuleSaveError.self) {
            try RuleStore.setCustomFolder("Clients/VIP", for: "news@x.example", in: store.refusing)
        }
        let shown = RuleStore.overrides(in: store.refusing)["news@x.example"]
        #expect(shown == SenderOverride(decision: .sweep, disposition: .archiveOnly))
        #expect(store.storedRules()["news@x.example"] == shown)
    }

    @Test func aRefusedClearKeepsTheRule() throws {
        let store = try RefusingStore()
        defer { store.remove() }
        try RuleStore.set(.keep, for: "boss@x.example", in: store.writable)

        #expect(throws: RuleSaveError.self) {
            try RuleStore.clear(for: "boss@x.example", in: store.refusing)
        }
        #expect(RuleStore.all(in: store.refusing)["boss@x.example"] == .keep, "a keep rule must not look cleared when it is not")
        #expect(store.storedRules()["boss@x.example"]?.decision == .keep)
    }

    @Test func theErrorNamesTheSenderAndSaysNothingChanged() throws {
        let store = try RefusingStore()
        defer { store.remove() }
        do {
            try RuleStore.set(.sweep, for: "news@x.example", in: store.refusing)
            Issue.record("expected a RuleSaveError")
        } catch let error as RuleSaveError {
            #expect(error.address == "news@x.example")
            #expect(error.errorDescription?.contains("nothing changed") == true)
        }
    }

    @Test func aSavedEditReachesTheStore() throws {
        let store = try RefusingStore()
        defer { store.remove() }
        try RuleStore.setCustomFolder("Clients/VIP", for: "news@x.example", in: store.writable)

        let stored = store.storedRules()["news@x.example"]
        #expect(stored == SenderOverride(decision: .sweep, disposition: .fileIntoFolders, customFolder: "Clients/VIP"))
        try RuleStore.clear(for: "news@x.example", in: store.writable)
        #expect(store.storedRules().isEmpty)
    }
}
