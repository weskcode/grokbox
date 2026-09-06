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

        public init(uid: UInt32, subject: String, isFlagged: Bool, importance: Importance?) {
            self.uid = uid
            self.subject = subject
            self.isFlagged = isFlagged
            self.importance = importance
        }
    }

    public static func check(_ facts: [MessageFacts], keepTransactional: Bool) -> Verdict {
        var allowed: [UInt32] = []
        var held: [Held] = []
        for fact in facts {
            if fact.isFlagged {
                held.append(Held(uid: fact.uid, reason: "flagged"))
            } else if fact.importance == .needsYou {
                held.append(Held(uid: fact.uid, reason: "need you"))
            } else if keepTransactional, looksTransactional(fact.subject) {
                held.append(Held(uid: fact.uid, reason: "look transactional"))
            } else {
                allowed.append(fact.uid)
            }
        }
        return Verdict(allowed: allowed, held: held)
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
