import Foundation

/// What the local model made of a typed request such as "file Medium under
/// Reading". Every field is the model's text and is trusted for nothing until
/// `RuleProposal.make` has checked it against what already exists.
struct RuleReading: Sendable, Equatable {
    /// The sender as the person named it: an address or a display name.
    var sender: String
    /// "sweep" or "keep"; nil leaves the decision alone.
    var decision: String?
    /// "policy", "folders", "archive" or "trash"; nil leaves it alone.
    var destination: String?
    /// A folder that already exists; nil leaves it alone.
    var folder: String?
    /// "policy", "never" or "always"; nil leaves it alone.
    var unsubscribe: String?
    /// Whatever the request asked that the fields above cannot say.
    var unsupported: String?

    init(sender: String, decision: String? = nil, destination: String? = nil, folder: String? = nil,
         unsubscribe: String? = nil, unsupported: String? = nil) {
        self.sender = sender
        self.decision = decision
        self.destination = destination
        self.folder = folder
        self.unsubscribe = unsubscribe
        self.unsupported = unsupported
    }
}

/// A sender Grokbox has indexed, as the proposal step needs it.
struct KnownSender: Sendable, Equatable {
    var address: String
    var displayName: String
    var supportsOneClickUnsubscribe: Bool
}

/// The outcome of checking a reading: a draft for the person to preview and
/// confirm, or a reason nothing was drafted. Neither writes anything.
enum RuleProposal: Sendable, Equatable {
    case draft(RuleDraft)
    case unresolved(Unresolved)

    enum Unresolved: Sendable, Equatable {
        case unsupported(String)
        case malformed(field: String, value: String)
        case unknownSender(String)
        case ambiguousSender([String])
        /// Typed requests may tighten a sender's rule but never approve one;
        /// approval stays with Sweep and Senders (ADR-0007).
        case notApproved(String)
        case unknownFolder(String)
        case conflict(String)
        case nothingToChange
    }

    /// Checks a reading against the senders, rules and folders that exist.
    ///
    /// `request` is the person's own sentence. It is read only to catch a
    /// condition the model dropped, so "archive Medium older than 30 days"
    /// cannot quietly become "archive all of Medium".
    static func make(from reading: RuleReading, request: String, senders: [KnownSender],
                     rules: [String: SenderOverride], folders: Set<String>) -> RuleProposal {
        if let unsupported = reading.unsupported?.trimmingCharacters(in: .whitespacesAndNewlines), !unsupported.isEmpty {
            return .unresolved(.unsupported(unsupported))
        }

        let decision: RuleDecision?
        switch normalized(reading.decision) {
        case nil: decision = nil
        case "sweep": decision = .sweep
        case "keep": decision = .keep
        case let other?: return .unresolved(.malformed(field: "decision", value: other))
        }

        let destination: Slot<CleanupPolicy.Disposition>?
        switch normalized(reading.destination) {
        case nil: destination = nil
        case "policy": destination = .followPolicy
        case "folders": destination = .set(.fileIntoFolders)
        case "archive": destination = .set(.archiveOnly)
        case "trash": destination = .set(.trash)
        case let other?: return .unresolved(.malformed(field: "destination", value: other))
        }

        let unsubscribe: Slot<Bool>?
        switch normalized(reading.unsubscribe) {
        case nil: unsubscribe = nil
        case "policy": unsubscribe = .followPolicy
        case "never": unsubscribe = .set(false)
        case "always": unsubscribe = .set(true)
        case let other?: return .unresolved(.malformed(field: "unsubscribe", value: other))
        }

        var folder: String?
        if let asked = reading.folder?.trimmingCharacters(in: .whitespacesAndNewlines), !asked.isEmpty {
            guard let existing = folders.first(where: { $0.caseInsensitiveCompare(asked) == .orderedSame }) else {
                return .unresolved(.unknownFolder(asked))
            }
            folder = existing
        }

        if decision == nil, destination == nil, unsubscribe == nil, folder == nil {
            return .unresolved(.nothingToChange)
        }

        let reference = reading.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        if reference.isEmpty { return .unresolved(.unknownSender(reference)) }
        if reference.hasPrefix("@") || reference.contains("*") {
            return .unresolved(.unsupported("Rules apply to one sender address, not a whole domain."))
        }
        let address: String
        switch resolve(reference, senders: senders, ruled: Array(rules.keys)) {
        case .one(let found): address = found
        case .none: return .unresolved(.unknownSender(reference))
        case .many(let candidates): return .unresolved(.ambiguousSender(candidates))
        }

        if let condition = droppedCondition(in: request, ignoring: [reference, folder].compactMap { $0 }) {
            return .unresolved(.unsupported("Grokbox rules cannot say \"\(condition)\" yet."))
        }

        let before = rules[address]
        let tightensOnly = decision == .keep && destination == nil && unsubscribe == nil && folder == nil
        if before?.decision != .sweep, !tightensOnly {
            return .unresolved(.notApproved(address))
        }
        if decision == .keep, destination != nil || unsubscribe != nil || folder != nil {
            return .unresolved(.conflict("A kept sender is never swept, so where its mail goes cannot apply."))
        }
        if let folder, let destination, destination != .set(.fileIntoFolders) {
            return .unresolved(.conflict("Filing into \(folder) and \(destination.value?.label.lowercased() ?? "following the policy") contradict each other."))
        }
        if unsubscribe == .set(true), !(senders.first { $0.address == address }?.supportsOneClickUnsubscribe ?? false) {
            return .unresolved(.unsupported("This sender has no one-click unsubscribe link."))
        }

        var after = before ?? SenderOverride(decision: .keep)
        if let decision { after.decision = decision }
        if let destination { after.disposition = destination.value }
        if let unsubscribe { after.autoUnsubscribe = unsubscribe.value }
        if let folder {
            after.customFolder = folder
            after.disposition = .fileIntoFolders
        }
        if after.decision == .sweep, let kept = after.customFolder, let disposition = after.disposition, disposition != .fileIntoFolders {
            return .unresolved(.conflict("This sender files into \(kept); \(disposition.label.lowercased()) would ignore that folder."))
        }
        if after == before { return .unresolved(.nothingToChange) }

        return .draft(RuleDraft(address: address, before: before, after: after))
    }

