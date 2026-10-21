import Foundation

/// What the local model made of a typed request such as "file Medium under
/// Reading". Every field is the model's text and is trusted for nothing until
/// `RuleProposal.make` has checked it against the request and what exists.
struct RuleReading: Sendable, Equatable {
    /// The sender exactly as the request names it: an address or a display name.
    var sender: String
    /// "sweep" or "keep"; nil leaves the decision alone.
    var decision: String?
    /// "policy", "folders", "archive" or "trash"; nil leaves it alone.
    var destination: String?
    /// A folder that already exists, as the request names it; nil leaves it alone.
    var folder: String?
    /// "never" or "always"; nil leaves it alone.
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
    var category: SenderCategory
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
        /// The model named a sender or folder the request does not contain.
        case notInRequest(String)
        /// The model's slots disagree with the words the person typed.
        case misread
        case unknownSender(String)
        case ambiguousSender([String])
        /// Typed requests may tighten a sender's rule but never approve one;
        /// approval stays with Sweep and Senders (ADR-0007).
        case notApproved(String)
        case unknownFolder(String)
        case ambiguousFolder([String])
        case conflict(String)
        case nothingToChange
    }

    /// Checks a reading against the person's own sentence and against the
    /// senders, rules, folders and policy that exist now.
    ///
    /// Every word of `request` must be accounted for: the sender, the folder,
    /// a phrase that sets a field, or filler. Anything left over is a
    /// condition a sender rule cannot hold, so "trash Medium from yesterday"
    /// creates nothing rather than trashing all of Medium.
    static func make(from reading: RuleReading, request: String, senders: [KnownSender],
                     rules: [String: SenderOverride], folders: Set<String>,
                     policy: CleanupPolicy) -> RuleProposal {
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

        let unsubscribe: Bool?
        switch normalized(reading.unsubscribe) {
        case nil: unsubscribe = nil
        case "never": unsubscribe = false
        case "always": unsubscribe = true
        case let other?: return .unresolved(.malformed(field: "unsubscribe", value: other))
        }

        let askedFolder = reading.folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        if decision == nil, destination == nil, unsubscribe == nil, askedFolder?.isEmpty ?? true {
            return .unresolved(.nothingToChange)
        }

        let reference = reading.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        if reference.hasPrefix("@") || reference.contains("*") {
            return .unresolved(.unsupported("Rules apply to one sender address, not a whole domain."))
        }

        var words = RequestWords(request)
        guard !reference.isEmpty, words.consume(reference) else { return .unresolved(.notInRequest(reference)) }

        var folder: String?
        if let askedFolder, !askedFolder.isEmpty {
            guard words.consume(askedFolder) else { return .unresolved(.notInRequest(askedFolder)) }
            let exact = folders.filter { $0 == askedFolder }
            let loose = folders.filter { $0.caseInsensitiveCompare(askedFolder) == .orderedSame }
            if let only = exact.first ?? (loose.count == 1 ? loose.first : nil) {
                folder = only
            } else if loose.isEmpty {
                return .unresolved(.unknownFolder(askedFolder))
            } else {
                return .unresolved(.ambiguousFolder(loose.sorted()))
            }
        }

        let evidence: Evidence
        switch words.phrases() {
        case .leftover(let word): return .unresolved(.unsupported("Grokbox rules cannot say \"\(word)\" yet."))
        case .found(let found): evidence = found
        }
        var allowedDestinations = Set([destination].compactMap { $0 })
        if folder != nil { allowedDestinations.insert(.set(.fileIntoFolders)) }
        guard evidence.decisions == Set([decision].compactMap { $0 }),
              evidence.destinations.isSubset(of: allowedDestinations),
              destination.map { evidence.destinations.contains($0) } ?? true,
              evidence.unsubscribes == Set([unsubscribe].compactMap { $0 }) else {
            return .unresolved(.misread)
        }

        let address: String
        switch resolve(reference, senders: senders, ruled: Array(rules.keys)) {
        case .one(let found): address = found
        case .none: return .unresolved(.unknownSender(reference))
        case .many(let candidates): return .unresolved(.ambiguousSender(candidates))
        }
        let sender = senders.first { $0.address == address }

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
        if unsubscribe == true, !(sender?.supportsOneClickUnsubscribe ?? false) {
            return .unresolved(.unsupported("This sender has no one-click unsubscribe link."))
        }

        var after = before ?? SenderOverride(decision: .keep)
        if let decision { after.decision = decision }
        if let destination { after.disposition = destination.value }
        if let unsubscribe { after.autoUnsubscribe = unsubscribe }
        if let folder {
            after.customFolder = folder
            after.disposition = .fileIntoFolders
        }
        if after == before { return .unresolved(.nothingToChange) }

        let effects = Effects(sender: sender, policy: policy)
        if after.decision == .sweep, let kept = after.customFolder, effects.disposition(after) != .fileIntoFolders {
            return .unresolved(.conflict("This sender files into \(kept); \(effects.disposition(after).label.lowercased()) would ignore that folder."))
        }
        return .draft(RuleDraft(address: address, before: before, after: after,
                                irreversibleEffects: effects.irreversible(from: before, to: after)))
    }

    /// A rule field the request touches: back to the policy, or a value.
    fileprivate enum Slot<Value: Hashable>: Hashable {
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
        if byAddress.count > 1 { return .many(byAddress.sorted()) }
        if let only = byAddress.first { return .one(only) }
        let byName = Set(senders.filter { $0.displayName.caseInsensitiveCompare(reference) == .orderedSame }.map(\.address))
        if byName.count > 1 { return .many(byName.sorted()) }
        return byName.first.map(Match.one) ?? .none
    }

    /// What each field-setting phrase in the request asked for.
    fileprivate struct Evidence {
        var decisions: Set<RuleDecision> = []
        var destinations: Set<Slot<CleanupPolicy.Disposition>> = []
        var unsubscribes: Set<Bool> = []
    }

    /// The whole v1 vocabulary. Longer phrases are tried first, so "never
    /// unsubscribe" is not read as "unsubscribe".
    fileprivate static let phrases: [(words: [String], apply: @Sendable (inout Evidence) -> Void)] = [
        (["never", "unsubscribe"], { $0.unsubscribes.insert(false) }),
        (["don't", "unsubscribe"], { $0.unsubscribes.insert(false) }),
        (["stop", "unsubscribing"], { $0.unsubscribes.insert(false) }),
        (["never", "sweep"], { $0.decisions.insert(.keep) }),
        (["don't", "sweep"], { $0.decisions.insert(.keep) }),
        (["stop", "sweeping"], { $0.decisions.insert(.keep) }),
        (["follow", "policy"], { $0.destinations.insert(.followPolicy) }),
        (["archive", "only"], { $0.destinations.insert(.set(.archiveOnly)) }),
        (["file", "folders"], { $0.destinations.insert(.set(.fileIntoFolders)) }),
        (["unsubscribe"], { $0.unsubscribes.insert(true) }),
        (["keep"], { $0.decisions.insert(.keep) }),
        (["sweep"], { $0.decisions.insert(.sweep) }),
        (["archive"], { $0.destinations.insert(.set(.archiveOnly)) }),
        (["trash"], { $0.destinations.insert(.set(.trash)) }),
        (["bin"], { $0.destinations.insert(.set(.trash)) }),
        (["file"], { $0.destinations.insert(.set(.fileIntoFolders)) })
    ]

    /// Words that carry no condition. Anything not here, not a phrase, and
    /// not the sender or folder stops the request.
    static let filler: Set<String> = [
        "a", "an", "the", "me", "my", "i", "please", "and", "also", "too", "always", "all", "everything",
        "of", "for", "from", "to", "into", "under", "in", "with", "it", "its", "them", "their", "these", "this",
        "those", "mail", "mails", "email", "emails", "message", "messages", "set", "send", "move", "put",
        "let", "make", "rule", "go", "should", "folder"
    ]
}

