import Foundation

/// One indexed row for the sender a request is about. An address can have
/// one row per account.
struct KnownSender: Sendable, Equatable {
    var category: SenderCategory
    var supportsOneClickUnsubscribe: Bool
}

/// The outcome of reading a typed request about one sender, such as "file
/// them under Reading": a draft for the person to preview and confirm, or a
/// reason nothing was drafted. Neither writes anything.
///
/// The sender is fixed by where the request was typed (that sender's own
/// rule menu), never read from the sentence. Display names are chosen by
/// senders, so a sentence that named one could be captured by a sender
/// whose name swallows the rest of it.
enum RuleProposal: Sendable, Equatable {
    case draft(RuleDraft)
    case unresolved(Unresolved)

    enum Unresolved: Sendable, Equatable {
        /// The sentence is not one of the forms in `RequestForm.all`.
        case unsupported
        /// The sentence fits more than one form with different results, or
        /// one reading works and another does not.
        case ambiguousRequest
        /// Typed requests may tighten a sender's rule but never approve one;
        /// approval stays with Sweep and Senders (ADR-0007).
        case notApproved
        case unknownFolder(String)
        case ambiguousFolder([String])
        /// The inbox, Trash, Junk, Sent, Drafts, All Mail or Archive: filing
        /// into one would be a different action wearing a folder's name.
        case reservedFolder(String)
        case noOneClickLink
        case conflict(String)
        case nothingToChange
    }

    /// Longer than any supported sentence with a long folder name; refused unread.
    static let wordLimit = 30

    /// Reads a request about the sender at `address`. `indexed` are that
    /// sender's rows, `rule` its current rule. `folders` are filing
    /// destinations: category folders, folders rules already use, and
    /// server mailboxes that are not special-use.
    ///
    /// The whole sentence must be one supported form. Anything else, such as
    /// "trash this one" or "archive them after 30 days", creates nothing
    /// rather than a broader rule than was asked for.
    static func make(request: String, address: String, indexed: [KnownSender], rule before: SenderOverride?,
                     folders: Set<String>, policy: CleanupPolicy) -> RuleProposal {
        let words = request.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count <= wordLimit else { return .unresolved(.unsupported) }
        let readings = Set(RequestForm.all.flatMap { $0.readings(of: words) })
        guard !readings.isEmpty else { return .unresolved(.unsupported) }

        var targets: Set<Target> = []
        var failures: [Unresolved] = []
        for reading in readings {
            switch target(for: reading, folders: folders) {
            case .success(let target): targets.insert(target)
            case .failure(let failure): failures.append(failure.reason)
            }
        }
        // A reading that works cannot outvote one that failed: the person may
        // have meant that one.
        if targets.count > 1 || (!targets.isEmpty && !failures.isEmpty) { return .unresolved(.ambiguousRequest) }
        guard let target = targets.first else {
            return .unresolved(failures.min { ($0.rank, "\($0)") < ($1.rank, "\($1)") } ?? .unsupported)
        }

        if before?.decision != .sweep, target.change != .decide(.keep) { return .unresolved(.notApproved) }

        var after = before ?? SenderOverride(decision: .keep)
        switch target.change {
        case .decide(let decision): after.decision = decision
        case .destination(let disposition): after.disposition = disposition
        case .unsubscribe(let allowed):
            if allowed, !indexed.contains(where: \.supportsOneClickUnsubscribe) { return .unresolved(.noOneClickLink) }
            after.autoUnsubscribe = allowed
        case .folder:
            after.customFolder = target.folder
            after.disposition = .fileIntoFolders
        }

        // A folder means nothing unless the sender's mail is filed, and the
        // policy can change after this draft. Only a change that makes or
        // touches the mismatch is refused, even when it restates what is
        // stored; an old one does not block an unrelated edit.
        if let kept = unusedFolder(after), target.change.touchesWhereMailGoes || unusedFolder(before) == nil {
            return .unresolved(.conflict("This sender files into \(kept). Clear that folder before changing where its mail goes."))
        }
        if after == before { return .unresolved(.nothingToChange) }

        let effects = Effects(categories: Set(indexed.map(\.category)), policy: policy)
        return .draft(RuleDraft(address: address, before: before, after: after,
                                irreversibleEffects: effects.irreversible(from: before, to: after)))
    }

    private static func unusedFolder(_ rule: SenderOverride?) -> String? {
        guard let rule, rule.decision == .sweep, let folder = rule.customFolder, rule.disposition != .fileIntoFolders else { return nil }
        return folder
    }

    private struct Target: Hashable {
        var folder: String?
        var change: RequestForm.Change
    }

    private struct Failure: Error { var reason: Unresolved }

