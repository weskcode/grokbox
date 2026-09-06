import Foundation

/// Everything the reader pass needs to know about one message.
/// Built from headers plus a transient body excerpt; never persisted.
public struct ReadRequest: Sendable {
    public var subject: String
    public var senderName: String
    public var senderAddress: String
    public var senderIsKnownContact: Bool
    public var receivedAt: Date
    public var bodyExcerpt: String

    public init(subject: String, senderName: String, senderAddress: String,
                senderIsKnownContact: Bool, receivedAt: Date, bodyExcerpt: String) {
        self.subject = subject
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.senderIsKnownContact = senderIsKnownContact
        self.receivedAt = receivedAt
        self.bodyExcerpt = bodyExcerpt
    }

    /// The prompt body shared by every model backend.
    public var rendered: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return """
        From: \(senderName) <\(senderAddress)>\(senderIsKnownContact ? " (someone the reader has written to before)" : "")
        Date: \(formatter.string(from: receivedAt))
        Subject: \(subject)

        \(bodyExcerpt)
        """
    }
}

/// What the reader would have to do, if anything.
public enum ActionType: String, Codable, Sendable, CaseIterable {
    case reply, pay, attend, review, decide, none

    public var label: String {
        switch self {
        case .reply: "Reply"
        case .pay: "Pay"
        case .attend: "Attend"
        case .review: "Review"
        case .decide: "Decide"
        case .none: ""
        }
    }
}

public struct ReadResult: Sendable, Equatable {
    public var summary: String
    public var importance: Importance
    public var reason: String
    public var actionType: ActionType
    /// The deadline phrase as the model saw it ("by Friday", "the 28th"). Parsed later.
    public var dueHint: String?
    /// Can be dealt with in under two minutes.
    public var isQuick: Bool

    public init(summary: String, importance: Importance, reason: String,
                actionType: ActionType = .none, dueHint: String? = nil, isQuick: Bool = false) {
        self.summary = summary
        self.importance = importance
        self.reason = reason
        self.actionType = actionType
        self.dueHint = dueHint
        self.isQuick = isQuick
    }
}

public enum ModelAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }
}

/// A local text model that can read one email and say what it is.
///
/// Every conforming type runs on this machine. There is no remote option and
/// there will not be one — see docs/PRIVACY.md.
public protocol TextModel: Sendable {
    var name: String { get }
    func availability() async -> ModelAvailability
    func read(_ request: ReadRequest) async throws -> ReadResult
    func categorize(_ request: CategorizeRequest) async throws -> CategorizeResult
}

/// A sender the heuristics could not place, with enough context to decide.
public struct CategorizeRequest: Sendable {
    public var displayName: String
    public var address: String
    public var sampleSubjects: [String]
    public var messageCount: Int
    public var unreadRatio: Double
    public var hasUnsubscribeLink: Bool

    public init(displayName: String, address: String, sampleSubjects: [String], messageCount: Int, unreadRatio: Double, hasUnsubscribeLink: Bool) {
        self.displayName = displayName
        self.address = address
        self.sampleSubjects = sampleSubjects
        self.messageCount = messageCount
        self.unreadRatio = unreadRatio
        self.hasUnsubscribeLink = hasUnsubscribeLink
    }

    public var rendered: String {
        """
        Sender: \(displayName) <\(address)>
        Messages: \(messageCount), \(Int(unreadRatio * 100))% never opened, \(hasUnsubscribeLink ? "has" : "no") unsubscribe link
        Recent subjects:
        \(sampleSubjects.map { "- " + $0 }.joined(separator: "\n"))
        """
    }
}

public struct CategorizeResult: Sendable, Equatable {
    public var category: SenderCategory
    public var reason: String

    public init(category: SenderCategory, reason: String) {
        self.category = category
        self.reason = reason
    }
}

