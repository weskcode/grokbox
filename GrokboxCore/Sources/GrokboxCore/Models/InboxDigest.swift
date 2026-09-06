import Foundation
import SwiftData

/// One item in a digest: enough to show and to jump to, no more.
public struct DigestItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(accountID.uuidString)-\(uid)" }
    public var accountID: UUID
    public var uid: UInt32
    public var sender: String
    public var subject: String
    public var summary: String?
    public var why: [String]
    public var dueLabel: String?
    public var isOverdue: Bool
    public var actionType: String
    public var isQuick: Bool
    public var score: Int

    public init(accountID: UUID, uid: UInt32, sender: String, subject: String, summary: String?, why: [String],
                dueLabel: String?, isOverdue: Bool, actionType: String, isQuick: Bool, score: Int) {
        self.accountID = accountID
        self.uid = uid
        self.sender = sender
        self.subject = subject
        self.summary = summary
        self.why = why
        self.dueLabel = dueLabel
        self.isOverdue = isOverdue
        self.actionType = actionType
        self.isQuick = isQuick
        self.score = score
    }
}

/// A dated snapshot of "where the inbox stands", written by `DigestBuilder`
/// from the real numbers. Kept as history so it can be reread later.
@Model
public final class InboxDigest {
    #Index<InboxDigest>([\.generatedAt], [\.scopeKey])

    public var id: UUID = UUID()
    public var generatedAt: Date = Date()
    /// "all" or an account id — which mailboxes this covers.
    public var scopeKey: String = "all"
    public var scopeLabel: String = ""

    public var headline: String = ""
    public var narrative: String = ""
    public var topItems: [DigestItem] = []

    public var needsYou: Int = 0
    public var worthKnowing: Int = 0
    public var dueSoon: Int = 0
    public var overdue: Int = 0
    public var quickWins: Int = 0
    public var unreadUnclassified: Int = 0
    public var sweptToday: Int = 0
    public var heldToday: Int = 0
    public var pendingBulkSenders: Int = 0
    public var pendingBulkMessages: Int = 0
    public var unsubscribeCandidates: Int = 0
    public var inboxNow: Int = 0

    public init(scopeKey: String, scopeLabel: String) {
        self.id = UUID()
        self.generatedAt = Date()
        self.scopeKey = scopeKey
        self.scopeLabel = scopeLabel
    }

    /// Plain text for the clipboard or a note.
    public var asText: String {
        var lines: [String] = ["Grokbox — \(scopeLabel) — \(generatedAt.formatted(date: .abbreviated, time: .shortened))", "", headline, narrative, ""]
        if !topItems.isEmpty {
            lines.append("Start with:")
            for (index, item) in topItems.prefix(5).enumerated() {
                var line = "\(index + 1). \(item.sender) — \(item.subject)"
                if let due = item.dueLabel { line += " (\(due))" }
                if let summary = item.summary { line += "\n   \(summary)" }
                if !item.why.isEmpty { line += "\n   Why: \(item.why.joined(separator: " · "))" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}
