import Foundation
import Testing
import SwiftData
import Synchronization
@testable import GrokboxCore

private actor Calls {
    private(set) var count = 0
    func hit() { count += 1 }
}

private struct Sentinel: Error {}

/// Counts every request a session is asked to make, and fails each one.
private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    static let seen = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.withLock { $0 += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
    override func stopLoading() {}
}

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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        RecordingURLProtocol.seen.withLock { $0 = 0 }
        await demoOnly {
            await #expect(throws: LaunchIsolation.Refusal.self) {
                _ = try await AutoconfigService.discover(email: "someone@example.com", session: session, verifyGuess: false)
            }
        }
        #expect(RecordingURLProtocol.seen.withLock { $0 } == 0, "no request was created")

        // Control: outside isolation the same call does create requests.
        _ = try? await AutoconfigService.discover(email: "someone@example.com", session: session, verifyGuess: false)
        #expect(RecordingURLProtocol.seen.withLock { $0 } >= 1)
    }

    @Test func modelBackendsMakeNoRequestInIsolation() async {
        // Loopback base URLs, so a missing guard could not reach anything real.
        let ollama = OllamaProvider(baseURL: URL(string: "http://127.0.0.1:1")!)
        let jev = JevCategorizer(apiKey: "not-a-key", baseURL: URL(string: "http://127.0.0.1:1")!)
        let read = ReadRequest(subject: "Hello", senderName: "A", senderAddress: "a@example.com",
                               senderIsKnownContact: false, receivedAt: .now, bodyExcerpt: "")
        let categorize = CategorizeRequest(displayName: "A", address: "a@example.com", sampleSubjects: ["Hello"],
                                           messageCount: 3, unreadRatio: 1, hasUnsubscribeLink: false)
        await demoOnly {
            guard case .unavailable(let why) = await ollama.availability(), why.contains("Demo-only") else {
                Issue.record("Ollama was probed in isolation"); return
            }
            await #expect(throws: LaunchIsolation.Refusal.self) { _ = try await ollama.read(read) }
            await #expect(throws: LaunchIsolation.Refusal.self) { _ = try await ollama.categorize(categorize) }
            await #expect(throws: LaunchIsolation.Refusal.self) { _ = try await jev.categorize(categorize) }
            let onDevice = FoundationModelsProvider()
            guard case .unavailable(let onDeviceWhy) = await onDevice.availability(), onDeviceWhy.contains("Demo-only") else {
                Issue.record("the on-device model was probed in isolation"); return
            }
            await #expect(throws: LaunchIsolation.Refusal.self) { _ = try await onDevice.read(read) }
            await #expect(throws: LaunchIsolation.Refusal.self) { _ = try await onDevice.categorize(categorize) }
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

        // A sender with no one-click support would normally be handed to the
        // browser; in isolation nothing is offered either.
        var manual = cluster()
        manual.supportsOneClickUnsubscribe = false
        let browser = await demoOnly { await UnsubscribeService.unsubscribe(from: manual) }
        guard case .failed = browser else { Issue.record("expected a refusal, got \(browser)"); return }

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

    /// A value seeded into the real (standard) persistent domain is neither read
    /// nor overwritten in demo-only mode. `grokbox.readLimit` is read only by
    /// `Maintainer.Settings.load()` in the app, so no other test sees the seed.
    /// The argument domain cannot be set from inside a test; a launch passes
    /// none, and a suite would still search it, like the registration domain below.
    @Test func aValueInTheRealDefaultsIsNeitherReadNorOverwritten() async {
        let key = "grokbox.readLimit"
        let original = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(7_777, forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        await demoOnly {
            #expect(Maintainer.Settings.load().readLimit == Maintainer.Settings.defaults.readLimit, "the real value is not read")
            GrokboxDefaults.store.set(11, forKey: key)
            #expect(Maintainer.Settings.load().readLimit == 11)
            GrokboxDefaults.store.removeObject(forKey: key)
        }
        #expect(UserDefaults.standard.integer(forKey: key) == 7_777, "the real value was not written")
        #expect(Maintainer.Settings.load().readLimit == 7_777, "outside isolation nothing changes")
    }

    @Test func aFalseOverrideCannotClearTheProcessDecision() async {
        await LaunchIsolation.$override.withValue(false) {
            #expect(LaunchIsolation.isDemoOnly == LaunchIsolation.requested(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: CommandLine.arguments))
        }
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
            LaunchIsolation.attestation(bundleIdentifier: LaunchIsolation.isolatedBundleIdentifier, storeConfiguration: GrokboxStore.inMemoryConfiguration, logPath: "/tmp/x.log")
        }
        for expected in ["demoOnly=true", "bundleID=com.wesleykeetch.grokbox.isolation", "store=inMemory(groupContainer: none, cloudKit: none)",
                         "defaults=com.wesleykeetch.grokbox.isolated-demo", "keychain=refused", "mailServer=refused",
                         "unsubscribe=refused", "autoconfig=refused", "modelBackend=refused", "notifications=refused", "logSubsystem=com.wesleykeetch.grokbox.isolated-demo"] {
            #expect(isolated.contains(expected), "\(expected) in \(isolated)")
        }
        let normal = LaunchIsolation.attestation(bundleIdentifier: "com.wesleykeetch.grokbox", storeConfiguration: "disk", logPath: "/tmp/x.log")
        for expected in ["demoOnly=false", "store=disk", "defaults=standard", "keychain=open", "mailServer=open", "unsubscribe=open", "notifications=open"] {
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