/// The instructions every backend is given. Kept in one place so the two
/// models are asked the same question.
public enum ReaderPrompt {
    public static let instructions = """
    You triage email for a busy reader with ADHD. For each message, decide \
    whether the reader personally has to DO something.

    summary: one plain sentence, under 20 words, describing what the message \
    says. Start with the sender's name from the From line (a person's first \
    name, or the company). Example: "Alice asks if you are free for lunch \
    Friday and wants an answer by Thursday." Never write "someone" or "the \
    sender", and never include a category name, a label, or an instruction to \
    the reader.

    importance:
    - needsYou: the reader must reply, pay, sign, attend, confirm, review, or \
    decide, and the message asks for it. A person is waiting, or money or a \
    deadline is involved.
    - worthKnowing: real information for the reader, but nothing is asked of \
    them: receipts, confirmations, results being available, reminders of things \
    already scheduled, status updates from people they know.
    - noise: marketing, promotions, newsletters, digests, social notifications, \
    and automated activity feeds.

    Examples:
    "Your bill is $142, due on the 28th" → needsYou
    "Could you review my PR? It is blocking the release" → needsYou
    "Thanks for your payment; next billing date is next month" → worthKnowing
    "Reminder: standup starts in 10 minutes" → worthKnowing
    "Your order has shipped and arrives in 2 days" → worthKnowing
    "You have 7 unread messages in #engineering" → noise
    "50% off everything, today only" → noise

    reason: under 8 words, e.g. "Asks for a reply by Thursday".

    action: what the reader would have to do — reply, pay, attend, review, \
    decide, or none. Use none for worthKnowing and noise.

    due: the deadline phrase exactly as written in the message ("by Friday", \
    "the 28th", "in 5 days", "EOD"), or empty if there is none. Never invent one.

    quick: true if the action takes under two minutes — a yes/no reply, \
    confirming attendance, accepting an invitation, paying a known bill. false \
    for reviews, documents, decisions that need thought, or no action.
    """

    public static let categorizeInstructions = """
    Classify an email sender by what they are, using only the evidence given.

    - person: an individual human writing to the reader.
    - transactional: receipts, bills, statements, orders, shipping, appointments, \
    account security — records the reader may need later.
    - notification: automated activity from an app or service (task trackers, \
    calendars, chat digests, social "liked your post").
    - newsletter: editorial content sent on a schedule — articles, digests, issues.
    - promotion: marketing, sales, offers, discounts.

    reason: under 8 words. If truly unsure between two, pick the one whose \
    folder the reader would rather find the mail in.
    """

    /// Small models sometimes echo label names or the schema into prose.
    /// Strip the usual leakage before it reaches the screen.
    public static func sanitize(_ summary: String) -> String {
        var text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let leaks = ["needsYou", "NeedsYou", "worthKnowing", "WorthKnowing", "Noise.", "noise.",
                     "(Action needed.)", "(Action needed)", "Action needed.", "respond in JSON", "Respond in JSON",
                     "Importance:", "Summary:"]
        for leak in leaks {
            text = text.replacingOccurrences(of: leak, with: "")
        }
        text = text.replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: " .", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:;,"))
        if let first = text.first, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        if !text.isEmpty, !".!?".contains(text.last!) { text += "." }
        return text
    }
}

/// Picks the best backend available on this Mac.
public enum ModelRegistry {
    /// Preference order: Apple's on-device model first (no install, no daemon),
    /// then a local Ollama if one is running.
    public static func candidates() -> [any TextModel] {
        var models: [any TextModel] = []
        if #available(macOS 26.0, *) {
            models.append(FoundationModelsProvider())
        }
        models.append(OllamaProvider())
        return models
    }

    public static func firstAvailable() async -> (any TextModel)? {
        for model in candidates() where await probe(model).isAvailable {
            return model
        }
        return nil
    }

    /// `availability()` with a deadline. A wedged system service must never
    /// hold up app startup; after `limit` the backend is reported unavailable.
    public static func probe(_ model: any TextModel, limit: Duration = .seconds(8)) async -> ModelAvailability {
        // Detached on both sides so neither racer can inherit — and be stuck
        // behind — the caller's actor.
        let probe = Task.detached(priority: .utility) { await model.availability() }
        let clock = Task.detached(priority: .utility) { () -> ModelAvailability in
            try? await Task.sleep(for: limit)
            return .unavailable(reason: "\(model.name) did not answer within \(limit.components.seconds) seconds.")
        }
        return await withTaskGroup(of: ModelAvailability.self) { group in
            group.addTask { await probe.value }
            group.addTask { await clock.value }
            let first = await group.next() ?? .unavailable(reason: "No answer.")
            probe.cancel(); clock.cancel()
            group.cancelAll()
            return first
        }
    }
}
