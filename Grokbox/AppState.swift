import Foundation
import AppKit
import SwiftData
import UserNotifications
import GrokboxCore

/// The long-lived engines, created once per launch and shared by every view.
@MainActor
@Observable
final class AppState {
    let engine: SyncEngine
    let executor: PlanExecutor
    let maintainer: Maintainer
    private let context: ModelContext

    /// Set once at launch if the index had to be rebuilt or cannot be written.
    /// Shown as a banner until dismissed — silently losing someone's index and
    /// saying nothing would be the worst possible behaviour here.
    var storeRecovery: String?

    /// A menu-bar command waiting for the root view to act on it. Menus have
    /// no idea which account is selected; the root view does, so it consumes
    /// this and clears it.
    var pendingCommand: AppCommand?

    /// Replaces a stored password after proving it works. The account record
    /// and its history are untouched; only the Keychain item changes.
    func updatePassword(for account: MailAccount, password: String) async throws {
        let clean = account.kind == .gmail ? password.replacingOccurrences(of: " ", with: "") : password
        let provider = try await IMAPMailProvider.connect(
            host: account.host, port: account.port, security: account.security,
            username: account.username, password: clean)
        _ = try await provider.discoverMailboxes()
        await provider.finish()
        try KeychainStore.save(password: clean, for: account.keychainAccount)
        account.lastSyncError = nil
        try context.save()
        Log.note("password updated for \(account.displayName)")
    }

    /// Set by the root view when it appears. The menu-bar label uses it to open
    /// the main window if SwiftUI declined to at launch.
    var mainWindowSeen = false

    /// Whether the status-bar item is inserted.
    ///
    /// Deliberately NOT an `@AppStorage` binding in the App: `MenuBarExtra`
    /// echoes its insertion state back through the binding, an `@AppStorage`
    /// write invalidates the App body, the scene rebuilds and echoes again —
    /// a measured 100%-of-one-core infinite loop (ADR-0017). The no-op guards
    /// here and in `GrokboxApp.menuBarInsertion` are what break the cycle.
    var showMenuBar: Bool = UserDefaults.standard.object(forKey: "grokbox.showMenuBar") as? Bool ?? true {
        didSet {
            guard oldValue != showMenuBar else { return }
            UserDefaults.standard.set(showMenuBar, forKey: "grokbox.showMenuBar")
        }
    }

    /// The model currently chosen for reading, if any is available.
    private(set) var model: (any TextModel)?
    private(set) var modelStatuses: [(name: String, availability: ModelAvailability)] = []


    init(context: ModelContext) {
        self.context = context
        engine = SyncEngine(modelContext: context)
        executor = PlanExecutor(modelContext: context)
        maintainer = Maintainer(modelContext: context, engine: engine, executor: executor)
        maintainer.onFinished = { [weak self] summary in
            self?.notifyIfWorthwhile(summary: summary)
        }
    }

    var isBusy: Bool {
        engine.phase.isRunning || executor.phase.isRunning || maintainer.phase.isRunning
    }

    // MARK: - Startup

