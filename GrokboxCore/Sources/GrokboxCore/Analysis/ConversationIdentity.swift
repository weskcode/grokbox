import Foundation

/// The `<id@host>` tokens in a Message-ID, In-Reply-To or References value,
/// read with the RFC 5322 grammar: comments and quoted phrases outside the
/// brackets are skipped, folding whitespace inside an id is dropped, and a
/// quoted local part that needs no quotes compares equal to the bare form
/// (RFC 5256 §6.4). Old clients put prose and stray addresses in In-Reply-To;
/// only well-formed `local@domain` ids survive. Case is kept and ids compare as written.
public enum MessageIDList {
    public static func parse(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        let chars = Array(raw)
        var ids: [String] = []
        var seen = Set<String>()
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case "(": i = skipComment(chars, from: i)
            case "\"": i = skipQuoted(chars, from: i)
            case "<":
                let (id, next) = scanID(chars, from: i + 1)
                if let id, seen.insert(id).inserted { ids.append(id) }
                i = next
            default: i += 1
            }
        }
        return ids
    }

    /// One Message-ID. Some servers write it without brackets; a bare value is
    /// accepted only when it is a single `local@domain` token.
    public static func messageID(_ raw: String?) -> String? {
        if let first = parse(raw).first { return first }
        guard let bare = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !bare.isEmpty,
              !bare.contains(where: { $0.isWhitespace || "<>()\"".contains($0) }),
              let at = bare.firstIndex(of: "@"), at != bare.startIndex, bare.index(after: at) != bare.endIndex
        else { return nil }
        return bare
    }

    private static let atext = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-/=?^_`{|}~.")

    private static func skipComment(_ c: [Character], from start: Int) -> Int {
        var depth = 0, i = start
        while i < c.count {
            switch c[i] {
            case "\\": i += 1
            case "(": depth += 1
            case ")": depth -= 1; if depth == 0 { return i + 1 }
            default: break
            }
            i += 1
        }
        return i
    }

    private static func skipQuoted(_ c: [Character], from start: Int) -> Int {
        var i = start + 1
        while i < c.count {
            if c[i] == "\\" { i += 2; continue }
            if c[i] == "\"" { return i + 1 }
            i += 1
        }
        return i
    }

    /// Reads up to the closing `>`. The local part keeps quoted content exactly,
    /// including spaces; everything else drops whitespace.
    private static func scanID(_ c: [Character], from start: Int) -> (String?, Int) {
        var local = "", domain = "", inDomain = false, inQuotes = false, needsQuotes = false
        var i = start
        while i < c.count {
            let ch = c[i]
            if inQuotes {
                if ch == "\\", i + 1 < c.count { i += 1; local.append(c[i]); if !atext.contains(c[i]) { needsQuotes = true } }
                else if ch == "\"" { inQuotes = false }
                else if !(ch.isNewline) { local.append(ch); if !atext.contains(ch) { needsQuotes = true } }
            } else if ch == ">" {
                guard !local.isEmpty, !domain.isEmpty else { return (nil, i + 1) }
                let left = needsQuotes ? "\"" + local.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" : local
                return (left + "@" + domain, i + 1)
            } else if ch == "<" {
                return (nil, i)
            } else if !ch.isWhitespace {
                if !inDomain && ch == "\"" { inQuotes = true }
                else if !inDomain && ch == "@" { inDomain = true }
                else if inDomain { domain.append(ch) }
                else { local.append(ch) }
            }
            i += 1
        }
        return (nil, i)
    }
}

/// Which messages belong to one conversation, decided from RFC 5322 headers and
/// only falling back to the sender-and-subject `ThreadKey` when a message carries
/// no reply headers at all.
///
/// The result depends only on the set of messages given, never on their order,
/// so an out-of-order sync or a renumbered mailbox (which changes UIDs, not
/// Message-IDs) produces the same grouping. Copies are recognised by Message-ID
/// and always share one assignment; two inputs without a Message-ID are two
/// messages, because nothing in their headers can tell a copy from a lookalike.
public enum ConversationIdentity {
    public struct Input: Sendable, Equatable {
        public var accountID: UUID
        public var messageID: String?
        public var inReplyTo: [String]
        public var references: [String]
        public var senderAddress: String
        public var subject: String

        public init(accountID: UUID, messageID: String?, inReplyTo: [String] = [], references: [String] = [],
                    senderAddress: String, subject: String) {
            self.accountID = accountID
            self.messageID = messageID
            self.inReplyTo = inReplyTo
            self.references = references
            self.senderAddress = senderAddress
            self.subject = subject
        }

        /// The same message from an inbox fetch or a Sent fetch; the UID plays no part.
        public init(accountID: UUID, header: FetchedHeader) {
            self.init(accountID: accountID, messageID: MessageIDList.messageID(header.messageID),
                      inReplyTo: header.inReplyTo, references: header.references,
                      senderAddress: header.senderAddress, subject: header.subject)
        }

        public var hasReplyHeaders: Bool { !inReplyTo.isEmpty || !references.isEmpty }
    }

    /// How sure the grouping is. Only `.headers` is evidence; `.subjectFallback`
    /// is a guess and must be presented as one.
    public enum Evidence: String, Sendable, Equatable {
        /// Linked to at least one other message by Message-ID, In-Reply-To or References.
        case headers
        /// Grouped with others only because sender and normalized subject match,
        /// and none of them carries reply headers.
        case subjectFallback
        /// No other message in the set belongs with it.
        case single
    }

    public struct Assignment: Sendable, Equatable {
        /// Stable for a given set of messages. Not a durable identifier: it can
        /// change when an earlier message of the conversation is indexed later.
        public var key: String
        public var evidence: Evidence
    }

    /// One assignment per input, in input order.
    public static func assign(_ inputs: [Input]) -> [Assignment] {
        var copiesOf: [[Int]] = []
        var messageOf: [Int] = []
        var messageByID: [String: Int] = [:]
        for (i, input) in inputs.enumerated() {
            if let id = input.messageID {
                let scoped = "\(input.accountID.uuidString)|\(id)"
                if let m = messageByID[scoped] { copiesOf[m].append(i); messageOf.append(m); continue }
                messageByID[scoped] = copiesOf.count
            }
            messageOf.append(copiesOf.count)
            copiesOf.append([i])
        }

        var parent: [String: String] = [:]
        func find(_ node: String) -> String {
            var root = node
            while let up = parent[root], up != root { root = up }
            var walk = node
            while let up = parent[walk], up != root { parent[walk] = root; walk = up }
            return root
        }
        func joinKeepingSmallerRoot(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            if ra < rb { parent[rb] = ra } else { parent[ra] = rb }
        }

        // RFC 5256 §6.4: References when present, else only the first In-Reply-To id.
        // Old clients append the sender's address to In-Reply-To, and linking it
        // would join every conversation that address ever replied in.
        func parents(_ input: Input) -> [String] {
            input.references.isEmpty ? Array(input.inReplyTo.prefix(1)) : input.references
        }
        let nodes: [[String]] = copiesOf.map { copies in
            copies.flatMap { i in
                ([inputs[i].messageID].compactMap(\.self) + parents(inputs[i])).map { "\(inputs[i].accountID.uuidString)|\($0)" }
            }
        }
        for ids in nodes {
            for id in ids where parent[id] == nil { parent[id] = id }
            for id in ids.dropFirst() { joinKeepingSmallerRoot(ids[0], id) }
        }

        let roots: [String?] = nodes.map { $0.first.map(find) }
        var messagesPerRoot: [String: Int] = [:]
        for root in roots.compactMap(\.self) { messagesPerRoot[root, default: 0] += 1 }

        enum Link { case linked(root: String), unlinkedReply(root: String), headerless(key: String) }
        let links: [Link] = copiesOf.indices.map { m in
            let copies = copiesOf[m].map { inputs[$0] }
            if let root = roots[m], (messagesPerRoot[root] ?? 0) > 1 { return .linked(root: root) }
            if let root = roots[m], copies.contains(where: \.hasReplyHeaders) { return .unlinkedReply(root: root) }
            let keys = copies.map { "subject|" + ThreadKey.key(accountID: $0.accountID, senderAddress: $0.senderAddress, subject: $0.subject) }
            return .headerless(key: keys.min() ?? "")
        }
        var messagesPerFallback: [String: Int] = [:]
        for case .headerless(let key) in links { messagesPerFallback[key, default: 0] += 1 }

        let perMessage: [Assignment] = links.map { link in
            switch link {
            case .linked(let root): Assignment(key: "headers|" + root, evidence: .headers)
            case .unlinkedReply(let root): Assignment(key: "headers|" + root, evidence: .single)
            case .headerless(let key): Assignment(key: key, evidence: (messagesPerFallback[key] ?? 0) > 1 ? .subjectFallback : .single)
            }
        }
        return messageOf.map { perMessage[$0] }
    }
}