/// The request as words, so a sender or folder is matched as whole words
/// at one place, never as a substring anywhere ("read" inside "unread").
private struct RequestWords {
    private var words: [String]
    private var used: [Bool]

    init(_ text: String) {
        words = Self.split(text)
        used = Array(repeating: false, count: words.count)
    }

    static func split(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { $0.isWhitespace || ",;:!?()[]\"/".contains($0) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".'")) }
            .filter { !$0.isEmpty }
    }

    /// Marks the first unused run of words equal to `phrase`.
    mutating func consume(_ phrase: String) -> Bool {
        let target = Self.split(phrase)
        guard !target.isEmpty, target.count <= words.count else { return false }
        for start in 0...(words.count - target.count) {
            let range = start..<(start + target.count)
            if Array(words[range]) == target, !used[range].contains(true) {
                for index in range { used[index] = true }
                return true
            }
        }
        return false
    }

    enum Reading { case found(RuleProposal.Evidence), leftover(String) }

    func phrases() -> Reading {
        let rest = zip(words, used).filter { !$0.1 }.map(\.0).filter { !RuleProposal.filler.contains($0) }
        var evidence = RuleProposal.Evidence()
        var index = 0
        next: while index < rest.count {
            for phrase in RuleProposal.phrases where Array(rest[index...].prefix(phrase.words.count)) == phrase.words {
                phrase.apply(&evidence)
                index += phrase.words.count
                continue next
            }
            return .leftover(rest[index])
        }
        return .found(evidence)
    }
}

/// What a rule actually does once the policy fills in what it leaves open.
private struct Effects {
    var sender: KnownSender?
    var policy: CleanupPolicy

    func disposition(_ rule: SenderOverride) -> CleanupPolicy.Disposition {
        rule.disposition ?? policy.disposition(for: sender?.category ?? .unknown)
    }

    private func trashes(_ rule: SenderOverride?) -> Bool {
        guard let rule, rule.decision == .sweep else { return false }
        return disposition(rule) == .trash
    }

    /// Effects a person cannot take back from Activity alone: the provider
    /// may empty its Trash, and an unsubscribe request cannot be unsent.
    func irreversible(from before: SenderOverride?, to after: SenderOverride) -> [String] {
        var effects: [String] = []
        if trashes(after), !trashes(before) {
            effects.append(CleanupPolicy.Disposition.trash.warning ?? "Moves mail to Trash.")
        }
        // An explicit yes skips the policy's own qualifying checks, so it is
        // new even where the policy might already have unsubscribed.
        if after.decision == .sweep, after.autoUnsubscribe == true,
           !(before?.decision == .sweep && before?.autoUnsubscribe == true) {
            effects.append("Unsubscribes from this sender when it is next swept. That request cannot be taken back.")
        }
        return effects
    }
}

/// A rule change for one sender, before and after, with what it would do
/// under the policy in force when it was drafted. Global across accounts,
/// like every sender rule.
struct RuleDraft: Sendable, Equatable {
    var address: String
    var before: SenderOverride?
    var after: SenderOverride
    var irreversibleEffects: [String]
}
