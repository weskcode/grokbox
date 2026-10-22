import Foundation
import SwiftData

/// A responsibility state the user chose for one conversation. Derived states
/// are never stored; this is the one fact Grokbox cannot recompute from mail.
///
/// Keyed by account and conversation identity rather than by message, because
/// header rows are rewritten on re-index and after a UIDVALIDITY change. If the
/// identity scheme ever changes, old rows are orphaned, never misapplied.
@Model
public final class ConversationCorrection {
    #Index<ConversationCorrection>([\.accountID])

    /// `"<accountID>|<conversation identity>"`.
    @Attribute(.unique) public var key: String = ""
    public var accountID: UUID = UUID()
    public var stateRaw: String = ""
    /// Per-message key of the newest human message when the user chose.
    public var anchorMessageKey: String = ""
    public var anchorDate: Date = Date.distantPast
    public var correctedAt: Date = Date()

    public enum RecordError: Error, Equatable {
        case noConversation
        /// Uncertain is something Grokbox reports, not something a person chooses.
        case notAChoice
    }

    public static func key(accountID: UUID, conversationID: String) -> String {
        "\(accountID.uuidString)|\(conversationID)"
    }

    init(key: String, accountID: UUID, stateRaw: String, anchorMessageKey: String, anchorDate: Date, correctedAt: Date) {
        self.key = key
        self.accountID = accountID
        self.stateRaw = stateRaw
        self.anchorMessageKey = anchorMessageKey
        self.anchorDate = anchorDate
        self.correctedAt = correctedAt
    }

    /// What the responsibility rules read. `nil` if the stored state is unknown to this build.
    public var correction: ConversationResponsibility.Correction? {
        guard let state = ConversationResponsibility.State(rawValue: stateRaw), state != .uncertain else { return nil }
        return .init(state: state, anchorKey: anchorMessageKey, anchorDate: anchorDate)
    }

    /// Saves the user's choice. Choosing again for the same conversation
    /// replaces the one stored row.
    @discardableResult
    public static func record(_ state: ConversationResponsibility.State, accountID: UUID, conversationID: String,
                              anchorMessageKey: String, anchorDate: Date, now: Date = Date(),
                              in context: ModelContext) throws -> ConversationCorrection {
        guard !conversationID.isEmpty else { throw RecordError.noConversation }
        guard state != .uncertain else { throw RecordError.notAChoice }
        let key = key(accountID: accountID, conversationID: conversationID)
        let row: ConversationCorrection
        if let existing = try context.fetch(FetchDescriptor<ConversationCorrection>(predicate: #Predicate { $0.key == key })).first {
            row = existing
        } else {
            row = ConversationCorrection(key: key, accountID: accountID, stateRaw: "", anchorMessageKey: "",
                                         anchorDate: .distantPast, correctedAt: now)
            context.insert(row)
        }
        row.stateRaw = state.rawValue
        row.anchorMessageKey = anchorMessageKey
        row.anchorDate = anchorDate
        row.correctedAt = now
        try context.save()
        return row
    }

    /// Deletes every correction, or one account's. Throws so callers can say so
    /// when a removal leaves choices behind.
    public static func deleteAll(accountID: UUID? = nil, in context: ModelContext) throws {
        if let accountID {
            try context.delete(model: ConversationCorrection.self, where: #Predicate { $0.accountID == accountID })
        } else {
            try context.delete(model: ConversationCorrection.self, where: #Predicate { _ in true })
        }
    }
}
