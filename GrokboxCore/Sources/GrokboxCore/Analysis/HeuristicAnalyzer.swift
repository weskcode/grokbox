import Foundation

/// Produces suggestions for what to do with each sender.
///
/// Tier 1 (this type) is pure heuristics over headers: no model, no network,
/// no per-message inference. It runs in milliseconds over tens of thousands of
/// messages and covers the large majority of an email pile-up.
public protocol Analyzer: Sendable {
    func assess(_ clusters: [SenderCluster]) -> [SenderAssessment]
}

public struct HeuristicAnalyzer: Analyzer {
    /// Above this, a sender is bulk. Below `keepThreshold`, keep. Between, review.
    public var bulkThreshold = 4
    public var keepThreshold = 0

    public init() {}

    public func assess(_ clusters: [SenderCluster]) -> [SenderAssessment] {
        clusters.map(score).sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.cluster.messageCount > rhs.cluster.messageCount
        }
    }

    private func score(_ cluster: SenderCluster) -> SenderAssessment {
        var score = 0
        var reasons: [String] = []

        // Having written to someone is the strongest keep signal there is, and it
        // outweighs every bulk signal combined on purpose: the cost of wrongly
        // bulking a real correspondent is far higher than of keeping a newsletter.
        if cluster.everContacted {
            score -= 6
            reasons.append("You have written to this address")
        }

        if cluster.hasUnsubscribeLink {
            score += 3
            reasons.append("Sends with an unsubscribe link")
        }

        if !cluster.everContacted {
            score += 2
            reasons.append("You have never written back")
        }

        if cluster.unreadRatio > 0.9 && cluster.messageCount >= 3 {
            score += 2
            reasons.append("\(Int(cluster.unreadRatio * 100))% never opened")
        } else if cluster.unreadRatio < 0.3 {
            score -= 2
            reasons.append("You usually read these")
        }

        if cluster.messageCount >= 20 {
            score += 1
            reasons.append("\(cluster.messageCount) messages")
        }

        if cluster.flaggedCount > 0 {
            score -= 4
            reasons.append("You have flagged \(cluster.flaggedCount)")
        }

        // Dormant senders are safe to sweep; recent ones may still be live.
        if let months = Calendar.current.dateComponents([.month], from: cluster.newest, to: .now).month, months >= 12 {
            score += 1
            reasons.append("Nothing new in over a year")
        }

        let verdict: Verdict = if score >= bulkThreshold {
            .bulk
        } else if score <= keepThreshold {
            .keep
        } else {
            .review
        }

        return SenderAssessment(cluster: cluster, verdict: verdict, score: score, reasons: reasons)
    }
}

/// Collapses indexed messages into sender clusters.
public enum SenderClusterBuilder {
    @MainActor
    public static func build(
        messages: [MessageHeader],
        contactedAddresses: Set<String>
    ) -> [SenderCluster] {
        var byAddress: [String: [MessageHeader]] = [:]
        for message in messages where !message.senderAddress.isEmpty {
            byAddress[message.senderAddress, default: []].append(message)
        }

        return byAddress.map { address, group in
            let sorted = group.sorted { $0.receivedAt > $1.receivedAt }
            let pending = group.filter { !$0.isSweptLocally && $0.isInInbox }
            return SenderCluster(
                address: address,
                displayName: sorted.first(where: { !$0.senderName.isEmpty })?.senderName ?? address,
                domain: sorted.first?.senderDomain ?? "",
                mailbox: sorted.first?.mailbox ?? "",
                uids: pending.map(\.uid),
                unreadUIDs: pending.filter(\.isUnread).map(\.uid),
                messageCount: group.count,
                unreadCount: group.count(where: \.isUnread),
                flaggedCount: group.count(where: \.isFlagged),
                sweptCount: group.count(where: \.isSweptLocally),
                newest: sorted.first?.receivedAt ?? .distantPast,
                oldest: sorted.last?.receivedAt ?? .distantPast,
                hasUnsubscribeLink: group.contains(where: \.hasUnsubscribeLink),
                unsubscribeValue: group.first(where: \.hasUnsubscribeLink)?.listUnsubscribe,
                supportsOneClickUnsubscribe: group.contains(where: \.supportsOneClickUnsubscribe),
                everContacted: contactedAddresses.contains(address),
                sampleSubjects: Array(sorted.prefix(3).map(\.subject))
            )
        }
    }
}
