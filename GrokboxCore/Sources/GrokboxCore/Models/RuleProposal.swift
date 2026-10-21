import Foundation

/// A sender Grokbox has indexed, as the proposal step needs it.
struct KnownSender: Sendable, Equatable {
    var address: String
    var displayName: String
    var category: SenderCategory
    var supportsOneClickUnsubscribe: Bool
}

/// The outcome of reading a typed request such as "file Medium under
/// Reading": a draft for the person to preview and confirm, or a reason
/// nothing was drafted. Neither writes anything.
enum RuleProposal: Sendable, Equatable {
    case draft(RuleDraft)
    case unresolved(Unresolved)

    enum Unresolved: Sendable, Equatable {
        /// The sentence is not one of the forms in `RequestForm.all`.
        case unsupported
        /// The sentence fits more than one form with different results.
        case ambiguousRequest
        case wholeDomain(String)
        case unknownSender(String)
        case ambiguousSender([String])
        /// Typed requests may tighten a sender's rule but never approve one;
        /// approval stays with Sweep and Senders (ADR-0007).
        case notApproved(String)
        case unknownFolder(String)
        case ambiguousFolder([String])
        case noOneClickLink(String)
        case conflict(String)
        case nothingToChange
    }

    /// Reads a request against the senders, rules, folders and policy that
    /// exist now.
    ///
    /// The whole sentence must be one supported form. Anything else, such as
    /// "trash this message from Medium" or "archive Medium older than 30
    /// days", creates nothing rather than a broader rule than was asked for.
    static func make(request: String, senders: [KnownSender], rules: [String: SenderOverride],
                     folders: Set<String>, policy: CleanupPolicy) -> RuleProposal {
        let words = RequestForm.words(in: request)
        let readings = RequestForm.all.flatMap { $0.readings(of: words) }
        guard !readings.isEmpty else { return .unresolved(.unsupported) }

        var targets: Set<Target> = []
        var failures: [Unresolved] = []
        for reading in readings {
            switch target(for: reading, senders: senders, rules: rules, folders: folders) {
            case .success(let target): targets.insert(target)
            case .failure(let failure): failures.append(failure.reason)
            }
        }
        guard targets.count <= 1 else { return .unresolved(.ambiguousRequest) }
        // Sender names are chosen by senders, so one reading that resolves
        // cannot outvote another that found two senders or folders.
        if let ambiguity = failures.first(where: \.isAmbiguity) { return .unresolved(ambiguity) }
        guard let target = targets.first else {
            return .unresolved(failures.min { $0.rank < $1.rank } ?? .unsupported)
        }

        let sender = senders.first { $0.address == target.address }
        let before = rules[target.address]
        if before?.decision != .sweep, target.change != .decide(.keep) {
            return .unresolved(.notApproved(target.address))
        }

        var after = before ?? SenderOverride(decision: .keep)
        switch target.change {
        case .decide(let decision): after.decision = decision
        case .destination(let disposition): after.disposition = disposition
        case .unsubscribe(let allowed):
            if allowed, sender?.supportsOneClickUnsubscribe != true { return .unresolved(.noOneClickLink(target.address)) }
            after.autoUnsubscribe = allowed
        case .folder:
            after.customFolder = target.folder
            after.disposition = .fileIntoFolders
        }
        if after == before { return .unresolved(.nothingToChange) }

        let effects = Effects(sender: sender, policy: policy)
        if after.decision == .sweep, let kept = after.customFolder, effects.disposition(after) != .fileIntoFolders {
            return .unresolved(.conflict("This sender files into \(kept); \(effects.disposition(after).label.lowercased()) would ignore that folder."))
        }
        return .draft(RuleDraft(address: target.address, before: before, after: after,
                                irreversibleEffects: effects.irreversible(from: before, to: after)))
    }

    private struct Target: Hashable {
        var address: String
        var folder: String?
        var change: RequestForm.Change
    }

    private struct Failure: Error { var reason: Unresolved }

    /// Resolves the words the person typed, spelled as they typed them.
    private static func target(for reading: RequestForm.Reading, senders: [KnownSender],
                               rules: [String: SenderOverride], folders: Set<String>) -> Result<Target, Failure> {
        let named = reading.sender
        if named.hasPrefix("@") || named.contains("*") { return .failure(Failure(reason: .wholeDomain(named))) }

        // Exact address first, then an exact display name. Display names are
        // written by senders, so two that collide are shown, never guessed between.
        let addresses = Set(senders.map(\.address) + rules.keys)
        var matches = addresses.filter { $0.caseInsensitiveCompare(named) == .orderedSame }
        if matches.isEmpty {
            matches = Set(senders.filter { $0.displayName.caseInsensitiveCompare(named) == .orderedSame }.map(\.address))
        }
        if matches.count > 1 { return .failure(Failure(reason: .ambiguousSender(matches.sorted()))) }
        guard let address = matches.first else { return .failure(Failure(reason: .unknownSender(named))) }

        var folder: String?
        if let typed = reading.folder {
            let loose = folders.filter { $0.caseInsensitiveCompare(typed) == .orderedSame }
            if folders.contains(typed) {
                folder = typed
            } else if loose.count == 1 {
                folder = loose.first
            } else if loose.isEmpty {
                return .failure(Failure(reason: .unknownFolder(typed)))
            } else {
                return .failure(Failure(reason: .ambiguousFolder(loose.sorted())))
            }
        }
        return .success(Target(address: address, folder: folder, change: reading.change))
    }
}