    /// The one comparison used for folder names: compatibility-normalized,
    /// case- and width-folded, whitespace collapsed. "Traſh" is "trash"
    /// here, so no check can pass one spelling and resolve another.
    static func fold(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Mail filed anywhere under one of these is on its way out.
    static let disposalFolderNames: Set<String> = Set([IMAPMailbox].trashNames.union([
        "junk", "junk e-mail", "junk email", "junk-mail", "junk mail", "spam", "bulk mail", "courrier indésirable",
        "indésirables", "pourriel", "spamverdacht", "correo no deseado", "posta indesiderata", "ongewenste e-mail",
        "lixo eletrônico", "skräppost"
    ]).map(fold))

    /// Names a mailbox may not be filed into, whatever the server calls it.
    /// Sent names include the ones `sentMailbox` recognizes.
    static let reservedFolderNames: Set<String> = disposalFolderNames
        .union([IMAPMailbox].sentNames.map(fold))
        .union(["messages envoyés", "inbox", "drafts", "all mail", "archive", "outbox", "brouillons", "entwürfe",
                "borradores", "bozze", "concepten", "rascunhos"].map(fold))

    /// Words that put a condition on a request. A bare one-word folder name
    /// that is one of these is not read as a name; quoted, it is.
    static let conditionWords: Set<String> = [
        "older", "newer", "than", "after", "before", "since", "until", "unless", "except", "only", "if", "when",
        "whenever", "day", "days", "week", "weeks", "month", "months", "year", "years", "today", "yesterday",
        "tomorrow", "ago", "unread", "subject", "contains", "containing", "attachment", "attachments",
        "message", "messages", "and", "or", "but", "not", "then", "also"
    ]

    static func holdsCondition(_ folder: String) -> Bool {
        fold(folder).split { !$0.isLetter && !$0.isNumber }.contains { conditionWords.contains(String($0)) }
    }

    /// Whether filing into `folder` would really be a different action.
    /// Paths split on "/" and on "." (`INBOX.Trash`), and a leading "the"
    /// is ignored, so "the trash" is the Trash. A "." inside an ordinary
    /// name is read as a separator too; the cost is refusing a folder such
    /// as "bin.packing", which the folder picker can still set.
    static func isReserved(_ folder: String) -> Bool {
        var name = fold(folder)
        if name.hasPrefix("the ") { name.removeFirst(4) }
        if name.hasPrefix("[gmail]") || name.hasPrefix("[google mail]") { return true }
        let parts = name.split { $0 == "/" || $0 == "." }.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let leaf = parts.last else { return true }
        return reservedFolderNames.contains(leaf) || parts.contains { disposalFolderNames.contains($0) }
    }

    /// Resolves the folder the person typed, spelled as they typed it, and
    /// checks the folder it resolves to as well.
    private static func target(for reading: RequestForm.Reading, folders: Set<String>) -> Result<Target, Failure> {
        guard let typed = reading.folder else { return .success(Target(folder: nil, change: reading.change)) }
        if isReserved(typed) { return .failure(Failure(reason: .reservedFolder(typed))) }
        let loose = folders.filter { fold($0) == fold(typed) }
        let folder: String
        if folders.contains(typed) {
            folder = typed
        } else if loose.count == 1, let only = loose.first {
            folder = only
        } else if loose.isEmpty {
            return .failure(Failure(reason: .unknownFolder(typed)))
        } else {
            return .failure(Failure(reason: .ambiguousFolder(loose.sorted())))
        }
        if isReserved(folder) { return .failure(Failure(reason: .reservedFolder(folder))) }
        return .success(Target(folder: folder, change: reading.change))
    }
}

private extension RuleProposal.Unresolved {
    /// Which failure explains a request best when every reading of it failed.
    var rank: Int {
        switch self {
        case .reservedFolder: 0
        case .ambiguousFolder: 1
        case .unknownFolder: 2
        default: 3
        }
    }
}

/// The sentences a request may be, word for word apart from a folder name.
/// This is the whole v1 grammar: one change to the sender whose menu it was
/// typed in, in English.
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
        case folder
    }

    struct Reading: Sendable, Hashable {
        var change: Change
        var folder: String?
    }

    var pieces: [Piece]
    var change: Change

    /// Fixed ways to refer to the sender whose menu this is. Never a name.
    static let objects = ["them", "these", "it", "this sender", "their mail", "all their mail", "everything from them"]

    static let all: [RequestForm] = {
        // <o> is one of `objects`; [o] is that or nothing.
        let forms: [(String, Change)] = [
            ("keep [o]", .decide(.keep)),
            ("always keep [o]", .decide(.keep)),
            ("never sweep [o]", .decide(.keep)),
            ("don't sweep [o]", .decide(.keep)),
            ("stop sweeping [o]", .decide(.keep)),
            ("sweep [o]", .decide(.sweep)),
            ("always sweep [o]", .decide(.sweep)),
            ("archive [o]", .destination(.archiveOnly)),
            ("always archive [o]", .destination(.archiveOnly)),
            ("archive only", .destination(.archiveOnly)),
            ("set [o] to archive only", .destination(.archiveOnly)),
            ("trash [o]", .destination(.trash)),
            ("always trash [o]", .destination(.trash)),
            ("bin [o]", .destination(.trash)),
            ("send <o> to the trash", .destination(.trash)),
            ("send <o> to trash", .destination(.trash)),
            ("move <o> to the trash", .destination(.trash)),
            ("move <o> to trash", .destination(.trash)),
            ("file [o] into folders", .destination(.fileIntoFolders)),
            ("set [o] to file into folders", .destination(.fileIntoFolders)),
            ("follow my policy", .destination(nil)),
            ("let <o> follow my policy", .destination(nil)),
            ("set [o] to follow my policy", .destination(nil)),
            ("file [o] under <f>", .folder),
            ("file [o] into <f>", .folder),
            ("file [o] in <f>", .folder),
            ("put <o> in <f>", .folder),
            ("put <o> into <f>", .folder),
            ("put <o> under <f>", .folder),
            ("unsubscribe", .unsubscribe(true)),
            ("unsubscribe me", .unsubscribe(true)),
            ("unsubscribe me from <o>", .unsubscribe(true)),
            ("unsubscribe from <o>", .unsubscribe(true)),
            ("never unsubscribe", .unsubscribe(false)),
            ("never unsubscribe me", .unsubscribe(false)),
            ("never unsubscribe me from <o>", .unsubscribe(false)),
            ("never unsubscribe from <o>", .unsubscribe(false)),
            ("don't unsubscribe me", .unsubscribe(false)),
            ("don't unsubscribe me from <o>", .unsubscribe(false)),
            ("don't unsubscribe from <o>", .unsubscribe(false)),
            ("stop unsubscribing me", .unsubscribe(false)),
            ("stop unsubscribing me from <o>", .unsubscribe(false)),
            ("stop unsubscribing from <o>", .unsubscribe(false))
        ]
        return forms.flatMap { text, change -> [RequestForm] in
            let objects: [String] = text.contains("<o>") ? RequestForm.objects
                : text.contains("[o]") ? [""] + RequestForm.objects : [""]
            return objects.flatMap { object -> [RequestForm] in
                let sentence = text.replacingOccurrences(of: "<o>", with: object).replacingOccurrences(of: "[o]", with: object)
                let pieces = sentence.split(separator: " ").map { $0 == "<f>" ? Piece.folder : .word(String($0)) }
                // "Too" never follows a folder, so a folder name ends the sentence.
                let tails: [[Piece]] = change == .folder ? [[]] : [[], [.word("too")]]
                return [[], [Piece.word("please")]].flatMap { lead in
                    tails.map { tail in RequestForm(pieces: lead + pieces + tail, change: change) }
                }
            }
        }
    }()

    /// Every way the words fit this form. Form words are compared loosely
    /// (case, a curly apostrophe, a closing "." or "!"); the folder name is
    /// kept as typed apart from the sentence's closing punctuation.
    ///
    /// A bare folder name is one word or path ("Reading", "Clients/VIP"). A
    /// name of several words must be quoted ("Reading 2026" in quotes), so
    /// trailing words such as "from last Tuesday" can never be taken for
    /// part of a name. A bare "folders" means the filing disposition, and a
    /// bare word that is itself a condition ("unread") is not a name.
    func readings(of words: [String]) -> [Reading] {
        var found: [Reading] = []
        func loose(_ index: Int) -> String {
            var word = words[index].lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            if index == words.count - 1 { while let last = word.last, ".!".contains(last) { word.removeLast() } }
            return word
        }
        func name(_ range: Range<Int>) -> String? {
            var typed = words[range].joined(separator: " ")
            if range.upperBound == words.count { while let last = typed.last, ".!".contains(last) { typed.removeLast() } }
            let quotes = "\"\u{201C}\u{201D}"
            if typed.count > 2, let first = typed.first, let last = typed.last,
               "\"\u{201C}".contains(first), "\"\u{201D}".contains(last) {
                let inner = typed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                return inner.isEmpty || inner.contains(where: { quotes.contains($0) }) ? nil : inner
            }
            guard range.count == 1, !typed.contains(where: { quotes.contains($0) }) else { return nil }
            return RuleProposal.fold(typed) == "folders" || RuleProposal.holdsCondition(typed) ? nil : typed
        }
        func match(_ piece: Int, _ word: Int, folder: String?) {
            if piece == pieces.count {
                if word == words.count { found.append(Reading(change: change, folder: folder)) }
                return
            }
            switch pieces[piece] {
            case .word(let expected):
                guard word < words.count, loose(word) == expected else { return }
                match(piece + 1, word + 1, folder: folder)
            case .folder:
                let wordsAfter = pieces.count - piece - 1
                guard word < words.count - wordsAfter else { return }
                for end in (word + 1)...(words.count - wordsAfter) {
                    if let name = name(word..<end) { match(piece + 1, end, folder: name) }
                }
            }
        }
        match(0, 0, folder: nil)
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