    /// A rule field the request touches: back to the policy, or a value.
    private enum Slot<Value: Equatable>: Equatable {
        case followPolicy
        case set(Value)

        var value: Value? {
            if case .set(let value) = self { value } else { nil }
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else { return nil }
        return value
    }

    private enum Match { case one(String), none, many([String]) }

    /// Exact address first, then an exact display name. Display names are
    /// written by senders, so two that collide are shown, never guessed between.
    private static func resolve(_ reference: String, senders: [KnownSender], ruled: [String]) -> Match {
        let addresses = Set(senders.map(\.address) + ruled)
        let byAddress = addresses.filter { $0.caseInsensitiveCompare(reference) == .orderedSame }
        if byAddress.count == 1, let only = byAddress.first { return .one(only) }
        if byAddress.count > 1 { return .many(byAddress.sorted()) }
        let byName = Set(senders.filter { $0.displayName.caseInsensitiveCompare(reference) == .orderedSame }.map(\.address))
        if byName.count > 1 { return .many(byName.sorted()) }
        return byName.first.map(Match.one) ?? .none
    }

    /// Words that put a condition on a rule, which a sender rule cannot hold.
    static let conditionWords: Set<String> = [
        "older", "newer", "after", "before", "since", "until", "unless", "except", "only", "if", "when",
        "day", "days", "week", "weeks", "month", "months", "year", "years",
        "read", "unread", "subject", "contains", "containing", "attachment", "attachments"
    ]

    private static func droppedCondition(in request: String, ignoring names: [String]) -> String? {
        var text = request.lowercased()
        for name in names { text = text.replacingOccurrences(of: name.lowercased(), with: " ") }
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.first { conditionWords.contains($0) || $0.contains(where: \.isNumber) }
    }
}

/// A rule change for one sender, before and after. Global across accounts,
/// like every sender rule.
struct RuleDraft: Sendable, Equatable {
    var address: String
    var before: SenderOverride?
    var after: SenderOverride

    /// Effects a person cannot take back from Activity alone: the provider
    /// may empty its Trash, and an unsubscribe request cannot be unsent.
    var irreversibleEffects: [String] {
        var effects: [String] = []
        if after.decision == .sweep, after.disposition == .trash, before?.disposition != .trash {
            effects.append(CleanupPolicy.Disposition.trash.warning ?? "Moves mail to Trash.")
        }
        if after.decision == .sweep, after.autoUnsubscribe == true, before?.autoUnsubscribe != true {
            effects.append("Unsubscribes from this sender when it is next swept. That request cannot be taken back.")
        }
        return effects
    }
}
