import Foundation
import SwiftData

enum SentHistory {
    /// One walk of the Sent mailbox. Rows are only ever added while it runs;
    /// `finish` is the one place that deletes, and only a completed walk calls it.
    struct Walk {
        let accountID: UUID
        let mailbox: String
        let uidValidity: UInt32
        private var known: Set<String>
        private var seen: Set<UInt32> = []

        init(accountID: UUID, mailbox: String, uidValidity: UInt32, in context: ModelContext) throws {
            self.accountID = accountID
            self.mailbox = mailbox
            self.uidValidity = uidValidity
            self.known = Set(try SentHistory.rows(accountID: accountID, in: context).map(\.key))
        }

        mutating func record(_ header: FetchedHeader, in context: ModelContext) {
            seen.insert(header.uid)
            let key = SentMessageHeader.key(accountID: accountID, mailbox: mailbox, uidValidity: uidValidity, uid: header.uid)
            if known.insert(key).inserted {
                context.insert(SentMessageHeader(accountID: accountID, mailbox: mailbox, uidValidity: uidValidity, header: header))
            }
        }

        /// Keeps only what this walk saw: same folder, same numbering. Rows from
        /// a renamed or replaced Sent folder go too.
        func finish(in context: ModelContext) throws {
            for row in try SentHistory.rows(accountID: accountID, in: context)
            where row.mailbox != mailbox || row.uidValidity != uidValidity || !seen.contains(row.uid) {
                context.delete(row)
            }
        }
    }

    static func rows(accountID: UUID, in context: ModelContext) throws -> [SentMessageHeader] {
        try context.fetch(FetchDescriptor<SentMessageHeader>(predicate: #Predicate { $0.accountID == accountID }))
    }
}
