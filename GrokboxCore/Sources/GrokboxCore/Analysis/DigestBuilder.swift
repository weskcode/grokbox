import Foundation
import SwiftData

/// Builds an `InboxDigest` from what is already known. No model call, no
/// network: pressing Refresh is instant, and every sentence is a number.
@MainActor
public enum DigestBuilder {
    @discardableResult
    public static func build(for accounts: [MailAccount], in context: ModelContext, keepHistory: Int = 30) throws -> InboxDigest {
        let ids = accounts.map(\.id)
        let scopeKey = accounts.count == 1 ? accounts[0].id.uuidString : "all"
        let scopeLabel = accounts.count == 1 ? accounts[0].displayName : "All accounts (\(accounts.count))"
        let digest = InboxDigest(scopeKey: scopeKey, scopeLabel: scopeLabel)
        let now = Date()
        let calendar = Calendar.current

        // Classified, in-inbox, unswept, not snoozed — the Brief's rows.
        let classified = try context.fetch(FetchDescriptor<MessageHeader>(
            predicate: #Predicate { ids.contains($0.accountID) && $0.briefRank > 0 && $0.isSweptLocally == false && $0.isInInbox == true }
        )).filter { !$0.isSnoozed }

        let contacts = Dictionary(try context.fetch(FetchDescriptor<ContactedAddress>()).map { ($0.address, $0.timesContacted) }, uniquingKeysWith: { a, _ in a })
        let accountName = Dictionary(accounts.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })

        let ranked = classified.map { message -> (MessageHeader, PriorityScorer.Result) in
            (message, PriorityScorer.score(.init(
                importance: message.importance, actionType: message.actionType, dueAt: message.dueAt,
                receivedAt: message.receivedAt, isUnread: message.isUnread, isFlagged: message.isFlagged,
                isQuick: message.isQuick, timesContacted: contacts[message.senderAddress] ?? 0, now: now,
                subject: message.subject, summary: message.summary
            )))
        }.sorted { $0.1.score != $1.1.score ? $0.1.score > $1.1.score : $0.0.receivedAt > $1.0.receivedAt }
        // One entry per conversation, the same way the Brief shows rows, so
        // the summary's numbers match the tiles underneath it.
        .collapsedByThread()

        let needs = ranked.filter { $0.0.importance == .needsYou }
        digest.needsYou = needs.count
        digest.worthKnowing = ranked.filter { $0.0.importance == .worthKnowing }.count
        digest.overdue = needs.filter { $0.1.isOverdue }.count
        digest.dueSoon = needs.filter { item in
            guard let due = item.0.dueAt, !item.1.isOverdue else { return false }
            return (calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 99) <= 3
        }.count
        digest.quickWins = needs.filter { $0.0.isQuick }.count

        digest.topItems = needs.prefix(5).map { message, result in
            DigestItem(
                accountID: message.accountID, uid: message.uid,
                sender: (accounts.count > 1 ? "\(message.senderName.isEmpty ? message.senderAddress : message.senderName) · \(accountName[message.accountID] ?? "")"
                         : (message.senderName.isEmpty ? message.senderAddress : message.senderName)),
                subject: message.subject, summary: message.summary, why: result.reasons,
                dueLabel: result.dueLabel, isOverdue: result.isOverdue,
                actionType: message.actionType.rawValue, isQuick: message.isQuick, score: result.score
            )
        }

        // Counts the store can answer without loading rows.
        digest.unreadUnclassified = (try? context.fetchCount(FetchDescriptor<MessageHeader>(
            predicate: #Predicate { ids.contains($0.accountID) && $0.readAt == nil && $0.isUnread == true && $0.isInInbox == true && $0.isSweptLocally == false }
        ))) ?? 0
        digest.inboxNow = (try? context.fetchCount(FetchDescriptor<MessageHeader>(
            predicate: #Predicate { ids.contains($0.accountID) && $0.isInInbox == true && $0.isSweptLocally == false }
        ))) ?? 0

        let startOfDay = calendar.startOfDay(for: now)
        let todaysActions = try context.fetch(FetchDescriptor<CleanupAction>(
            predicate: #Predicate { ids.contains($0.accountID) && $0.performedAt >= startOfDay }
        ))
        digest.sweptToday = todaysActions.filter { $0.kind == .archive && !$0.isUndone && $0.errorMessage == nil }.reduce(0) { $0 + $1.messageCount }
        digest.heldToday = todaysActions.filter { $0.kind == .archive }.reduce(0) { $0 + $1.heldUIDs.count }

