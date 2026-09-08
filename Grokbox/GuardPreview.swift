import Foundation
import SwiftData
import GrokboxCore

/// Feeds `CleanupPlan.previewGuard` from the local index, so the number on the
/// Sweep button is the number of messages that will actually move.
enum GuardPreview {
    static func apply(to plan: inout CleanupPlan, policy: CleanupPolicy, account: MailAccount, in context: ModelContext) {
        let accountID = account.id
        plan.previewGuard(policy: policy) { cluster in
            let uids = cluster.pendingUIDs
            guard !uids.isEmpty else { return [] }
            var out: [SweepGuard.MessageFacts] = []
            out.reserveCapacity(uids.count)
            for start in stride(from: 0, to: uids.count, by: 400) {
                let chunk = Array(uids[start..<min(start + 400, uids.count)])
                let descriptor = FetchDescriptor<MessageHeader>(
                    predicate: #Predicate { $0.accountID == accountID && chunk.contains($0.uid) })
                for message in (try? context.fetch(descriptor)) ?? [] {
                    out.append(.init(uid: message.uid, subject: message.subject, isFlagged: message.isFlagged,
                                     importance: message.importance, receivedAt: message.receivedAt))
                }
            }
            return out
        }
    }
}
