import Foundation

/// Whose move it is in a conversation, from what Grokbox can actually see.
///
/// A pure function of the conversation's messages and at most one manual
/// correction. Duplicates collapse and every arrival order of the same messages
/// gives the same answer, so incremental or out-of-order sync cannot leave a
/// stale state behind. Nothing here infers completion: a receipt, an automatic
/// reply or the user's own latest message never resolves a conversation; only
/// the user does. Rule order matters: missing or conflicting facts win first,
/// so an unknown is shown as uncertain rather than guessed.
public enum ConversationResponsibility {
    public enum State: String, Sendable, Codable, CaseIterable {
        case needsReply, waiting, resolved, uncertain
    }

    public enum IdentitySource: Sendable, Equatable {
        case headers, subjectFallback
    }

    /// From when Sent mail is known to be complete for the account.
    public enum SentCoverage: Sendable, Equatable {
        case unknown
        case since(Date)
    }

    public enum Parent: Sendable, Hashable {
        case root
        case message(String)
        case unknown
    }

    public enum Automation: Sendable, Equatable {
        case human
        /// A bounce: the user's message may never have arrived.
        case deliveryFailure
        /// Out-of-office, auto-submitted, bulk, read or delivery receipts.
        case other
    }

    /// What the reader pass did with a message. Only `.read` carries a real
    /// importance and action; the other cases leave `actionType` at its default.
    public enum Reading: Sendable, Equatable {
        case notRead
        case rulesOnly
        case modelFailed
        case read(Importance, ActionType)
    }

    /// A `nil` fact is unknown, and an unknown fact is never guessed.
    public struct Message: Sendable, Equatable {
        public var key: String?
        public var date: Date
        public var author: String
        public var isFromUser: Bool?
        /// To rather than Cc. Only inbound messages need it.
        public var isAddressedToUser: Bool?
        public var parent: Parent
        public var automation: Automation?
        public var reading: Reading

        public init(key: String?, date: Date, author: String, isFromUser: Bool?, isAddressedToUser: Bool?,
                    parent: Parent, automation: Automation?, reading: Reading) {
            self.key = key
            self.date = date
            self.author = author
            self.isFromUser = isFromUser
            self.isAddressedToUser = isAddressedToUser
            self.parent = parent
            self.automation = automation
            self.reading = reading
        }
    }

    public struct Conversation: Sendable, Equatable {
        public var identity: IdentitySource?
        public var sentCoverage: SentCoverage
        public var messages: [Message]

        public init(identity: IdentitySource?, sentCoverage: SentCoverage, messages: [Message]) {
            self.identity = identity
            self.sentCoverage = sentCoverage
            self.messages = messages
        }
    }

    /// A state the user chose, anchored to the newest human message at the time.
    public struct Correction: Sendable, Equatable {
        public var state: State
        public var anchorKey: String
        public var anchorDate: Date

        public init(state: State, anchorKey: String, anchorDate: Date) {
            self.state = state
            self.anchorKey = anchorKey
            self.anchorDate = anchorDate
        }
    }

    public enum MissingFact: Sendable, Equatable {
        case identitySource, key, direction, automation, addressee, sentCoverage
    }

    public enum Reason: Sendable, Equatable {
        case groupedBySubject
        case missingFact(MissingFact)
        case sentNotCheckedBefore(Date)
        case orderUnclear
        case replyMayNotHaveArrived(Date)
        case corrected
        case notReadByModel(key: String, Reading)
        case othersReplied(author: String, Date)
        case copiedOnReply(Date)
        case asked(author: String, Date)
        case youReplied(Date)
        case acknowledged(Date)
        case taskNotReply(ActionType)
        case unmatched(task: ActionType?)
    }

    public struct Result: Sendable, Equatable {
        public var state: State
        public var reason: Reason
        /// After an open ask, what the asker sent next: `.none` for a thanks.
        public var followUp: ActionType?
        /// Automatic replies and receipts after the user's latest message, shown as evidence only.
        public var automaticReplies: [Date]
        public var lastFromUser: Date?
    }

    /// Actions that mean a reply is owed. Other needs-you actions are tasks.
    static let replyActions: Set<ActionType> = [.reply, .decide]

    public static let waitingVisibleDays = 14

