import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

/// A model that is "available" and then fails on every message — what a
/// broken on-device model looks like from the outside.
actor BrokenModel: TextModel {
    nonisolated let name = "Broken"
    struct Failure: Error, LocalizedError { var errorDescription: String? { "model exploded" } }
    func availability() async -> ModelAvailability { .available }
    func read(_ request: ReadRequest) async throws -> ReadResult { throw Failure() }
    func categorize(_ request: CategorizeRequest) async throws -> CategorizeResult { throw Failure() }
}

@MainActor
@Suite(.serialized)
struct MaintainerFailureTests {
    /// Regression: a model failing on every message used to surface as
    /// "nothing new to read", which is the opposite of what happened.
    @Test func brokenModelIsReportedNotHidden() async throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let mailbox = DemoMailbox(persona: .personal)
        let account = MailAccount(displayName: "Demo", username: mailbox.username, host: "127.0.0.1", port: 0, kind: .demo, security: .none)
        context.insert(account); try context.save()
        DemoRegistry.shared.register(mailbox, for: account.id)
        defer { DemoRegistry.shared.remove(account.id) }

        let engine = SyncEngine(modelContext: context)
        let executor = PlanExecutor(modelContext: context)
        let maintainer = Maintainer(modelContext: context, engine: engine, executor: executor)
        await maintainer.run(accounts: [account], model: BrokenModel(), settings: .defaults)

        guard case .failed(let text) = maintainer.phase else {
            Issue.record("expected a failure, got \(maintainer.phase.label)"); return
        }
        #expect(text.localizedCaseInsensitiveContains("reading failed"))
        #expect(text.contains("model exploded"))
        #expect(!text.localizedCaseInsensitiveContains("nothing new to read"))
    }
}
