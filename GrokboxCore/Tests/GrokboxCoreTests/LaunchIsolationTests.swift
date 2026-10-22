import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

private actor Calls {
    private(set) var count = 0
    func hit() { count += 1 }
}

private struct Sentinel: Error {}

/// Runs `body` in demo-only mode for this task only, so tests running beside
/// it see the process as it really is.
@MainActor
private func demoOnly<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
    try await LaunchIsolation.$override.withValue(true) { try await body() }
}

struct LaunchIsolationPolicyTests {
    @Test func theSwitchAndTheIsolationBundleBothRequestIsolation() {
        #expect(LaunchIsolation.requested(bundleIdentifier: "com.wesleykeetch.grokbox.isolation", arguments: ["Grokbox"]))
        #expect(LaunchIsolation.requested(bundleIdentifier: "com.wesleykeetch.grokbox", arguments: ["Grokbox", "--isolated-demo"]))
        #expect(!LaunchIsolation.requested(bundleIdentifier: "com.wesleykeetch.grokbox", arguments: ["Grokbox", "--demo"]))
        #expect(!LaunchIsolation.requested(bundleIdentifier: nil, arguments: []))
    }

    @Test func outsideIsolationEveryArgumentIsKept() {
        let arguments = ["Grokbox", "--reset", "--demo", "--run-all", "--index", "25000", "--selftest"]
        #expect(LaunchIsolation.effectiveArguments(arguments, demoOnly: false) == arguments)
    }

    @Test func inIsolationTheFlagsThatReachRealDataAreDropped() {
        let arguments = ["Grokbox", "--reset", "--demo", "--run-all", "--index", "25000", "--read", "400",
                         "--catch-up", "--selftest", "--section", "sweep", "--demo-sweep", "--isolated-demo"]
        #expect(LaunchIsolation.effectiveArguments(arguments, demoOnly: true)
                == ["Grokbox", "--demo", "--section", "sweep", "--demo-sweep", "--isolated-demo", "--stub-model"])
    }

    @Test func isolationForcesTheDemoMailboxesAndTheRulesOnlyReader() {
        #expect(LaunchIsolation.effectiveArguments(["Grokbox"], demoOnly: true) == ["Grokbox", "--demo", "--stub-model"])
    }

    @Test func aFlagWithoutAValueDoesNotSwallowTheNextFlag() {
        #expect(LaunchIsolation.effectiveArguments(["Grokbox", "--index", "--demo"], demoOnly: true)
                == ["Grokbox", "--demo", "--stub-model"])
    }
}

@MainActor
@Suite(.serialized)
struct LaunchIsolationTests {
    // MARK: - Keychain

    private func expectIsolated(_ body: () throws -> Void, _ surface: String) {
        do {
            try body()
            Issue.record("\(surface) was not refused")
        } catch let error as KeychainStore.KeychainError {
            if case .isolated = error { return }
            Issue.record("\(surface) threw \(error) instead of .isolated")
        } catch {
            Issue.record("\(surface) threw \(error)")
        }
    }

    @Test func theKeychainRefusesBeforeTouchingAnything() async {
        await demoOnly {
            // Throwaway account names: if a guard were missing these calls would
            // reach the real Keychain, but never an item the app owns.
            let account = "isolation-test-\(UUID().uuidString)"
            expectIsolated({ _ = try KeychainStore.password(for: account) }, "KeychainStore.password")
            expectIsolated({ try KeychainStore.save(password: "x", for: account) }, "KeychainStore.save")
            expectIsolated({ try KeychainStore.delete(account: account) }, "KeychainStore.delete")
            expectIsolated({ _ = try JevKeyStore.apiKey() }, "JevKeyStore.apiKey")
        }
    }

    // MARK: - Network boundary

    private func demoAccount() -> MailAccount {
        MailAccount(displayName: "Demo", username: "nobody@demo.example", host: "127.0.0.1", port: 0, kind: .demo, security: .none)
    }