        let profiles = try context.fetch(FetchDescriptor<SenderProfile>(predicate: #Predicate { ids.contains($0.accountID) }))
        let rules = RuleStore.all(in: context)
        let pendingBulk = profiles.filter { $0.verdict == .bulk && $0.pendingCount > 0 && rules[$0.address] != .keep }
        digest.pendingBulkSenders = pendingBulk.count
        digest.pendingBulkMessages = pendingBulk.reduce(0) { $0 + $1.pendingCount }
        digest.unsubscribeCandidates = profiles.filter { $0.recommendation == .unsubscribeAndSweep }.count

        digest.headline = headline(digest)
        digest.narrative = narrative(digest, accountCount: accounts.count)

        context.insert(digest)
        // Keep a bounded history per scope.
        let scope = scopeKey
        let old = try context.fetch(FetchDescriptor<InboxDigest>(predicate: #Predicate { $0.scopeKey == scope },
                                                                  sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]))
        for stale in old.dropFirst(keepHistory) { context.delete(stale) }
        try context.save()
        return digest
    }

    public static func latest(scopeKey: String, in context: ModelContext) -> InboxDigest? {
        var descriptor = FetchDescriptor<InboxDigest>(predicate: #Predicate { $0.scopeKey == scopeKey },
                                                      sortBy: [SortDescriptor(\.generatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Words

    static func headline(_ d: InboxDigest) -> String {
        if d.needsYou == 0 {
            return d.unreadUnclassified > 0 ? "Nothing is waiting on you — \(d.unreadUnclassified.formatted()) unread not yet read by the model." : "Nothing is waiting on you."
        }
        var parts: [String] = ["\(d.needsYou) thing\(d.needsYou == 1 ? "" : "s") need\(d.needsYou == 1 ? "s" : "") you"]
        if d.overdue > 0 { parts.append("\(d.overdue) overdue") }
        else if d.dueSoon > 0 { parts.append("\(d.dueSoon) due within 3 days") }
        if d.quickWins > 0 { parts.append("\(d.quickWins) quick") }
        return parts.joined(separator: " · ") + "."
    }

    static func narrative(_ d: InboxDigest, accountCount: Int) -> String {
        var sentences: [String] = []
        let scope = accountCount > 1 ? "Across \(accountCount) inboxes" : "This inbox"
        sentences.append("\(scope): \(d.inboxNow.formatted()) message\(d.inboxNow == 1 ? "" : "s") in the inbox right now.")
        if d.worthKnowing > 0 {
            sentences.append("\(d.worthKnowing) more \(d.worthKnowing == 1 ? "is" : "are") worth knowing but need nothing from you.")
        }
        if d.sweptToday > 0 {
            sentences.append("\(d.sweptToday.formatted()) filed today" + (d.heldToday > 0 ? ", \(d.heldToday) held back for you." : "."))
        }
        if d.pendingBulkSenders > 0 {
            sentences.append("\(d.pendingBulkSenders) bulk sender\(d.pendingBulkSenders == 1 ? "" : "s") (\(d.pendingBulkMessages.formatted()) messages) \(d.pendingBulkSenders == 1 ? "is" : "are") waiting for your decision in Sweep.")
        }
        if d.unsubscribeCandidates > 0 {
            sentences.append("\(d.unsubscribeCandidates) sender\(d.unsubscribeCandidates == 1 ? "" : "s") you never open still \(d.unsubscribeCandidates == 1 ? "has" : "have") an unsubscribe link.")
        }
        if d.unreadUnclassified > 0 {
            sentences.append("\(d.unreadUnclassified.formatted()) unread \(d.unreadUnclassified == 1 ? "has" : "have") not been read by the model yet — press Read new mail.")
        }
        return sentences.joined(separator: " ")
    }
}


extension Array where Element == (MessageHeader, PriorityScorer.Result) {
    /// Keeps the highest-ranked message of each conversation.
    func collapsedByThread() -> [(MessageHeader, PriorityScorer.Result)] {
        var seen = Set<String>()
        return filter { message, _ in
            seen.insert(ThreadKey.key(accountID: message.accountID, senderAddress: message.senderAddress, subject: message.subject)).inserted
        }
    }
}
