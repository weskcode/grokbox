import Foundation
import SwiftData

/// One indexed message. Grokbox stores **headers only** — never message bodies.
///
/// When the reader pass runs, a body is fetched transiently, handed to the
/// on-device model, and discarded. Only the model's one-line summary and
/// importance call are kept here.
@Model
public final class MessageHeader {
    #Index<MessageHeader>([\.accountID], [\.senderAddress], [\.receivedAt], [\.importanceRaw], [\.briefRank], [\.accountID, \.senderAddress])

    /// Plain column rather than a relationship: a to-many inverse on the account
    /// makes every insert touch a 40,000-element array. Cascade is done by hand
    /// in `AppState.remove`.
    public var accountID: UUID = UUID()
    public var uid: UInt32 = 0
    public var mailbox: String = ""
    public var subject: String = ""
    public var senderName: String = ""
    public var senderAddress: String = ""
    public var senderDomain: String = ""
    public var receivedAt: Date = Date.distantPast
    public var isUnread: Bool = true
    public var isFlagged: Bool = false
    public var listUnsubscribe: String?
    public var listUnsubscribePost: String?
    public var listID: String?
    public var messageID: String?

    /// Set locally when Grokbox archives the message, so the UI reflects it
    /// without a re-index. The server is the source of truth.
    public var isSweptLocally: Bool = false

    /// Whether the message is currently in the inbox (Gmail: carries `\Inbox`).
    /// Mail that is already archived is not a sweep candidate.
    public var isInInbox: Bool = true

    // Filled in by the reader pass. Nil means the model has not seen it.
    public var summary: String?
    public var importanceRaw: String?
    public var importanceReason: String?
    public var readAt: Date?
    /// 2 = needs you, 1 = worth knowing, 0 = noise or unread by the model.
    /// A non-optional integer so the Brief's predicate stays trivially indexable.
    public var briefRank: Int = 0

    // Prioritisation signals from the reader pass.
    public var actionTypeRaw: String = ActionType.none.rawValue
    public var dueHint: String?
    public var dueAt: Date?
    public var isQuick: Bool = false

    /// "Later": hidden from the Brief until this date. A deliberate deferral,
    /// recorded so it is a choice rather than a thing that slipped.
    public var snoozedUntil: Date?

    public var actionType: ActionType {
        get { ActionType(rawValue: actionTypeRaw) ?? .none }
        set { actionTypeRaw = newValue.rawValue }
    }

    public var isSnoozed: Bool {
        guard let until = snoozedUntil else { return false }
        return until > Date()
    }

    public var hasUnsubscribeLink: Bool { listUnsubscribe?.isEmpty == false }

    /// RFC 8058: the sender supports unsubscribing with a single HTTPS POST.
    public var supportsOneClickUnsubscribe: Bool {
        listUnsubscribePost?.localizedCaseInsensitiveContains("One-Click") == true
    }

    public var importance: Importance? {
        get { importanceRaw.flatMap(Importance.init(rawValue:)) }
        set {
            importanceRaw = newValue?.rawValue
            briefRank = switch newValue {
            case .needsYou: 2
            case .worthKnowing: 1
            default: 0
            }
        }
    }

    public init(
        accountID: UUID,
        uid: UInt32,
        mailbox: String,
        subject: String,
        senderName: String,
        senderAddress: String,
        receivedAt: Date,
        isUnread: Bool,
        isFlagged: Bool,
        listUnsubscribe: String?,
        listUnsubscribePost: String?,
        listID: String?,
        messageID: String?,
        isInInbox: Bool = true
    ) {
        self.accountID = accountID
        self.uid = uid
        self.isInInbox = isInInbox
        self.mailbox = mailbox
        self.subject = subject
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.senderDomain = senderAddress.split(separator: "@").last.map(String.init) ?? ""
        self.receivedAt = receivedAt
        self.isUnread = isUnread
        self.isFlagged = isFlagged
        self.listUnsubscribe = listUnsubscribe
        self.listUnsubscribePost = listUnsubscribePost
        self.listID = listID
        self.messageID = messageID
    }
}

/// An address the user has personally written to. The single strongest
/// "this matters" signal in an inbox, and it needs no AI at all.
@Model
public final class ContactedAddress {
    @Attribute(.unique) public var address: String = ""
    public var lastContactedAt: Date = Date.distantPast
    public var timesContacted: Int = 0

    public init(address: String, lastContactedAt: Date) {
        self.address = address
        self.lastContactedAt = lastContactedAt
        self.timesContacted = 1
    }
}

