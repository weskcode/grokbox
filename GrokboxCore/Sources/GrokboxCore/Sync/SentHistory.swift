import Foundation
import SwiftData

/// Keeps `SentMessageHeader` rows matching the Sent mailbox: what a completed
/// walk saw, under the mailbox's current UIDVALIDITY, and nothing else.
enum SentHistory {
    /// Runs before anything is fetched. Rows from an older numbering are wrong
    /// whatever the walk finds, and an empty mailbox has nothing to keep.
    static func reconcile(accountID: UUID, mailbox: String, uidValidity: UInt32, isEmpty: Bool, in context: ModelContext) throws {
        let stale = try rows(accountID: accountID, mailbox: mailbox, in: context)
            .filter { isEmpty || $0.uidValidity != uidValidity }
        for row in stale { context.delete(row) }
    }

    static func record(_ header: FetchedHeader, accountID: UUID, mailbox: String, uidValidity: UInt32, in context: ModelContext) {
        let key = SentMessageHeader.key(accountID: accountID, mailbox: mailbox, uidValidity: uidValidity, uid: header.uid)
        let existing = try? context.fetch(FetchDescriptor<SentMessageHeader>(predicate: #Predicate { $0.key == key })).first
        if existing == nil {
            context.insert(SentMessageHeader(accountID: accountID, mailbox: mailbox, uidValidity: uidValidity, header: header))
        }
    }

    /// Only after a walk finished: anything it did not see is gone from the
    /// server or older than the walk reaches.
    static func prune(accountID: UUID, mailbox: String, keeping seen: Set<UInt32>, in context: ModelContext) throws {
        for row in try rows(accountID: accountID, mailbox: mailbox, in: context) where !seen.contains(row.uid) {
            context.delete(row)
        }
    }

    private static func rows(accountID: UUID, mailbox: String, in context: ModelContext) throws -> [SentMessageHeader] {
        try context.fetch(FetchDescriptor<SentMessageHeader>(predicate: #Predicate { $0.accountID == accountID && $0.mailbox == mailbox }))
    }
}
