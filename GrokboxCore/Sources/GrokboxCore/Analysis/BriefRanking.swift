import Foundation
import SwiftData

/// One row of the Brief: the message that earned the slot, plus the rest of
/// its conversation folded underneath so Done and Later act on the thread.
public struct BriefItem: Identifiable {
    public let message: MessageHeader
    public let result: PriorityScorer.Result
    public var others: [MessageHeader] = []
    public var id: PersistentIdentifier { message.persistentModelID }
    public var thread: [MessageHeader] { [message] + others }

    public init(message: MessageHeader, result: PriorityScorer.Result, others: [MessageHeader] = []) {
        self.message = message; self.result = result; self.others = others
    }
}

/// The ordering both apps show. Kept here so a phone and a Mac never disagree
/// about what comes first.
public enum BriefRanking {
    public static func rank(_ messages: [MessageHeader], contactCounts: [String: Int], now: Date = Date()) -> [BriefItem] {
        messages
            .filter { !$0.isSnoozed }
            .map { message in
                BriefItem(message: message, result: PriorityScorer.score(.init(
                    importance: message.importance, actionType: message.actionType, dueAt: message.dueAt,
                    receivedAt: message.receivedAt, isUnread: message.isUnread, isFlagged: message.isFlagged,
                    isQuick: message.isQuick, timesContacted: contactCounts[message.senderAddress] ?? 0, now: now
                )))
            }
            .sorted { $0.result.score != $1.result.score ? $0.result.score > $1.result.score : $0.message.receivedAt > $1.message.receivedAt }
            .collapsedByThread()
    }

    /// What VoiceOver reads for a row: the same facts the colours and chips carry.
    public static func spokenSummary(_ item: BriefItem) -> String {
        let m = item.message
        var parts: [String] = []
        parts.append(m.isUnread ? "Unread" : "Read")
        parts.append("from \(m.senderName.isEmpty ? m.senderAddress : m.senderName)")
        parts.append(m.subject)
        if let due = item.result.dueLabel { parts.append(item.result.isOverdue ? "overdue, \(due)" : "due \(due)") }
        if m.actionType != .none { parts.append(m.actionType.label) }
        if m.isQuick { parts.append("about two minutes") }
        if !item.others.isEmpty { parts.append("\(item.thread.count) messages in this thread") }
        if let summary = m.summary { parts.append(summary) }
        return parts.joined(separator: ". ")
    }
}

extension Array where Element == BriefItem {
    /// One row per conversation; the highest-ranked message keeps the row.
    public func collapsedByThread() -> [BriefItem] {
        var out: [BriefItem] = []
        var index: [String: Int] = [:]
        for item in self {
            let key = ThreadKey.key(accountID: item.message.accountID, senderAddress: item.message.senderAddress, subject: item.message.subject)
            if let i = index[key] { out[i].others.append(item.message) }
            else { index[key] = out.count; out.append(item) }
        }
        return out
    }
}