/// What the model decided a message is. Three buckets, chosen for an ADHD
/// reader: the only question that matters is "do I have to do something?"
public enum Importance: String, Codable, Sendable, CaseIterable {
    /// Someone is waiting on you, or there is a deadline, bill, or decision.
    case needsYou
    /// Real information from a real person or service. Nothing required.
    case worthKnowing
    /// Marketing, newsletters, automated notifications.
    case noise

    public var label: String {
        switch self {
        case .needsYou: "Needs you"
        case .worthKnowing: "Worth knowing"
        case .noise: "Noise"
        }
    }
}

/// One thing Grokbox did to the mailbox. Every mutation writes one of these
/// *before* it runs, and the record is what undo reads from.
@Model
public final class CleanupAction {
    public var id: UUID = UUID()
    public var accountID: UUID = UUID()
    public var performedAt: Date = Date()
    public var kindRaw: String = ActionKind.archive.rawValue
    public var senderAddress: String = ""
    public var senderName: String = ""
    public var mailbox: String = ""
    public var uids: [UInt32] = []
    public var labelName: String?
    public var isUndoable: Bool = true
    public var undoneAt: Date?
    public var errorMessage: String?

    /// The mailbox's UIDVALIDITY at the moment this action ran.
    ///
    /// Undo compares this against the server's *live* value. It cannot use the
    /// `MailboxSnapshot` instead: an index pass overwrites the snapshot with
    /// whatever the server now reports, so after a renumber the snapshot agrees
    /// with the server and the guard passes while these UIDs point at entirely
    /// different messages. 0 means "recorded before this was tracked".
    public var uidValidity: UInt32 = 0

    /// For a MOVE on a non-Gmail server: where the messages went, what UIDs
    /// they have there, and that mailbox's validity at the time. Undo moves
    /// them back from here. Empty for label-based (Gmail) archives.
    public var targetMailbox: String?
    public var targetUIDs: [UInt32] = []
    public var targetUIDValidity: UInt32 = 0

    /// Messages the sweep guard kept out of this action, and why.
    public var heldUIDs: [UInt32] = []
    public var heldSummary: String?

    public var kind: ActionKind {
        get { ActionKind(rawValue: kindRaw) ?? .archive }
        set { kindRaw = newValue.rawValue }
    }

    public var isUndone: Bool { undoneAt != nil }
    public var messageCount: Int { uids.count }

    public init(
        accountID: UUID,
        kind: ActionKind,
        senderAddress: String,
        senderName: String,
        mailbox: String,
        uids: [UInt32],
        labelName: String? = nil,
        isUndoable: Bool,
        uidValidity: UInt32 = 0
    ) {
        self.id = UUID()
        self.accountID = accountID
        self.performedAt = Date()
        self.kindRaw = kind.rawValue
        self.senderAddress = senderAddress
        self.senderName = senderName
        self.mailbox = mailbox
        self.uids = uids
        self.labelName = labelName
        self.isUndoable = isUndoable
        self.uidValidity = uidValidity
    }
}

/// The mutations Grokbox is willing to perform. Note what is absent: there is
/// no `delete`. See docs/DECISIONS.md ADR-0003.
public enum ActionKind: String, Codable, Sendable, CaseIterable {
    /// Remove from the inbox. The message stays in All Mail / Archive.
    case archive
    /// Set the \Seen flag.
    case markRead
    /// Apply a label (Gmail) so swept mail stays findable.
    case label

    public var label: String {
        switch self {
        case .archive: "Archive"
        case .markRead: "Mark read"
        case .label: "Label"
        }
    }
}

/// What we last saw of a mailbox on the server. Drives incremental sync and,
/// more importantly, the UIDVALIDITY guard: if the server renumbered the
/// mailbox, every UID we hold is stale and a sweep must refuse to run.
@Model
public final class MailboxSnapshot {
    /// `"<accountID>|<mailbox>"` — SwiftData has no compound unique keys.
    @Attribute(.unique) public var key: String = ""
    public var accountID: UUID = UUID()
    public var mailbox: String = ""
    public var uidValidity: UInt32 = 0
    public var highestUID: UInt32 = 0
    public var messageCountOnServer: Int = 0
    public var lastIndexedAt: Date = Date()

    public static func key(accountID: UUID, mailbox: String) -> String { "\(accountID.uuidString)|\(mailbox)" }

    public init(accountID: UUID, mailbox: String, uidValidity: UInt32, highestUID: UInt32, messageCountOnServer: Int) {
        self.key = Self.key(accountID: accountID, mailbox: mailbox)
        self.accountID = accountID
        self.mailbox = mailbox
        self.uidValidity = uidValidity
        self.highestUID = highestUID
        self.messageCountOnServer = messageCountOnServer
        self.lastIndexedAt = Date()
    }
}
