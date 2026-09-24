import Foundation
import SwiftData

/// Keeps the inbox clean after the first big sweep.
///
/// One pass = index what is new → apply the user's existing rules → read what
/// matters with the local model. It **never** invents a new sweep: senders the
/// user has not ruled on are left for the Sweep screen. Runs on demand, or on
/// a timer while the app is open.
@MainActor
@Observable
public final class Maintainer {
    public enum Phase: Equatable, Sendable {
        case idle
        case indexing
        case sweeping
        case reading
        case finished(String)
        case failed(String)

        public var isRunning: Bool {
            switch self {
            case .idle, .finished, .failed: false
            default: true
            }
        }

        public var label: String {
            switch self {
            case .idle: "Idle"
            case .indexing: "Checking for new mail…"
            case .sweeping: "Applying your rules…"
            case .reading: "Reading what matters…"
            case .finished(let message): message
            case .failed(let message): message
            }
        }
    }

    public struct Settings: Sendable {
        public var isAutoEnabled: Bool
        public var intervalMinutes: Int
        public var readLimit: Int
        public var indexDepth: Int
        /// With automatic tidy-up on, also run soon after new mail reaches an
        /// inbox (IMAP IDLE), not only on the timer.
        public var runsOnNewMail: Bool

        /// Reads cost ~10 s each on-device with structured output; 25 keeps a pass under five minutes.
        public static let defaults = Settings(isAutoEnabled: false, intervalMinutes: 30, readLimit: 25, indexDepth: 1_000)

        public init(isAutoEnabled: Bool, intervalMinutes: Int, readLimit: Int, indexDepth: Int, runsOnNewMail: Bool = true) {
            self.isAutoEnabled = isAutoEnabled
            self.intervalMinutes = intervalMinutes
            self.readLimit = readLimit
            self.indexDepth = indexDepth
            self.runsOnNewMail = runsOnNewMail
        }

        public static func load(from defaults: UserDefaults = .standard) -> Settings {
            Settings(
                isAutoEnabled: defaults.bool(forKey: "grokbox.autoMaintain"),
                intervalMinutes: max(5, defaults.integer(forKey: "grokbox.autoIntervalMinutes").nonZero ?? Settings.defaults.intervalMinutes),
                readLimit: defaults.integer(forKey: "grokbox.readLimit").nonZero ?? Settings.defaults.readLimit,
                indexDepth: defaults.integer(forKey: "grokbox.indexDepth").nonZero ?? Settings.defaults.indexDepth,
                runsOnNewMail: defaults.object(forKey: "grokbox.autoOnNewMail") as? Bool ?? true
            )
        }
    }

    public private(set) var phase: Phase = .idle
    /// Bumped by `cancel()`; a pass checks it between steps. Stopping the
    /// engines alone is not enough, because each step returns normally once
    /// its engine stops and the pass would carry on into the next one: a Stop
    /// during indexing would still apply the user's sweep rules.
    private var generation = 0

    /// Stops the pass that is running and the engines underneath it.
    public func cancel() {
        generation += 1
        engine.cancel()
        executor.cancel()
        phase = .idle
    }
    public private(set) var lastRunAt: Date?
    public private(set) var nextRunAt: Date?

    /// Called after every completed pass with its summary. The app uses it to
    /// post a notification when a timed run finds something.
    public var onFinished: (@MainActor (String) -> Void)?

    private let modelContext: ModelContext
    private let engine: SyncEngine
    private let executor: PlanExecutor
    private var loopTask: Task<Void, Never>?

    public init(modelContext: ModelContext, engine: SyncEngine, executor: PlanExecutor) {
        self.modelContext = modelContext
        self.engine = engine
        self.executor = executor
    }

    // MARK: - One pass

