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

        /// Reads cost ~10 s each on-device with structured output; 25 keeps a pass under five minutes.
        public static let defaults = Settings(isAutoEnabled: false, intervalMinutes: 30, readLimit: 25, indexDepth: 1_000)

        public init(isAutoEnabled: Bool, intervalMinutes: Int, readLimit: Int, indexDepth: Int) {
            self.isAutoEnabled = isAutoEnabled
            self.intervalMinutes = intervalMinutes
            self.readLimit = readLimit
            self.indexDepth = indexDepth
        }

        public static func load(from defaults: UserDefaults = .standard) -> Settings {
            Settings(
                isAutoEnabled: defaults.bool(forKey: "grokbox.autoMaintain"),
                intervalMinutes: max(5, defaults.integer(forKey: "grokbox.autoIntervalMinutes").nonZero ?? Settings.defaults.intervalMinutes),
                readLimit: defaults.integer(forKey: "grokbox.readLimit").nonZero ?? Settings.defaults.readLimit,
                indexDepth: defaults.integer(forKey: "grokbox.indexDepth").nonZero ?? Settings.defaults.indexDepth
            )
        }
    }

    public private(set) var phase: Phase = .idle
    private var runTask: Task<Void, Never>?

    /// Stops the pass that is running and the engines underneath it.
    public func cancel() {
        runTask?.cancel()
        runTask = nil
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

    public func run(accounts: [MailAccount], model: (any TextModel)?, settings: Settings) async {
        guard !phase.isRunning, !engine.phase.isRunning, !executor.phase.isRunning else { return }

        var sweptMessages = 0
        var readMessages = 0
        var readFailures: [String] = []

        for account in accounts {
            phase = .indexing
            await engine.indexNow(account: account, mode: .incremental(fallbackLimit: settings.indexDepth))
            if case .failed(let message) = engine.phase {
                phase = .failed("\(account.displayName): \(message)")
                return
            }

            phase = .sweeping
            let plan = rulesPlan(for: account)
            if !plan.isEmpty {
                await executor.apply(plan, to: account, recordRules: false)
                sweptMessages += plan.enabledMessageCount
            }

            if let model {
                phase = .reading
                await engine.readNow(account: account, model: model, limit: settings.readLimit)
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
        if !readFailures.isEmpty {
            text += ". Reading failed — " + readFailures.joined(separator: "; ")
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

    private func rulesPlan(for account: MailAccount) -> CleanupPlan {
        CleanupPlan.fromRules(SenderProfileBuilder.assessments(for: account, in: modelContext), rules: RuleStore.all(in: modelContext))
    }

    // MARK: - Timer loop

    /// Starts the periodic loop. The closures are evaluated each tick so account
    /// and model changes in the app are picked up without a restart.
    public func startLoop(
        accounts: @escaping @MainActor () -> [MailAccount],
        model: @escaping @MainActor () async -> (any TextModel)?,
        settings: @escaping @MainActor () -> Settings
    ) {
        stopLoop()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                let current = settings()
                guard current.isAutoEnabled else {
                    self?.nextRunAt = nil
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
                let interval = Duration.seconds(current.intervalMinutes * 60)
                self?.nextRunAt = Date().addingTimeInterval(TimeInterval(current.intervalMinutes * 60))
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.run(accounts: accounts(), model: await model(), settings: settings())
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
