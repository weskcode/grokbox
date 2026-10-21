import Foundation

/// The `<id@host>` tokens in a Message-ID, In-Reply-To or References value.
///
/// Only bracketed tokens with an `@` count: In-Reply-To written by old clients
/// can carry prose ("your message of 3 May") or a second, unrelated id, and a
/// folded References line can put whitespace anywhere. Brackets are dropped and
/// whitespace inside a token removed, so the same id written two ways compares
/// equal. Case is kept and ids compare as written.
public enum MessageIDList {
    /// A References chain is kept whole up to this length. Past it, the first id
    /// (the conversation root) and the most recent ones are what link a message.
    public static let maxReferences = 50

    public static func parse(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var ids: [String] = []
        var seen = Set<String>()
        var rest = Substring(raw)
        while let open = rest.firstIndex(of: "<") {
            let afterOpen = rest[rest.index(after: open)...]
            guard let close = afterOpen.firstIndex(of: ">") else { break }
            let id = String(afterOpen[..<close].filter { !$0.isWhitespace })
            if id.contains("@"), !id.hasPrefix("@"), !id.hasSuffix("@"), seen.insert(id).inserted { ids.append(id) }
            rest = afterOpen[afterOpen.index(after: close)...]
        }
        return ids
    }

    /// One Message-ID. Some servers write it without brackets; a bare value is
    /// accepted only when it is a single `local@domain` token.
    public static func messageID(_ raw: String?) -> String? {
        if let first = parse(raw).first { return first }
        guard let bare = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !bare.isEmpty,
              !bare.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }),
              let at = bare.firstIndex(of: "@"), at != bare.startIndex, bare.index(after: at) != bare.endIndex
        else { return nil }
        return bare
    }

    public static func references(_ raw: String?) -> [String] {
        let ids = parse(raw)
        guard ids.count > maxReferences else { return ids }
        return [ids[0]] + ids.suffix(maxReferences - 1)
    }
}

/// Which messages belong to one conversation, decided from RFC 5322 headers and
/// only falling back to the sender-and-subject `ThreadKey` when a message carries
/// no reply headers at all.
///
/// The result depends only on the set of messages given, never on their order,
/// so a duplicate fetch, an out-of-order sync or a renumbered mailbox (which
/// changes UIDs, not Message-IDs) produces the same grouping.
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

        let nodes: [[String]] = inputs.map { input in
            let ids = ([input.messageID].compactMap(\.self) + input.inReplyTo + input.references)
            return ids.map { "\(input.accountID.uuidString)|\($0)" }
        }
        for ids in nodes {
            for id in ids where parent[id] == nil { parent[id] = id }
            for id in ids.dropFirst() { joinKeepingSmallerRoot(ids[0], id) }
        }

        // Copies of one message (All Mail and Sent, or a duplicate fetch) share a
        // Message-ID and must count once, or a copy alone would look like a reply.
        let messages: [String] = inputs.indices.map { i in
            inputs[i].messageID.map { "\(inputs[i].accountID.uuidString)|\($0)" } ?? "#\(i)"
        }
        let roots: [String?] = nodes.map { $0.first.map(find) }
        var messagesPerRoot: [String: Set<String>] = [:]
        for (i, root) in roots.enumerated() { if let root { messagesPerRoot[root, default: []].insert(messages[i]) } }

        enum Link { case linked(root: String), unlinkedReply(root: String), headerless(key: String) }
        let links: [Link] = inputs.indices.map { i in
            let input = inputs[i]
            if let root = roots[i], (messagesPerRoot[root]?.count ?? 0) > 1 { return .linked(root: root) }
            if input.hasReplyHeaders, let root = roots[i] { return .unlinkedReply(root: root) }
            return .headerless(key: "subject|" + ThreadKey.key(accountID: input.accountID, senderAddress: input.senderAddress, subject: input.subject))
        }
        var messagesPerFallback: [String: Set<String>] = [:]
        for (i, link) in links.enumerated() { if case .headerless(let key) = link { messagesPerFallback[key, default: []].insert(messages[i]) } }

        return links.map { link in
            switch link {
            case .linked(let root): Assignment(key: "headers|" + root, evidence: .headers)
            case .unlinkedReply(let root): Assignment(key: "headers|" + root, evidence: .single)
            case .headerless(let key): Assignment(key: key, evidence: (messagesPerFallback[key]?.count ?? 0) > 1 ? .subjectFallback : .single)
            }
        }
    }
}