    public func run(accounts: [MailAccount], model: (any TextModel)?, settings: Settings,
                    policy: CleanupPolicy = .current) async {
        guard !phase.isRunning, !engine.phase.isRunning, !executor.phase.isRunning else { return }
        let token = generation
        let stopped = { Task.isCancelled || token != self.generation }
        // Ends a stopped pass. The phase is only touched if no newer pass has
        // started since.
        let end = { if token == self.generation { self.phase = .idle } }

        var sweptMessages = 0
        var readMessages = 0
        var readFailures: [String] = []
        var sweepFailures: [String] = []

        for account in accounts {
            guard !stopped() else { return end() }
            phase = .indexing
            await engine.indexNow(account: account, mode: .incremental(fallbackLimit: settings.indexDepth))
            // A run that ends idle was stopped, possibly by a Stop button that
            // only knows about the engine. Either way the pass ends here.
            guard !stopped(), engine.phase != .idle else { return end() }
            if case .failed(let message) = engine.phase {
                phase = .failed("\(account.displayName): \(message)")
                return
            }

            phase = .sweeping
            let plan = rulesPlan(for: account, policy: policy)
            if !plan.isEmpty {
                await executor.apply(plan, to: account, recordRules: false, policy: policy)
                guard !stopped(), !executor.lastOutcome.stopped else { return end() }
                // What the server confirmed, not what the plan asked for.
                sweptMessages += executor.lastOutcome.messages
                if case .failed(let why) = executor.phase {
                    sweepFailures.append("\(account.displayName): \(why)")
                }
            }

            if let model {
                phase = .reading
                await engine.readNow(account: account, model: model, limit: settings.readLimit)
                guard !stopped(), engine.phase != .idle else { return end() }
                switch engine.phase {
                case .finished(let message):
                    if let count = Int(message.split(separator: " ").dropFirst().first ?? "") { readMessages += count }
                case .failed(let why):
                    // A broken model must not be reported as "nothing new to read".
                    readFailures.append("\(account.displayName): \(why)")
                default:
                    break
                }
            }
        }

        lastRunAt = Date()
        var text = summary(swept: sweptMessages, read: readMessages, model: readFailures.isEmpty ? model : nil)
        if !sweepFailures.isEmpty {
            text += ". Sweeping failed: " + sweepFailures.joined(separator: "; ")
        }
        if !readFailures.isEmpty {
            text += ". Reading failed — " + readFailures.joined(separator: "; ")
        }
        if !sweepFailures.isEmpty || !readFailures.isEmpty {
            phase = .failed(text)
        } else {
            phase = .finished(text)
        }
        onFinished?(text)
    }

    private func summary(swept: Int, read: Int, model: (any TextModel)?) -> String {
        var parts: [String] = []
        parts.append(swept > 0 ? "swept \(swept)" : "nothing new to sweep")
        if model != nil { parts.append(read > 0 ? "read \(read)" : "nothing new to read") }
        return parts.joined(separator: ", ").capitalizedFirst
    }

    private func rulesPlan(for account: MailAccount, policy: CleanupPolicy) -> CleanupPlan {
        CleanupPlan.fromRules(SenderProfileBuilder.assessments(for: account, in: modelContext),
                              rules: RuleStore.all(in: modelContext), policy: policy,
                              overrides: RuleStore.overrides(in: modelContext))
    }

    // MARK: - Timer loop

    /// When new mail was first reported since the last pass. Nil when none is waiting.
    private var newMailAt: Date?

    /// New mail waits this long before a pass, so a burst is handled once.
    nonisolated static let arrivalSettle: TimeInterval = 20
    /// And a pass never follows the previous one sooner than this, which is
    /// also the shortest timer interval: push brings passes forward, it does
    /// not make them (or their notifications) more frequent than the timer can.
    nonisolated static let minimumSpacing: TimeInterval = 5 * 60

    /// An `InboxWatcher` saw new mail. Only acted on while automatic tidy-up
    /// is on and set to run on new mail.
    public func noteNewMail(at date: Date = Date()) {
        if newMailAt == nil { newMailAt = date }
    }

    nonisolated static func newMailIsDue(now: Date, newMailAt: Date?, lastRunAt: Date?) -> Bool {
        guard let newMailAt, now.timeIntervalSince(newMailAt) >= arrivalSettle else { return false }
        if let lastRunAt, now.timeIntervalSince(lastRunAt) < minimumSpacing { return false }
        return true
    }

    /// Starts the periodic loop. The closures are evaluated each tick so account
    /// and model changes in the app are picked up without a restart. A pass
    /// runs when the interval is up, or earlier once new mail has been
    /// reported and `newMailIsDue` agrees.
    public func startLoop(
        accounts: @escaping @MainActor () -> [MailAccount],
        model: @escaping @MainActor () async -> (any TextModel)?,
        settings: @escaping @MainActor () -> Settings
    ) {
        stopLoop()
        loopTask = Task { [weak self] in
            var due: Date?
            while !Task.isCancelled {
                guard let self else { return }
                let current = settings()
                guard current.isAutoEnabled else {
                    due = nil
                    self.nextRunAt = nil
                    self.newMailAt = nil
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
                let now = Date()
                let interval = TimeInterval(current.intervalMinutes * 60)
                // A shortened interval takes effect now rather than after the old one.
                if due.map({ $0 > now.addingTimeInterval(interval) }) ?? true { due = now.addingTimeInterval(interval) }
                self.nextRunAt = due
                if !current.runsOnNewMail { self.newMailAt = nil }
                let arrival = Self.newMailIsDue(now: now, newMailAt: self.newMailAt, lastRunAt: self.lastRunAt)
                if now >= (due ?? now) || arrival {
                    let previousRun = self.lastRunAt
                    let waiting = self.newMailAt
                    self.newMailAt = nil
                    await self.run(accounts: accounts(), model: await model(), settings: settings())
                    // Skipped because something else was running: keep the news for next tick.
                    if self.lastRunAt == previousRun, arrival { self.newMailAt = waiting }
                    due = Date().addingTimeInterval(interval)
                    continue
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    public func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
        nextRunAt = nil
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

private extension String {
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
