import Foundation
import SwiftData

/// What saving a rule edit would do to a sender's mail right now, worked out
/// with the planner and guard a sweep uses and without touching anything.
///
/// It reads the local index only: no mailbox connection, no rule written, no
/// action logged, no unsubscribe sent. Flags can change after it is built, so
/// a sweep still checks the guard again against live data when it runs; use
/// `sameEffect(as:)` to notice that the answer has moved.
///
/// Rules are global — a rule for an address covers it in every account — so a
/// preview lists every account that receives from the sender.
public struct RulePreview: Sendable {
    public struct Message: Sendable, Equatable, Identifiable {
        public var id: UInt32 { uid }
        public var uid: UInt32
        public var subject: String
        public var receivedAt: Date
        /// Why the guard keeps it in the inbox; nil for mail that would move.
        public var heldReason: String?
    }

    public struct Sweep: Sendable, Equatable {
        public var disposition: CleanupPolicy.Disposition
        public var folder: String
        public var markRead: Bool
        public var unsubscribe: Bool
        public var affectedCount: Int
        public var heldCount: Int
        /// Every message in each group, so `sameEffect` sees a change the capped samples would hide.
        public var affectedUIDs: [UInt32]
        public var heldUIDs: [UInt32]
        /// Newest first, capped at the preview's sample limit.
        public var affected: [Message]
        public var held: [Message]
    }

    public enum Outcome: Sendable, Equatable {
        case sweeps(Sweep)
        /// A keep rule: nothing is proposed for this sender.
        case keptInInbox
        /// Everything from this sender is already dealt with.
        case nothingPending
        /// No sweep rule, and the sender's verdict would not put it in a sweep.
        case notProposed
    }

    public struct AccountEffect: Sendable, Equatable, Identifiable {
        public var id: UUID { accountID }
        public var accountID: UUID
        public var accountName: String
        public var outcome: Outcome
    }

    /// Effects a person cannot take back from Activity.
    public enum IrreversibleEffect: Sendable, Equatable {
        /// A one-click request to the sender; it cannot be recalled.
        case unsubscribeRequest
        /// A move to the provider's Trash; recoverable only until the provider empties it.
        case movesToTrash
    }

    public let address: String
    public let edit: RuleEdit
    /// The rule as it would be stored; nil when the edit removes it.
    public let resultingRule: SenderOverride?
    public let accounts: [AccountEffect]
    public let generatedAt: Date
    /// The newest index update among the sender's accounts: how fresh the mail it describes is.
    public let indexedAt: Date?

    public var irreversibleEffects: [IrreversibleEffect] {
        // The sweep only unsubscribes after it has moved something, so a
        // sender whose every message is held sends nothing.
        let sweeps = accounts.compactMap { effect -> Sweep? in
            if case .sweeps(let sweep) = effect.outcome, sweep.affectedCount > 0 { return sweep }
            return nil
        }
        var out: [IrreversibleEffect] = []
        if sweeps.contains(where: \.unsubscribe) { out.append(.unsubscribeRequest) }
        if sweeps.contains(where: { $0.disposition == .trash }) { out.append(.movesToTrash) }
        return out
    }

    /// Whether another preview of the same edit reaches the same result, so a
    /// screen can say "mail changed since you looked" before saving.
    public func sameEffect(as other: RulePreview) -> Bool {
        address == other.address && edit == other.edit && accounts == other.accounts
    }

    @MainActor
    public static func make(address: String, edit: RuleEdit, policy: CleanupPolicy = .current,
                            in context: ModelContext, now: Date = Date(), sampleLimit: Int = 5) throws -> RulePreview {
        let resulting = try edit.applied(to: RuleStore.override(for: address, in: context))
        let rules = resulting.map { [address: $0.decision] } ?? [:]
        let overrides = resulting.map { [address: $0] } ?? [:]

        let profiles = try context.fetch(FetchDescriptor<SenderProfile>(predicate: #Predicate { $0.address == address }))
        let names = Dictionary(try context.fetch(FetchDescriptor<MailAccount>()).map { ($0.id, $0.displayName) },
                               uniquingKeysWith: { a, _ in a })

        let effects = try profiles.map { profile -> AccountEffect in
            let plan = CleanupPlan.suggested(from: [profile.assessment], rules: rules, policy: policy, overrides: overrides)
            let outcome: Outcome
            if let item = plan.items.first {
                let facts = try SweepGuard.MessageFacts.load(uids: item.cluster.pendingUIDs, accountID: profile.accountID, in: context)
                let verdict = SweepGuard.check(facts, policy: policy, now: now)
                let byUID = Dictionary(facts.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
                func sample(_ uids: [UInt32], reasons: [UInt32: String] = [:]) -> [Message] {
                    uids.compactMap { uid in byUID[uid].map {
                        Message(uid: uid, subject: $0.subject, receivedAt: $0.receivedAt, heldReason: reasons[uid])
                    } }
                    .sorted { $0.receivedAt > $1.receivedAt }
                    .prefix(sampleLimit).map { $0 }
                }
                let reasons = Dictionary(verdict.held.map { ($0.uid, SweepGuard.phrase(for: $0.reason, count: 1)) },
                                         uniquingKeysWith: { a, _ in a })
                outcome = .sweeps(Sweep(disposition: item.disposition, folder: item.folder, markRead: item.markRead,
                                        unsubscribe: item.unsubscribe,
                                        affectedCount: verdict.allowed.count, heldCount: verdict.held.count,
                                        affectedUIDs: verdict.allowed.sorted(), heldUIDs: verdict.held.map(\.uid).sorted(),
                                        affected: sample(verdict.allowed),
                                        held: sample(verdict.held.map(\.uid), reasons: reasons)))
            } else if resulting?.decision == .keep {
                outcome = .keptInInbox
            } else if profile.pendingUIDs.isEmpty {
                outcome = .nothingPending
            } else {
                outcome = .notProposed
            }
            return AccountEffect(accountID: profile.accountID, accountName: names[profile.accountID] ?? "", outcome: outcome)
        }
        .sorted { ($0.accountName, $0.accountID.uuidString) < ($1.accountName, $1.accountID.uuidString) }

        return RulePreview(address: address, edit: edit, resultingRule: resulting, accounts: effects,
                           generatedAt: now, indexedAt: profiles.map(\.updatedAt).max())
    }
}

// MARK: - Wording

extension RuleEdit {
    /// The choice as the Senders menus name it.
    public var title: String {
        switch self {
        case .decision(let decision): decision.label
        case .disposition(nil): "Follow my policy"
        case .disposition(let disposition?): "Always \(disposition.label.lowercased())"
        case .autoUnsubscribe(false): "Never unsubscribe from this sender"
        case .autoUnsubscribe(true): "Unsubscribe when sweeping"
        case .autoUnsubscribe(nil): "Follow my policy on unsubscribing"
        case .customFolder(let folder?): "File into \(folder)"
        case .customFolder(nil): "Follow the category folder"
        case .clear: "Clear rule"
        }
    }
}

extension RulePreview.Sweep {
    /// Where the mail goes, in the words a person sees.
    public var destination: String {
        switch disposition {
        case .trash: "Trash"
        case .archiveOnly: "Archive"
        case .fileIntoFolders: folder
        }
    }
}

extension RulePreview.IrreversibleEffect {
    public var warning: String {
        switch self {
        case .unsubscribeRequest:
            "A one-click unsubscribe request will be sent to this sender. It cannot be recalled."
        case .movesToTrash:
            "Mail moved to Trash can be taken back only until the provider empties it."
        }
    }
}
