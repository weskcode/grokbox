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
        /// Two copies of one message disagree, so neither can be trusted.
        case conflictingCopies(key: String)
        case sentNotCheckedBefore(Date)
        case orderUnclear
        case replyMayNotHaveArrived(Date)
        case corrected
        case notReadByModel(key: String, Reading)
        case othersReplied(author: String, Date)
        case copiedOnReply(Date, ActionType?)
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
        /// Automatic replies and receipts after the user's latest message, or all of
        /// them when the user has not written. Evidence only.
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
    /// Unknown facts count as possibly tracking it, so an unknown is reported
    /// rather than hidden.
    public static func derive(_ conversation: Conversation, correction: Correction? = nil) -> Result? {
        guard conversation.messages.contains(where: mightTrack) else { return nil }

        let lastHumanFromUser = conversation.messages
            .filter { $0.isFromUser == true && $0.automation == .human }.map(\.date).max()
        func unresolved(_ reason: Reason, lastFromUser: Date? = lastHumanFromUser) -> Result {
            Result(state: .uncertain, reason: reason, followUp: nil, automaticReplies: [], lastFromUser: lastFromUser)
        }

        switch conversation.identity {
        case nil: return unresolved(.missingFact(.identitySource))
        case .subjectFallback: return unresolved(.groupedBySubject)
        case .headers: break
        }
        if let fact = missingFact(in: conversation.messages) { return unresolved(.missingFact(fact)) }

        let ordered: [Message]
        switch canonical(conversation.messages) {
        case .conflict(let key): return unresolved(.conflictingCopies(key: key), lastFromUser: nil)
        case .ordered(let messages): ordered = messages
        }
        let human = ordered.indices.filter { ordered[$0].automation == .human }
        guard ordered.contains(where: mightTrack), let l = human.last else { return nil }

        let u = human.last { ordered[$0].isFromUser == true }
        let automaticReplies = ordered.indices
            .filter { ordered[$0].automation == .other && $0 > (u ?? -1) }.map { ordered[$0].date }
        func result(_ state: State, _ reason: Reason, followUp: ActionType? = nil) -> Result {
            Result(state: state, reason: reason, followUp: followUp, automaticReplies: automaticReplies,
                   lastFromUser: u.map { ordered[$0].date })
        }

        switch conversation.sentCoverage {
        case .unknown:
            return result(.uncertain, .missingFact(.sentCoverage))
        case .since(let start):
            if ordered.contains(where: { $0.date < start }) { return result(.uncertain, .sentNotCheckedBefore(start)) }
        }

        let position = Dictionary(ordered.enumerated().compactMap { i, m in m.key.map { ($0, i) } },
                                  uniquingKeysWith: { a, _ in a })
        for i in ordered.indices {
            switch ordered[i].parent {
            case .root: continue
            case .unknown:
                // Receipts and auto-replies often carry no reply headers; only human order matters.
                if ordered[i].automation == .human { return result(.uncertain, .orderUnclear) }
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

        let openTask = inbound.contains { i in
            guard ordered[i].isAddressedToUser == true, case .read(.needsYou, let action) = ordered[i].reading,
                  !replyActions.contains(action) else { return false }
            return !human.contains { $0 > i && ordered[$0].isFromUser == true }
        }
        if latest.isFromUser == false, latest.isAddressedToUser == false, u != nil, !openTask {
            return result(.uncertain, .copiedOnReply(latest.date, readAction(latest)))
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

        if u != nil, !openTask, case .read(let importance, _) = latest.reading, importance != .needsYou {
            return result(.waiting, .acknowledged(latest.date))
        }

        if case .read(.needsYou, let action) = latest.reading, !replyActions.contains(action) {
            return result(.uncertain, .taskNotReply(action))
        }

        let task = inbound.reversed().lazy.compactMap { i -> ActionType? in
            guard ordered[i].isAddressedToUser == true, case .read(.needsYou, let action) = ordered[i].reading,
                  !replyActions.contains(action) else { return nil }
            return action
        }.first
        return result(.uncertain, .unmatched(task: task))
    }

    private static func readAction(_ message: Message) -> ActionType? {
        if case .read(_, let action) = message.reading { action } else { nil }
    }

    /// Could this message make the conversation tracked, reading unknowns permissively?
    /// Mail the rules already classed as bulk cannot.
    private static func mightTrack(_ message: Message) -> Bool {
        guard message.automation == .human || message.automation == nil else { return false }
        if message.isFromUser != false { return true }
        guard message.isAddressedToUser != false else { return false }
        switch message.reading {
        case .read(let importance, _): return importance == .needsYou
        case .rulesOnly: return false
        case .notRead, .modelFailed: return true
        }
    }

    enum Collapsed: Equatable {
        case ordered([Message])
        case conflict(String)
    }

    /// Collapses copies of one message and orders by (date, key), a total order,
    /// so the same set always gives the same list. Copies must agree on every
    /// fact. Their reader outcomes are taken as a set: an unread copy adds
    /// nothing, a completed read settles rules-only or failed reads, and any
    /// other mix disagrees.
    static func canonical(_ messages: [Message]) -> Collapsed {
        let merged = Dictionary(grouping: messages.filter { $0.key != nil }, by: { $0.key ?? "" }).mapValues(merge)
        if let key = merged.filter({ $0.value == nil }).keys.min() { return .conflict(key) }
        return .ordered(merged.values.compactMap { $0 }.sorted {
            $0.date != $1.date ? $0.date < $1.date : ($0.key ?? "") < ($1.key ?? "")
        })
    }

    private static func merge(_ copies: [Message]) -> Message? {
        guard var facts = copies.first else { return nil }
        facts.reading = .notRead
        guard copies.allSatisfy({ var f = $0; f.reading = .notRead; return f == facts }) else { return nil }
        var outcomes: [Reading] = []
        for reading in copies.map(\.reading) where reading != .notRead && !outcomes.contains(reading) {
            outcomes.append(reading)
        }
        let reads = outcomes.filter { if case .read = $0 { true } else { false } }
        let settled = reads.isEmpty ? outcomes : reads
        guard settled.count <= 1 else { return nil }
        facts.reading = settled.first ?? .notRead
        return facts
    }

    private static func missingFact(in messages: [Message]) -> MissingFact? {
        if messages.contains(where: { $0.key == nil }) { return .key }
        if messages.contains(where: { $0.isFromUser == nil }) { return .direction }
        if messages.contains(where: { $0.automation == nil }) { return .automation }
        if messages.contains(where: { $0.isFromUser == false && $0.isAddressedToUser == nil }) { return .addressee }
        return nil
    }
}