    /// Waiting drops out of the Brief after this long without changing state.
    public static func isWaitingStale(since lastFromUser: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastFromUser) > Double(waitingVisibleDays) * 86_400
    }

    /// `nil` when the conversation is not tracked and keeps today's behavior.
    public static func derive(_ conversation: Conversation, correction: Correction? = nil) -> Result? {
        let ordered = canonical(conversation.messages)
        let human = ordered.indices.filter { ordered[$0].automation == .human }
        let isTracked = human.contains { i in
            let m = ordered[i]
            if m.isFromUser == true { return true }
            guard m.isFromUser == false, m.isAddressedToUser == true, case .read(.needsYou, _) = m.reading else { return false }
            return true
        }
        guard isTracked, let l = human.last else { return nil }

        let u = human.last { ordered[$0].isFromUser == true }
        let automaticReplies = u.map { u in
            ordered.indices.filter { $0 > u && ordered[$0].automation == .other }.map { ordered[$0].date }
        } ?? []
        func result(_ state: State, _ reason: Reason, followUp: ActionType? = nil) -> Result {
            Result(state: state, reason: reason, followUp: followUp, automaticReplies: automaticReplies,
                   lastFromUser: u.map { ordered[$0].date })
        }

        switch conversation.identity {
        case nil: return result(.uncertain, .missingFact(.identitySource))
        case .subjectFallback: return result(.uncertain, .groupedBySubject)
        case .headers: break
        }

        if let fact = missingFact(in: ordered) { return result(.uncertain, .missingFact(fact)) }
        switch conversation.sentCoverage {
        case .unknown:
            return result(.uncertain, .missingFact(.sentCoverage))
        case .since(let start):
            if human.contains(where: { ordered[$0].date < start }) { return result(.uncertain, .sentNotCheckedBefore(start)) }
        }

        let position = Dictionary(ordered.enumerated().compactMap { i, m in m.key.map { ($0, i) } },
                                  uniquingKeysWith: { a, _ in a })
        for i in human {
            switch ordered[i].parent {
            case .root: continue
            case .unknown: return result(.uncertain, .orderUnclear)
            case .message(let parentKey):
                guard let p = position[parentKey], p < i else { return result(.uncertain, .orderUnclear) }
            }
        }

        if let u, let bounce = ordered.indices.first(where: { $0 > u && ordered[$0].automation == .deliveryFailure }) {
            return result(.uncertain, .replyMayNotHaveArrived(ordered[bounce].date))
        }

        if let correction, correction.state != .uncertain {
            let cleared = if let anchor = position[correction.anchorKey] {
                human.contains { $0 > anchor }
            } else {
                human.contains { ordered[$0].date > correction.anchorDate }
            }
            if !cleared { return result(correction.state, .corrected) }
        }

        let latest = ordered[l]
        let inbound = human.filter { ordered[$0].isFromUser == false }

        if let unread = inbound.last(where: { if case .read = ordered[$0].reading { false } else { true } }),
           let key = ordered[unread].key {
            return result(.uncertain, .notReadByModel(key: key, ordered[unread].reading))
        }

        if latest.isFromUser == false, Set(inbound.map { ordered[$0].author.lowercased() }).count >= 2 {
            return result(.uncertain, .othersReplied(author: latest.author, latest.date))
        }

        if latest.isFromUser == false, latest.isAddressedToUser == false, u != nil {
            return result(.uncertain, .copiedOnReply(latest.date))
        }

        let asks = inbound.filter { i in
            guard ordered[i].isAddressedToUser == true, case .read(.needsYou, let action) = ordered[i].reading else { return false }
            return replyActions.contains(action)
        }
        if let ask = asks.last, !human.contains(where: { $0 > ask && ordered[$0].isFromUser == true }) {
            let asker = ordered[ask]
            var followUp: ActionType?
            if l > ask, latest.author.lowercased() == asker.author.lowercased(), case .read(_, let action) = latest.reading {
                followUp = action
            }
            return result(.needsReply, .asked(author: asker.author, asker.date), followUp: followUp)
        }

        if latest.isFromUser == true { return result(.waiting, .youReplied(latest.date)) }

        if u != nil, case .read(let importance, _) = latest.reading, importance != .needsYou {
            return result(.waiting, .acknowledged(latest.date))
        }

        if case .read(.needsYou, let action) = latest.reading, !replyActions.contains(action) {
            return result(.uncertain, .taskNotReply(action))
        }

        let task = inbound.last.flatMap { i -> ActionType? in
            if case .read(.needsYou, let action) = ordered[i].reading { action } else { nil }
        }
        return result(.uncertain, .unmatched(task: task))
    }

    /// Collapses duplicates by key and orders by (date, key), a total order, so
    /// the same set always produces the same list. Duplicates are assumed to be
    /// one message seen twice; the copy with the most reader information wins.
    static func canonical(_ messages: [Message]) -> [Message] {
        var byKey: [String: Message] = [:]
        var unkeyed: [Message] = []
        for message in messages {
            guard let key = message.key else { unkeyed.append(message); continue }
            if let existing = byKey[key], !isBetterCopy(message, than: existing) { continue }
            byKey[key] = message
        }
        return (Array(byKey.values) + unkeyed).sorted {
            $0.date != $1.date ? $0.date < $1.date : ($0.key ?? "") < ($1.key ?? "")
        }
    }

    private static func isBetterCopy(_ a: Message, than b: Message) -> Bool {
        func rank(_ r: Reading) -> Int {
            switch r {
            case .notRead: 0
            case .rulesOnly: 1
            case .modelFailed: 2
            case .read: 3
            }
        }
        if rank(a.reading) != rank(b.reading) { return rank(a.reading) > rank(b.reading) }
        return a.date < b.date
    }

    private static func missingFact(in messages: [Message]) -> MissingFact? {
        if messages.contains(where: { $0.key == nil }) { return .key }
        if messages.contains(where: { $0.isFromUser == nil }) { return .direction }
        if messages.contains(where: { $0.automation == nil }) { return .automation }
        if messages.contains(where: { $0.automation == .human && $0.isFromUser == false && $0.isAddressedToUser == nil }) {
            return .addressee
        }
        return nil
    }
}
