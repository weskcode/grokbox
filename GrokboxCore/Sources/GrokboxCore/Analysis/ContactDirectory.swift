import Foundation

/// A contacted address joined with whatever sender profile exists for it.
public struct ContactSummary: Identifiable, Sendable, Hashable {
    public var id: String { address }
    public var address: String
    public var displayName: String
    public var timesContacted: Int
    public var lastContactedAt: Date
    public var messageCount: Int

    public init(address: String, displayName: String, timesContacted: Int, lastContactedAt: Date, messageCount: Int) {
        self.address = address
        self.displayName = displayName
        self.timesContacted = timesContacted
        self.lastContactedAt = lastContactedAt
        self.messageCount = messageCount
    }
}

/// Surfaces `SyncEngine.learnContacts`'s existing `ContactedAddress` data —
/// who the user has actually written to — with a friendlier display name and
/// message count where a `SenderProfile` for that address exists. No new
/// model, no new sync work: purely a read-side join of two things Grokbox
/// already computes.
public enum ContactDirectory {
    /// One summary per `ContactedAddress`, ranked by how often the user has
    /// written to them. `profiles` may span multiple accounts; if more than
    /// one carries the same address, the first is used — this always
    /// produces exactly one row per contacted address, never a duplicate.
    /// An address with no matching profile falls back to itself as the name.
    public static func summaries(contacts: [ContactedAddress], profiles: [SenderProfile]) -> [ContactSummary] {
        let profileByAddress = Dictionary(profiles.map { ($0.address, $0) }, uniquingKeysWith: { a, _ in a })
        return contacts
            .map { contact in
                let profile = profileByAddress[contact.address]
                let name = profile?.displayName.isEmpty == false ? profile!.displayName : contact.address
                return ContactSummary(
                    address: contact.address, displayName: name, timesContacted: contact.timesContacted,
                    lastContactedAt: contact.lastContactedAt, messageCount: profile?.messageCount ?? 0
                )
            }
            .sorted { $0.timesContacted > $1.timesContacted }
    }
}
