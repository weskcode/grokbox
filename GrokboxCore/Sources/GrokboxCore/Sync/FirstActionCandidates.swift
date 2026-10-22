import Foundation

/// A sender worth showing at the end of setup: an item the Sweep plan already
/// holds, plus the advice that put it here.
public struct FirstActionCandidate: Identifiable, Sendable, Equatable {
    public var id: String { item.id }
    public var item: CleanupPlan.Item
    public var recommendation: Recommendation
    public var reason: String
}

/// Picks the few senders setup offers for inspection.
///
/// Candidates come only from the plan Sweep will show, so a sender offered in
/// setup is one Sweep can act on. Selection reads the plan and changes nothing.
public enum FirstActionCandidates {
    public static let limit = 3

    public static func select(from plan: CleanupPlan, advice: [String: (recommendation: Recommendation, reason: String)]) -> [FirstActionCandidate] {
        plan.items
            .compactMap { item -> FirstActionCandidate? in
                guard item.isEnabled, !item.isFromRule, item.messageCount > 0,
                      let result = advice[item.cluster.address],
                      result.recommendation == .unsubscribeAndSweep || result.recommendation == .fileAutomatically
                else { return nil }
                return FirstActionCandidate(item: item, recommendation: result.recommendation, reason: result.reason)
            }
            .sorted(by: ranksBefore)
            .prefix(limit)
            .map { $0 }
    }

    private static func ranksBefore(_ a: FirstActionCandidate, _ b: FirstActionCandidate) -> Bool {
        if a.recommendation != b.recommendation { return a.recommendation == .unsubscribeAndSweep }
        if a.item.messageCount != b.item.messageCount { return a.item.messageCount > b.item.messageCount }
        return a.item.cluster.address < b.item.cluster.address
    }
}

extension CleanupPlan {
    /// The plan with only these senders ticked, for opening Sweep on the
    /// senders chosen in setup. A chosen sender that has left the plan (the
    /// mailbox changed since) is simply absent: nothing else gets ticked in
    /// its place.
    public func ticking(only addresses: Set<String>) -> CleanupPlan {
        var ticked = self
        ticked.items = items.map { item in
            var item = item
            item.isEnabled = addresses.contains(item.cluster.address)
            return item
        }
        return ticked
    }
}

/// How much of the mailbox the index covers, so setup can say what its counts
/// are counts of.
public enum IndexCoverage: Sendable, Equatable {
    case complete(indexed: Int)
    case partial(indexed: Int, of: Int)
    /// The server's size could not be read, so completeness cannot be claimed.
    case unknown(indexed: Int)

    public init(indexed: Int, mailboxTotal: Int?) {
        guard let mailboxTotal else { self = .unknown(indexed: indexed); return }
        self = indexed >= mailboxTotal ? .complete(indexed: indexed) : .partial(indexed: indexed, of: mailboxTotal)
    }

    public var indexed: Int {
        switch self {
        case .complete(let n), .partial(let n, _), .unknown(let n): n
        }
    }

    public var isPartial: Bool {
        if case .partial = self { true } else { false }
    }
}
