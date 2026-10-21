import Foundation
import SwiftData
import GrokboxCore

/// Feeds `CleanupPlan.previewGuard` from the local index, so the number on the
/// Sweep button is the number of messages that will actually move.
enum GuardPreview {
    static func apply(to plan: inout CleanupPlan, policy: CleanupPolicy, account: MailAccount, in context: ModelContext) {
        let accountID = account.id
        plan.previewGuard(policy: policy) { cluster in
            (try? SweepGuard.MessageFacts.load(uids: cluster.pendingUIDs, accountID: accountID, in: context)) ?? []
        }
    }
}
