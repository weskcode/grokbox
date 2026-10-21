import Foundation

/// A sender Grokbox has indexed, as the proposal step needs it. One address
/// can appear once per account.
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
        /// The sentence fits more than one form or name with different results.
        case ambiguousRequest
        case wholeDomain(String)
        case unknownSender(String)
        case ambiguousSender([String])
        /// Typed requests may tighten a sender's rule but never approve one;
        /// approval stays with Sweep and Senders (ADR-0007).
        case notApproved(String)
        case unknownFolder(String)
        case ambiguousFolder([String])
        /// The inbox, Trash, Junk, Sent, Drafts, All Mail or Archive: filing
        /// into one would be a different action wearing a folder's name.
        case reservedFolder(String)
        case noOneClickLink(String)
        case conflict(String)
        case nothingToChange
    }

    /// Longer than any supported sentence with long names; refused unread.
    static let wordLimit = 40

    /// Reads a request against the senders, rules, folders and policy that
    /// exist now. `folders` are filing destinations: category folders, folders
    /// rules already use, and server mailboxes that are not special-use.
    ///
    /// The whole sentence must be one supported form. Anything else, such as
    /// "trash this message from Medium" or "archive Medium older than 30
    /// days", creates nothing rather than a broader rule than was asked for.
    static func make(request: String, senders: [KnownSender], rules: [String: SenderOverride],
                     folders: Set<String>, policy: CleanupPolicy) -> RuleProposal {
        let words = request.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count <= wordLimit else { return .unresolved(.unsupported) }
        let readings = RequestForm.all.flatMap { $0.readings(of: words) }
        guard !readings.isEmpty else { return .unresolved(.unsupported) }

        let book = SenderBook(senders: senders, rules: rules)
        var targets: Set<Target> = []
        var failures: [Unresolved] = []
        for reading in Set(readings) {
            switch target(for: reading, in: book, folders: folders) {
            case .success(let target): targets.insert(target)
            case .failure(let failure): failures.append(failure.reason)
            }
        }
        if let failure = verdict(targets: targets, failures: failures) { return .unresolved(failure) }
        guard let target = targets.first else { return .unresolved(.unsupported) }

        let entries = senders.filter { $0.address == target.address }
        let before = rules[target.address]
        if before?.decision != .sweep, target.change != .decide(.keep) {
            return .unresolved(.notApproved(target.address))
        }

        var after = before ?? SenderOverride(decision: .keep)
        switch target.change {
        case .decide(let decision): after.decision = decision
        case .destination(let disposition): after.disposition = disposition
        case .unsubscribe(let allowed):
            if allowed, !entries.contains(where: \.supportsOneClickUnsubscribe) {
                return .unresolved(.noOneClickLink(target.address))
            }
            after.autoUnsubscribe = allowed
        case .folder:
            after.customFolder = target.folder
            after.disposition = .fileIntoFolders
        }
        if after == before { return .unresolved(.nothingToChange) }

        // A folder means nothing unless the sender's mail is filed, and the
        // policy can change after this draft. Only a change that makes or
        // touches the mismatch is refused; an old one does not block an
        // unrelated edit.
        if let kept = Self.unusedFolder(after), target.change.touchesWhereMailGoes || Self.unusedFolder(before) == nil {
            return .unresolved(.conflict("This sender files into \(kept). Clear that folder before changing where its mail goes."))
        }

        let effects = Effects(categories: Set(entries.map(\.category)), policy: policy)
        return .draft(RuleDraft(address: target.address, before: before, after: after,
                                irreversibleEffects: effects.irreversible(from: before, to: after)))
    }

    private static func unusedFolder(_ rule: SenderOverride?) -> String? {
        guard let rule, rule.decision == .sweep, let folder = rule.customFolder, rule.disposition != .fileIntoFolders else { return nil }
        return folder
    }

    /// Sender names are chosen by senders, so a reading that resolves cannot
    /// outvote another that found two senders or folders. The candidates of
    /// every ambiguous reading are shown together.
    private static func verdict(targets: Set<Target>, failures: [Unresolved]) -> Unresolved? {
        var senders: [String] = []
        var folders: [String] = []
        for failure in failures {
            if case .ambiguousSender(let candidates) = failure { senders += candidates }
            if case .ambiguousFolder(let candidates) = failure { folders += candidates }
        }
        if targets.count > 1 || (!targets.isEmpty && !(senders.isEmpty && folders.isEmpty)) { return .ambiguousRequest }
        if !targets.isEmpty { return nil }
        if !senders.isEmpty { return .ambiguousSender(Array(Set(senders)).sorted()) }
        if !folders.isEmpty { return .ambiguousFolder(Array(Set(folders)).sorted()) }
        return failures.min { $0.rank < $1.rank } ?? .unsupported
    }

    private struct Target: Hashable {
        var address: String
        var folder: String?
        var change: RequestForm.Change
    }

    private struct Failure: Error { var reason: Unresolved }

    /// Every address and display name, normalized once per request.
    private struct SenderBook {
        var addresses: Set<String>
        var names: [(name: String, address: String)]

        init(senders: [KnownSender], rules: [String: SenderOverride]) {
            addresses = Set(senders.map(\.address) + rules.keys)
            names = senders.map { (name: RuleProposal.spaced($0.displayName), address: $0.address) }
        }
    }

    static func spaced(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Names a mailbox may not be filed into, whatever the server calls it.
    static let reservedFolderNames: Set<String> = [
        "inbox", "trash", "bin", "deleted items", "deleted messages", "junk", "junk e-mail", "junk email", "spam",
        "sent", "sent items", "sent mail", "sent messages", "drafts", "all mail", "archive", "outbox"
    ]

    /// Resolves the words the person typed, spelled as they typed them.
    private static func target(for reading: RequestForm.Reading, in book: SenderBook,
                               folders: Set<String>) -> Result<Target, Failure> {
        let named = reading.sender
        // Exact address first, then an exact display name. Display names are
        // written by senders, so two that collide are shown, never guessed between.
        var matches = book.addresses.filter { $0.caseInsensitiveCompare(named) == .orderedSame }
        if matches.isEmpty {
            matches = Set(book.names.filter { $0.name.caseInsensitiveCompare(named) == .orderedSame }.map(\.address))
        }
        if matches.count > 1 { return .failure(Failure(reason: .ambiguousSender(matches.sorted()))) }
        guard let address = matches.first else {
            let looksLikeDomain = !named.contains(" ") && (named.hasPrefix("@") || named.contains("*") || (named.contains(".") && !named.contains("@")))
            return .failure(Failure(reason: looksLikeDomain ? .wholeDomain(named) : .unknownSender(named)))
        }

        var folder: String?
        if let typed = reading.folder {
            let leaf = typed.split(separator: "/").last.map(String.init) ?? typed
            if reservedFolderNames.contains(leaf.lowercased()) || typed.lowercased().hasPrefix("[gmail]") {
                return .failure(Failure(reason: .reservedFolder(typed)))
            }
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
        case .reservedFolder: 0
        case .unknownFolder: 1
        case .wholeDomain: 2
        case .unknownSender: 3
        default: 4
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

        var touchesWhereMailGoes: Bool {
            switch self {
            case .destination, .folder: true
            case .decide, .unsubscribe: false
            }
        }
    }

    enum Piece: Sendable, Equatable {
        case word(String)
        case sender
        case folder
    }

    struct Reading: Sendable, Hashable {
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
            ("send <s> to trash", .destination(.trash), true),
            ("move <s> to the trash", .destination(.trash), true),
            ("move <s> to trash", .destination(.trash), true),
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
            ("don't unsubscribe from <s>", .unsubscribe(false), false),
            ("stop unsubscribing me from <s>", .unsubscribe(false), false),
            ("stop unsubscribing from <s>", .unsubscribe(false), false)
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

    /// Every way the words fit this form. Form words are compared loosely
    /// (case, a curly apostrophe, a closing "." or "!"); sender and folder
    /// names are kept exactly as typed. A name that ends the sentence is
    /// read both with and without its closing punctuation, since "Yahoo!" may
    /// be a name. A name containing a form word ("Life in Pictures") can fit
    /// more than one way; the caller keeps only readings that name real things.
    func readings(of words: [String]) -> [Reading] {
        var found: [Reading] = []
        func loose(_ index: Int) -> String {
            var word = words[index].lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            if index == words.count - 1 { while let last = word.last, ".!".contains(last) { word.removeLast() } }
            return word
        }
        func names(_ range: Range<Int>) -> [String] {
            let typed = words[range].joined(separator: " ")
            guard range.upperBound == words.count else { return [typed] }
            var bare = typed
            while let last = bare.last, ".!".contains(last) { bare.removeLast() }
            return bare == typed || bare.isEmpty ? [typed] : [typed, bare]
        }
        func match(_ piece: Int, _ word: Int, sender: String?, folder: String?) {
            if piece == pieces.count {
                if word == words.count, let sender { found.append(Reading(change: change, sender: sender, folder: folder)) }
                return
            }
            switch pieces[piece] {
            case .word(let expected):
                guard word < words.count, loose(word) == expected else { return }
                match(piece + 1, word + 1, sender: sender, folder: folder)
            case .sender, .folder:
                let wordsAfter = pieces.count - piece - 1
                guard word < words.count - wordsAfter else { return }
                for end in (word + 1)...(words.count - wordsAfter) {
                    for name in names(word..<end) {
                        if pieces[piece] == .sender {
                            match(piece + 1, end, sender: name, folder: folder)
                        } else {
                            match(piece + 1, end, sender: sender, folder: name)
                        }
                    }
                }
            }
        }
        match(0, 0, sender: nil, folder: nil)
        return found
    }
}

/// What a rule actually does once the policy fills in what it leaves open.
/// With no indexed category, every category is assumed, so a warning errs
/// toward showing.
private struct Effects {
    var categories: Set<SenderCategory>
    var policy: CleanupPolicy

    private func trashes(_ rule: SenderOverride?) -> Bool {
        guard let rule, rule.decision == .sweep else { return false }
        if let disposition = rule.disposition { return disposition == .trash }
        let possible = categories.isEmpty ? Set(SenderCategory.allCases) : categories
        return possible.contains { policy.disposition(for: $0) == .trash }
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
