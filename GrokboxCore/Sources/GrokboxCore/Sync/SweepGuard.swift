import Foundation

/// The last check before anything is archived: message-level reasons to hold
/// a message out of a sender-level sweep.
///
/// Sender verdicts are right most of the time. The mail people regret losing
/// is the exception inside a bulk sender — the one receipt from a shop that
/// otherwise only sends promotions, the flagged newsletter issue, the message
/// the model said needs you. Those are held, named, and left in the inbox.
public enum SweepGuard {
    public struct Held: Sendable, Equatable {
        public var uid: UInt32
        public var reason: String
    }

    public struct Verdict: Sendable {
        public var allowed: [UInt32]
        public var held: [Held]

        /// "Held 3: 1 flagged, 2 look transactional"
        public var summary: String? {
            guard !held.isEmpty else { return nil }
            let counts = Dictionary(grouping: held, by: \.reason).mapValues(\.count)
            let parts = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { "\($0.value) \($0.key)" }
            return "Held \(held.count): " + parts.joined(separator: ", ")
        }
    }

    /// Subjects that usually mean "you may need this later". Matched case-
    /// insensitively as whole words or phrases.
    static let transactionalTerms: [String] = [
        "receipt", "invoice", "statement", "payment", "your order", "order #", "order confirmation",
        "shipped", "out for delivery", "delivered", "delivery attempted", "appointment", "reservation",
        "booking", "itinerary", "boarding pass", "ticket", "confirmation", "verification code",
        "security code", "one-time", "passcode", "password", "sign-in", "new device", "renewal",
        "lease", "contract", "tax", "refund", "test results", "prescription",
        "transaction", "alert", "security", "sign in", "your account", "two-factor", "2fa"
    ]

    public struct MessageFacts: Sendable {
        public var uid: UInt32
        public var subject: String
        public var isFlagged: Bool
        public var importance: Importance?
        public var receivedAt: Date

        public init(uid: UInt32, subject: String, isFlagged: Bool, importance: Importance?, receivedAt: Date = .distantPast) {
            self.uid = uid
            self.subject = subject
            self.isFlagged = isFlagged
            self.importance = importance
            self.receivedAt = receivedAt
        }
    }

    /// The whole check, under a policy. Order matters only for the *reason*
    /// reported; a message held for any reason is held.
    public static func check(_ facts: [MessageFacts], policy: CleanupPolicy, now: Date = Date()) -> Verdict {
        // "Keep the newest N from this sender" is decided across the set, so
        // work it out before walking the messages.
        let keepNewest: Set<UInt32> = policy.keepNewestPerSender > 0
            ? Set(facts.sorted { $0.receivedAt > $1.receivedAt }.prefix(policy.keepNewestPerSender).map(\.uid))
            : []
        let recentCutoff: Date? = policy.protectRecentDays > 0
            ? Calendar.current.date(byAdding: .day, value: -policy.protectRecentDays, to: now)
            : nil

        var allowed: [UInt32] = []
        var held: [Held] = []
        for fact in facts {
            if fact.isFlagged {
                held.append(Held(uid: fact.uid, reason: "flagged"))
            } else if fact.importance == .needsYou {
                held.append(Held(uid: fact.uid, reason: "need you"))
            } else if let cutoff = recentCutoff, fact.receivedAt > cutoff {
                held.append(Held(uid: fact.uid, reason: "too recent"))
            } else if keepNewest.contains(fact.uid) {
                held.append(Held(uid: fact.uid, reason: "newest from this sender"))
            } else if policy.guardTransactional, looksTransactional(fact.subject) {
                held.append(Held(uid: fact.uid, reason: "look transactional"))
            } else {
                allowed.append(fact.uid)
            }
        }
        return Verdict(allowed: allowed, held: held)
    }

    /// Older call site, kept so existing callers and tests still read clearly.
    public static func check(_ facts: [MessageFacts], keepTransactional: Bool) -> Verdict {
        var policy = CleanupPolicy.gentle
        policy.guardTransactional = keepTransactional
        policy.protectRecentDays = 0
        policy.keepNewestPerSender = 0
        return check(facts, policy: policy)
    }

    public static func looksTransactional(_ subject: String) -> Bool {
        let lower = subject.lowercased()
        return transactionalTerms.contains { term in
            guard let range = lower.range(of: term) else { return false }
            // Whole-word-ish: no letter immediately before or after the match.
            let before = range.lowerBound > lower.startIndex ? lower[lower.index(before: range.lowerBound)] : " "
            let after = range.upperBound < lower.endIndex ? lower[range.upperBound] : " "
            return !before.isLetter && !after.isLetter
        }
    }

    /// Reads the user's preference; on by default.
    public static var keepTransactionalPreference: Bool {
        UserDefaults.standard.object(forKey: "grokbox.guardTransactional") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "grokbox.guardTransactional")
    }
}