private extension RuleProposal.Unresolved {
    /// Which failure explains a request best when every reading of it failed.
    var rank: Int {
        switch self {
        case .ambiguousSender: 0
        case .ambiguousFolder: 1
        case .unknownFolder: 2
        case .wholeDomain: 3
        case .unknownSender: 4
        default: 5
        }
    }

    var isAmbiguity: Bool {
        switch self {
        case .ambiguousSender, .ambiguousFolder: true
        default: false
        }
    }
}

/// The sentences a typed request may be, word for word apart from the
/// sender and folder. This is the whole v1 grammar: one change to one
/// sender per request, in English.
struct RequestForm: Sendable {
    enum Change: Sendable, Hashable {
        case decide(RuleDecision)
        case destination(CleanupPolicy.Disposition?)
        case folder
        case unsubscribe(Bool)
    }

    enum Piece: Sendable, Equatable {
        case word(String)
        case sender
        case folder
    }

    struct Reading: Sendable, Equatable {
        var change: Change
        var sender: String
        var folder: String?
    }

    var pieces: [Piece]
    var change: Change

    /// What may stand before a sender in place of nothing: "trash mail from
    /// X" means the same as "trash X". "This message from" is not here.
    static let mailFrom = ["", "mail from", "email from", "emails from", "messages from",
                           "everything from", "all mail from", "all email from"]

    static let all: [RequestForm] = {
        let forms: [(String, Change, Bool)] = [
            ("keep <s>", .decide(.keep), true),
            ("always keep <s>", .decide(.keep), true),
            ("never sweep <s>", .decide(.keep), true),
            ("don't sweep <s>", .decide(.keep), true),
            ("stop sweeping <s>", .decide(.keep), true),
            ("sweep <s>", .decide(.sweep), true),
            ("always sweep <s>", .decide(.sweep), true),
            ("archive <s>", .destination(.archiveOnly), true),
            ("always archive <s>", .destination(.archiveOnly), true),
            ("set <s> to archive only", .destination(.archiveOnly), false),
            ("trash <s>", .destination(.trash), true),
            ("always trash <s>", .destination(.trash), true),
            ("bin <s>", .destination(.trash), true),
            ("send <s> to the trash", .destination(.trash), true),
            ("move <s> to the trash", .destination(.trash), true),
            ("set <s> to move to trash", .destination(.trash), false),
            ("file <s> into folders", .destination(.fileIntoFolders), true),
            ("set <s> to file into folders", .destination(.fileIntoFolders), false),
            ("let <s> follow my policy", .destination(nil), false),
            ("set <s> to follow my policy", .destination(nil), false),
            ("file <s> under <f>", .folder, true),
            ("file <s> into <f>", .folder, true),
            ("file <s> in <f>", .folder, true),
            ("put <s> in <f>", .folder, true),
            ("put <s> into <f>", .folder, true),
            ("put <s> under <f>", .folder, true),
            ("unsubscribe me from <s>", .unsubscribe(true), false),
            ("unsubscribe from <s>", .unsubscribe(true), false),
            ("never unsubscribe me from <s>", .unsubscribe(false), false),
            ("never unsubscribe from <s>", .unsubscribe(false), false),
            ("don't unsubscribe me from <s>", .unsubscribe(false), false),
            ("stop unsubscribing me from <s>", .unsubscribe(false), false)
        ]
        return forms.flatMap { text, change, takesMailFrom in
            (takesMailFrom ? RequestForm.mailFrom : [""]).flatMap { prefix in
                let sentence = text.replacingOccurrences(of: "<s>", with: prefix.isEmpty ? "<s>" : "\(prefix) <s>")
                let pieces = sentence.split(separator: " ").map { word -> Piece in
                    switch word {
                    case "<s>": .sender
                    case "<f>": .folder
                    default: .word(String(word))
                    }
                }
                return [RequestForm(pieces: pieces, change: change),
                        RequestForm(pieces: [.word("please")] + pieces, change: change)]
            }
        }
    }()

    /// The request split on spaces, keeping each word as typed, without the
    /// sentence's closing punctuation.
    static func words(in request: String) -> [String] {
        var text = request.replacingOccurrences(of: "\u{2019}", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".!".contains(last) { text.removeLast() }
        return text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Every way the words fit this form. A sender or folder whose name
    /// contains one of the form's words ("Life in Pictures") can fit more
    /// than one way; the caller keeps only readings that name real things.
    func readings(of words: [String]) -> [Reading] {
        var found: [Reading] = []
        func match(_ piece: Int, _ word: Int, sender: String?, folder: String?) {
            if piece == pieces.count {
                if word == words.count, let sender { found.append(Reading(change: change, sender: sender, folder: folder)) }
                return
            }
            switch pieces[piece] {
            case .word(let expected):
                guard word < words.count, words[word].lowercased() == expected else { return }
                match(piece + 1, word + 1, sender: sender, folder: folder)
            case .sender, .folder:
                let wordsAfter = pieces.count - piece - 1
                guard word < words.count - wordsAfter else { return }
                for end in (word + 1)...(words.count - wordsAfter) {
                    let name = words[word..<end].joined(separator: " ")
                    if pieces[piece] == .sender {
                        match(piece + 1, end, sender: name, folder: folder)
                    } else {
                        match(piece + 1, end, sender: sender, folder: name)
                    }
                }
            }
        }
        match(0, 0, sender: nil, folder: nil)
        return found
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