    private var allAccounts: [MailAccount] {
        (try? context.fetch(FetchDescriptor<MailAccount>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// Demo servers, model probe, the maintenance loop, then any launch flags.
    /// Idempotent and window-independent, so scripted runs work headless.
    ///
    /// Runs inline in the first caller rather than in a spawned Task: an
    /// unstructured Task created from a MenuBarExtra label's `.task` was
    /// observed never to be scheduled on macOS 27, which left every later
    /// caller waiting forever.
    private var isStarting = false
    private var hasStarted = false
    private var modelProbe: Task<Void, Never>?

    func startIfNeeded() async {
        Log.note("startIfNeeded called; started=\(hasStarted) starting=\(isStarting)")
        if hasStarted { return }
        if isStarting {
            while !hasStarted { try? await Task.sleep(for: .milliseconds(100)) }
            return
        }
        isStarting = true
        Log.note("starting")
        let accounts = allAccounts
        Log.note("step: \(accounts.count) accounts fetched")
        await ensureDemoServers(for: accounts)
        startMaintenanceLoop(accounts: { [weak self] in self?.allAccounts ?? [] })
        hasStarted = true
        Log.note("start finished; probing models in the background")
        // Model probes are bounded but can still take seconds; nothing in
        // startup should wait on them. Launch flags that need a model await
        // this task themselves.
        modelProbe = Task { @MainActor in await self.refreshModels() }
        await applyLaunchOptions()
    }

    /// Honors `--reset --demo --run-all --demo-sweep --demo-undo --catch-up --selftest`.
    private func applyLaunchOptions() async {
        let options = LaunchOptions.current
        if options.reset {
            eraseEverything()
            Log.note("reset — all local data erased")
        }
        if options.addDemo { await addDemoAccounts() }
        let accounts = allAccounts
        if options.runAll || options.catchUp {
            await modelProbe?.value
            Log.note("model for this run: \(model?.name ?? "none")")
        }
        if options.runAll {
            Log.note("run-all starting for \(accounts.count) account(s), model=\(model?.name ?? "none")")
            await maintainer.run(accounts: accounts, model: model, settings: .load())
            Log.note("run-all finished — \(maintainer.phase.label)")
        }
        if options.demoSweep {
            // Demo accounts only: applying a plan unattended on a real mailbox is
            // exactly what this app promises never to do.
            for account in accounts where account.kind.isDemo {
                let assessed = SenderProfileBuilder.assessments(for: account, in: context)
                let plan = CleanupPlan.suggested(from: assessed, rules: RuleStore.all(in: context))
                await executor.apply(plan, to: account)
                Log.note("demo-sweep \(account.displayName) — \(executor.phase.label)")
            }
            refreshDigest(accounts)
        }
        if options.demoUndo {
            for account in accounts where account.kind.isDemo {
                let id = account.id
                var descriptor = FetchDescriptor<CleanupAction>(predicate: #Predicate { $0.accountID == id && $0.kindRaw == "archive" && $0.undoneAt == nil },
                                                                sortBy: [SortDescriptor(\.performedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                if let action = try? context.fetch(descriptor).first {
                    await executor.undo(action, on: account)
                    Log.note("demo-undo \(account.displayName) \(action.senderName) — \(executor.phase.label)")
                }
            }
            refreshDigest(accounts)
        }
        if options.catchUp {
            await readAll(accounts, scope: .catchUp(days: 365))
            Log.note("catch-up finished — \(engine.phase.label)")
        }
        if options.selftest {
            await selfTest()
        }
    }

    /// Exercises, from inside the sandbox, exactly what a real account needs:
    /// a Keychain round trip and a TLS connection to a real IMAP host.
    private func selfTest() async {
        let key = "selftest@grokbox.local:0"
        do {
            try KeychainStore.save(password: "s3cret", for: key)
            let back = try KeychainStore.password(for: key)
            try KeychainStore.delete(account: key)
            Log.note("selftest keychain — \(back == "s3cret" ? "OK" : "MISMATCH")")
        } catch {
            Log.note("selftest keychain — FAILED \(error.localizedDescription)")
        }
        let client = IMAPClient()
        do {
            try await client.connect(host: "imap.gmail.com", port: 993, security: .tls)
            let caps = try await client.preLoginCapabilities()
            await client.logout()
            Log.note("selftest tls — OK, \(caps.count) capabilities, IMAP4REV1=\(caps.contains("IMAP4REV1"))")
        } catch {
            Log.note("selftest tls — FAILED \(error.localizedDescription)")
        }
    }

    // MARK: - Models

    /// Re-probes every backend. Honors the user's preferred backend when it is
    /// available; otherwise takes the first that is.
    func refreshModels() async {
        var candidates = ModelRegistry.candidates()
        let ollamaModel = UserDefaults.standard.string(forKey: "grokbox.ollamaModel") ?? OllamaProvider.defaultModel
        candidates = candidates.map { $0 is OllamaProvider ? OllamaProvider(model: ollamaModel) : $0 }

        var statuses: [(String, ModelAvailability)] = []
        for candidate in candidates {
            let availability = await ModelRegistry.probe(candidate)
            Log.note("probed \(candidate.name): \(availability.isAvailable ? "available" : "unavailable")")
            statuses.append((candidate.name, availability))
        }
        modelStatuses = statuses

        let preferred = UserDefaults.standard.string(forKey: "grokbox.preferredModel")
        let available = zip(candidates, statuses).filter { $0.1.1.isAvailable }.map(\.0)
        model = available.first { $0.name == preferred } ?? available.first
    }

    // MARK: - Demo accounts

    /// Builds the in-process mailbox behind every demo account. No sockets:
    /// the demo runs entirely inside the app's own process.
    func ensureDemoServers(for accounts: [MailAccount]) async {
        for account in accounts where account.kind.isDemo {
            guard DemoRegistry.shared.mailbox(for: account.id) == nil,
                  let persona = DemoPersona.from(username: account.username) else { continue }
            DemoRegistry.shared.register(DemoMailbox(persona: persona), for: account.id)
            account.lastSyncError = nil
        }
        try? context.save()
    }

    /// Creates the three sample mailboxes (skipping any that already exist).
    @discardableResult
    func addDemoAccounts() async -> [MailAccount] {
        let existing = Set(((try? context.fetch(FetchDescriptor<MailAccount>())) ?? []).map(\.username))
        var created: [MailAccount] = []
        for persona in DemoPersona.allCases where !existing.contains(persona.username) {
            let account = MailAccount(
                displayName: persona.displayName,
                username: persona.username,
                host: AccountKind.demo.defaultHost,
                port: 0,
                kind: .demo,
                security: .none
            )
            context.insert(account)
            created.append(account)
        }
        try? context.save()
        await ensureDemoServers(for: created)
        return created
    }

    func stopDemoServer(for account: MailAccount) {
        DemoRegistry.shared.remove(account.id)
    }

    // MARK: - Maintenance

    func startMaintenanceLoop(accounts: @escaping @MainActor () -> [MailAccount]) {
        maintainer.startLoop(
            accounts: accounts,
            model: { [weak self] in
                await self?.refreshModels()
                return self?.model
            },
            settings: { Maintainer.Settings.load() }
        )
    }

    /// Reads new mail for several accounts in sequence (the all-accounts Brief).
    func readAll(_ accounts: [MailAccount], scope: SyncEngine.ReadScope = .recent) async {
        guard let model else { return }
        let limit = Maintainer.Settings.load().readLimit
        for account in accounts {
            await engine.readNow(account: account, model: model, limit: limit, scope: scope)
        }
        _ = try? DigestBuilder.build(for: accounts, in: context)
    }

    /// Tidy up and refresh the cross-account summary; what the menu bar calls.
    func tidyUp(_ accounts: [MailAccount]) async {
        await maintainer.run(accounts: accounts, model: model, settings: .load())
        _ = try? DigestBuilder.build(for: accounts, in: context)
    }

    func refreshDigest(_ accounts: [MailAccount]) {
        _ = try? DigestBuilder.build(for: accounts, in: context)
    }

    // MARK: - Notifications

    private func notifyIfWorthwhile(summary: String) {
        guard UserDefaults.standard.bool(forKey: "grokbox.notify") else { return }
        let waiting = #Predicate<MessageHeader> { $0.briefRank == 2 && $0.isUnread == true && $0.isSweptLocally == false }
        let needsYou = (try? context.fetchCount(FetchDescriptor<MessageHeader>(predicate: waiting))) ?? 0
        NotificationService.post(
            title: needsYou > 0 ? "\(needsYou) thing\(needsYou == 1 ? "" : "s") need you" : "Inbox tidied",
            body: summary
        )
    }

    // MARK: - Reset

    /// Removes an account and everything indexed from it. Cascade is manual
    /// because messages reference accounts by id, not by relationship.
    func remove(_ account: MailAccount) {
        let id = account.id
        try? KeychainStore.delete(account: account.keychainAccount)
        stopDemoServer(for: account)
        let messages = #Predicate<MessageHeader> { $0.accountID == id }
        let profiles = #Predicate<SenderProfile> { $0.accountID == id }
        let snapshots = #Predicate<MailboxSnapshot> { $0.accountID == id }
        let actions = #Predicate<CleanupAction> { $0.accountID == id }
        try? context.delete(model: MessageHeader.self, where: messages)
        try? context.delete(model: SenderProfile.self, where: profiles)
        try? context.delete(model: MailboxSnapshot.self, where: snapshots)
        try? context.delete(model: CleanupAction.self, where: actions)
        context.delete(account)
        try? context.save()
    }

    /// Wipes every local record and Keychain item. The mailbox itself is untouched.
    func eraseEverything() {
        for account in (try? context.fetch(FetchDescriptor<MailAccount>())) ?? [] {
            try? KeychainStore.delete(account: account.keychainAccount)
            stopDemoServer(for: account)
            context.delete(account)
        }
        let everything = #Predicate<MessageHeader> { _ in true }
        let allProfiles = #Predicate<SenderProfile> { _ in true }
        let allDigests = #Predicate<InboxDigest> { _ in true }
        try? context.delete(model: MessageHeader.self, where: everything)
        try? context.delete(model: SenderProfile.self, where: allProfiles)
        try? context.delete(model: InboxDigest.self, where: allDigests)
        for rule in (try? context.fetch(FetchDescriptor<SenderRule>())) ?? [] { context.delete(rule) }
        for contact in (try? context.fetch(FetchDescriptor<ContactedAddress>())) ?? [] { context.delete(contact) }
        for action in (try? context.fetch(FetchDescriptor<CleanupAction>())) ?? [] { context.delete(action) }
        for snapshot in (try? context.fetch(FetchDescriptor<MailboxSnapshot>())) ?? [] { context.delete(snapshot) }
        try? context.save()
    }
}

/// Local notifications only. Nothing here talks to a push service.
enum NotificationService {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}


/// Everything the Mailbox menu can ask for.
enum AppCommand: Equatable {
    case readNewMail, tidyUp, index, summarize, stop, settings, addAccount
}