    @Test func noMailServerConnectionIsMadeInIsolation() async throws {
        await demoOnly {
            await #expect(throws: LaunchIsolation.Refusal.self) {
                try await IMAPClient().connect(host: "127.0.0.1", port: 1, security: .none)
            }
            await #expect(throws: LaunchIsolation.Refusal.self) {
                _ = try await IMAPMailProvider.connect(host: "127.0.0.1", port: 1, security: .none, username: "u", password: "p")
            }
            await #expect(throws: LaunchIsolation.Refusal.self) {
                _ = try await IMAPMailProvider.connect(to: demoAccount())
            }
        }
    }

    @Test func aDemoAccountWithoutAMailboxDoesNotFallBackToIMAP() async throws {
        let calls = Calls()
        let account = demoAccount()
        await demoOnly {
            await #expect(throws: LaunchIsolation.Refusal.self) {
                _ = try await MailProviderFactory.connect(to: account) { _ in await calls.hit(); throw Sentinel() }
            }
        }
        #expect(await calls.count == 0, "the IMAP connector was never called")

        // Outside isolation the same account still falls back, so the seam is real.
        await #expect(throws: Sentinel.self) {
            _ = try await MailProviderFactory.connect(to: account) { _ in await calls.hit(); throw Sentinel() }
        }
        #expect(await calls.count == 1)
    }

    @Test func aRealAccountIsRefusedBeforeTheConnectorIsCalled() async throws {
        let calls = Calls()
        let real = MailAccount(displayName: "Real", username: "me@example.com", host: "imap.example.com", port: 993, kind: .generic, security: .tls)
        await demoOnly {
            await #expect(throws: LaunchIsolation.Refusal.self) {
                _ = try await MailProviderFactory.connect(to: real) { _ in await calls.hit(); throw Sentinel() }
            }
        }
        #expect(await calls.count == 0)
    }

    @Test func aRegisteredDemoMailboxIsServedWithoutTheConnector() async throws {
        let calls = Calls()
        let account = demoAccount()
        DemoRegistry.shared.register(DemoMailbox(persona: .personal), for: account.id)
        defer { DemoRegistry.shared.remove(account.id) }
        try await demoOnly {
            _ = try await MailProviderFactory.connect(to: account) { _ in await calls.hit(); throw Sentinel() }
        }
        #expect(await calls.count == 0)
    }

    @Test func autoconfigurationMakesNoRequestInIsolation() async {
        await demoOnly {
            await #expect(throws: LaunchIsolation.Refusal.self) {
                _ = try await AutoconfigService.discover(email: "someone@example.com")
            }
        }
    }

    // MARK: - Unsubscribe

    private func cluster() -> SenderCluster {
        SenderCluster(address: "news@sender.example", displayName: "News", domain: "sender.example", mailbox: "INBOX",
                      uids: [1], unreadUIDs: [1], messageCount: 1, unreadCount: 1, flaggedCount: 0, sweptCount: 0,
                      newest: .now, oldest: .now, hasUnsubscribeLink: true,
                      unsubscribeValue: "<https://sender.example/unsub/abc>", supportsOneClickUnsubscribe: true,
                      everContacted: false, sampleSubjects: ["Hello"])
    }

    @Test func unsubscribeSendsNothingAndLooksNothingUpInIsolation() async {
        let lookups = Calls()
        let resolver = HostResolver { _ in await lookups.hit(); throw HostResolver.Failure(reason: "stub") }
        let url = URL(string: "https://sender.example/unsub/abc")!

        let refused = await demoOnly {
            await UnsubscribeService.performOneClick(to: url, allowingLoopbackForTests: false, resolver: resolver, timeout: .seconds(1))
        }
        guard case .failed(let why) = refused, why.contains("Nothing was sent") else {
            Issue.record("expected a refusal, got \(refused)"); return
        }
        #expect(await lookups.count == 0, "no name was resolved")

        let viaSender = await demoOnly { await UnsubscribeService.unsubscribe(from: cluster()) }
        guard case .failed(let reason) = viaSender, reason.contains("Nothing was sent") else {
            Issue.record("expected a refusal, got \(viaSender)"); return
        }

        // Control: outside isolation the same call does reach the resolver.
        _ = await UnsubscribeService.performOneClick(to: url, allowingLoopbackForTests: false, resolver: resolver, timeout: .seconds(1))
        #expect(await lookups.count == 1)
    }

    // MARK: - Defaults

    @Test func settingsAreKeptInTheIsolatedSuiteNotTheRealDefaults() async {
        let key = "grokbox.cleanupPolicy"
        let real = UserDefaults.standard.data(forKey: key)
        await demoOnly {
            #expect(GrokboxDefaults.store !== UserDefaults.standard)
            // Gentle is the default, so a missing repoint could not leave an
            // aggressive policy behind in the real defaults.
            CleanupPolicy.current = .gentle
            #expect(GrokboxDefaults.store.data(forKey: key) != nil)
            GrokboxDefaults.store.removeObject(forKey: key)
        }
        #expect(UserDefaults.standard.data(forKey: key) == real, "the real defaults were not written")
        #expect(GrokboxDefaults.store === UserDefaults.standard, "outside isolation nothing changes")
    }

    /// States which domains isolation does not exclude: a `UserDefaults` suite
    /// still searches the registration domain, so registered values show through.
    /// A unique key keeps this from touching anything the app reads.
    @Test func registeredDefaultsStillShowThroughTheSuite() async {
        let key = "grokbox.tests.registered.\(UUID().uuidString)"
        UserDefaults.standard.register(defaults: [key: "registered"])
        await demoOnly {
            #expect(GrokboxDefaults.store.string(forKey: key) == "registered")
        }
    }

    // MARK: - Attestation

    @Test func theAttestationReportsWhatIsRefused() async {
        let isolated = await demoOnly {
            LaunchIsolation.attestation(bundleIdentifier: LaunchIsolation.isolatedBundleIdentifier, storeInMemory: true, logPath: "/tmp/x.log")
        }
        for expected in ["demoOnly=true", "bundleID=com.wesleykeetch.grokbox.isolation", "store=inMemory(groupContainer: none, cloudKit: none)",
                         "defaults=com.wesleykeetch.grokbox.isolated-demo", "keychain=refused", "mailServer=refused",
                         "unsubscribe=refused", "autoconfig=refused", "logSubsystem=com.wesleykeetch.grokbox.isolated-demo"] {
            #expect(isolated.contains(expected), "\(expected) in \(isolated)")
        }
        let normal = LaunchIsolation.attestation(bundleIdentifier: "com.wesleykeetch.grokbox", storeInMemory: false, logPath: "/tmp/x.log")
        for expected in ["demoOnly=false", "store=disk", "defaults=standard", "keychain=open", "mailServer=open", "unsubscribe=open"] {
            #expect(normal.contains(expected), "\(expected) in \(normal)")
        }
    }

    // MARK: - Store and the demo flow

    @Test func theIsolatedStoreIsMemoryOnly() {
        let opened = GrokboxStore.open(inMemory: true)
        #expect(opened.isEphemeral)
        #expect(opened.recovery == nil)
    }

    /// Index, sweep and undo on the demo mailbox in demo-only mode: nothing in
    /// the flow needs the Keychain, a mail server or an unsubscribe request.
    @Test func theDemoFlowRunsEndToEndInIsolation() async throws {
        let opened = GrokboxStore.open(inMemory: true)
        let context = opened.container.mainContext
        let mailbox = DemoMailbox(persona: .personal)
        let account = MailAccount(displayName: "Demo", username: mailbox.username, host: "127.0.0.1", port: 0, kind: .demo, security: .none)
        context.insert(account); try context.save()
        DemoRegistry.shared.register(mailbox, for: account.id)
        defer { DemoRegistry.shared.remove(account.id) }

        try await demoOnly {
            let engine = SyncEngine(modelContext: context)
            await engine.indexNow(account: account, mode: .full(limit: 10_000))
            guard case .finished = engine.phase else { Issue.record("index: \(engine.phase.label)"); return }

            let plan = CleanupPlan.suggested(from: SenderProfileBuilder.assessments(for: account, in: context))
            try #require(!plan.enabledItems.isEmpty)
            let executor = PlanExecutor(modelContext: context)
            await executor.apply(plan, to: account)
            guard case .finished = executor.phase else { Issue.record("sweep: \(executor.phase.label)"); return }

            let actions = try context.fetch(FetchDescriptor<CleanupAction>())
            #expect(actions.allSatisfy { $0.kind != .unsubscribe }, "the saved policy in the isolated suite is Gentle: no unsubscribe")
            let undoable = try #require(actions.first { $0.isUndoable })
            await executor.undo(undoable, on: account)
            #expect(undoable.isUndone, "undo: \(executor.phase.label)")
        }
    }
}
