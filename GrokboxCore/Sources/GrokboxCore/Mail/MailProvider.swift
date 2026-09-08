import Foundation

/// What a mail backend must be able to do for Grokbox.
///
/// The IMAP implementation is the only one today. The seam exists because the
/// Gmail API is a meaningfully better backend for Gmail accounts specifically —
/// `history.list` gives true incremental sync and `batchModify` moves a thousand
/// messages in one call — and that should be a swap, not a rewrite.
/// See docs/DECISIONS.md ADR-0002.
public protocol MailProvider: Sendable {
    var capabilities: IMAPCapabilities { get async }

    // Read-only
    func discoverMailboxes() async throws -> [IMAPMailbox]
    func openReadOnly(_ mailbox: String) async throws -> MailboxStatus
    func headers(from start: Int, to end: Int) async throws -> [FetchedHeader]
    func headers(uidsFrom start: UInt32) async throws -> [FetchedHeader]
    func flags(from start: Int, to end: Int) async throws -> [FlagUpdate]
    func bodyExcerpt(uid: UInt32) async throws -> Data?

    // Mutating — only PlanExecutor calls these
    func openReadWrite(_ mailbox: String) async throws -> MailboxStatus
    func setFlags(uids: [UInt32], _ change: IMAPClient.FlagChange, flags: [String]) async throws
    func setGmailLabels(uids: [UInt32], _ change: IMAPClient.FlagChange, labels: [String]) async throws
    @discardableResult
    func move(uids: [UInt32], to mailbox: String) async throws -> MoveResult
    func ensureMailbox(_ name: String) async throws

    func finish() async
}

/// IMAP-backed provider.
public struct IMAPMailProvider: MailProvider {
    private let client: IMAPClient

    private init(client: IMAPClient) {
        self.client = client
    }

    public static func connect(
        host: String,
        port: Int,
        security: IMAPSecurity,
        username: String,
        password: String
    ) async throws -> IMAPMailProvider {
        let client = IMAPClient()
        try await client.connect(host: host, port: port, security: security)
        do {
            try await client.login(username: username, password: password)
        } catch {
            await client.logout()
            throw error
        }
        return IMAPMailProvider(client: client)
    }

    /// Convenience: connect using an account's Keychain credential.
    @MainActor
    public static func connect(to account: MailAccount) async throws -> IMAPMailProvider {
        let password: String
        if account.kind.isDemo {
            // The demo password is a public constant; nothing to protect.
            password = DemoMailbox.password
        } else {
            guard let stored = try KeychainStore.password(for: account.keychainAccount) else {
                throw IMAPError.connectionFailed("No password saved for this account. Remove and re-add it.")
            }
            password = stored
        }
        return try await connect(
            host: account.host,
            port: account.port,
            security: account.security,
            username: account.username,
            password: password
        )
    }

    public var capabilities: IMAPCapabilities {
        get async { await client.capabilities }
    }

    public func discoverMailboxes() async throws -> [IMAPMailbox] {
        try await client.listMailboxes().filter(\.isSelectable)
    }

    public func openReadOnly(_ mailbox: String) async throws -> MailboxStatus {
        try await client.examine(mailbox)
    }

    public func headers(from start: Int, to end: Int) async throws -> [FetchedHeader] {
        try await client.fetchHeaders(from: start, to: end)
    }

    public func headers(uidsFrom start: UInt32) async throws -> [FetchedHeader] {
        try await client.fetchHeaders(uidsFrom: start)
    }

    public func flags(from start: Int, to end: Int) async throws -> [FlagUpdate] {
        try await client.fetchFlags(from: start, to: end)
    }

    public func bodyExcerpt(uid: UInt32) async throws -> Data? {
        try await client.fetchBodyExcerpt(uid: uid)
    }

    public func openReadWrite(_ mailbox: String) async throws -> MailboxStatus {
        try await client.select(mailbox)
    }

    public func setFlags(uids: [UInt32], _ change: IMAPClient.FlagChange, flags: [String]) async throws {
        try await client.store(uids: uids, change, flags: flags)
    }

    public func setGmailLabels(uids: [UInt32], _ change: IMAPClient.FlagChange, labels: [String]) async throws {
        try await client.storeGmailLabels(uids: uids, change, labels: labels)
    }

    @discardableResult
    public func move(uids: [UInt32], to mailbox: String) async throws -> MoveResult {
        try await client.move(uids: uids, to: mailbox)
    }

    public func ensureMailbox(_ name: String) async throws {
        try await client.createMailbox(name)
    }

    public func finish() async {
        await client.logout()
    }
}

extension Array where Element == IMAPMailbox {
    /// The mailbox holding everything received. Gmail exposes `\All`; other
    /// servers generally mean INBOX.
    public var primaryArchive: IMAPMailbox? {
        first(where: \.isAllMail)
            ?? first { $0.name.caseInsensitiveCompare("INBOX") == .orderedSame }
            ?? first
    }

    /// The Sent mailbox, used to learn who the user actually writes to.
    /// RFC 6154 `\Sent` first; then the names providers use when they do not
    /// advertise special-use, in the languages most accounts are set to.
    public var sentMailbox: IMAPMailbox? {
        if let flagged = first(where: \.isSent) { return flagged }
        let known = ["sent", "sent mail", "sent items", "sent messages", "envoyés", "envoyes", "éléments envoyés",
                     "gesendet", "gesendete objekte", "enviados", "elementos enviados", "inviata", "posta inviata",
                     "verzonden", "verzonden items", "enviadas", "itens enviados", "skickat", "sendt", "lähetetyt", "wysłane"]
        return first { box in
            let leaf = box.displayName.split(separator: Character(box.delimiter ?? "/")).last.map(String.init) ?? box.displayName
            return known.contains(leaf.lowercased())
        }
    }

    /// The hierarchy delimiter in use, from whichever entry reported one.
    public var hierarchyDelimiter: String {
        first { $0.delimiter != nil && $0.name.caseInsensitiveCompare("INBOX") != .orderedSame }?.delimiter
            ?? first { $0.delimiter != nil }?.delimiter ?? "/"
    }

    /// Some servers (Courier, older Dovecot setups) keep every user folder
    /// under `INBOX.`: `INBOX.Sent`, `INBOX.Archive`. Detected when every
    /// non-INBOX mailbox carries that prefix.
    public var personalNamespacePrefix: String {
        let others = filter { $0.name.caseInsensitiveCompare("INBOX") != .orderedSame }
        guard !others.isEmpty else { return "" }
        let prefix = "INBOX" + hierarchyDelimiter
        return others.allSatisfy { $0.name.uppercased().hasPrefix(prefix.uppercased()) } ? prefix : ""
    }

    /// Turns Grokbox's logical folder name (`Grokbox/Newsletters`) into what
    /// this server needs: its delimiter, its namespace prefix, modified UTF-7.
    public func serverName(forLogical logical: String) -> String {
        let parts = logical.split(separator: "/").map { IMAPUTF7.encode(String($0)) }
        return personalNamespacePrefix + parts.joined(separator: hierarchyDelimiter)
    }

    /// The Trash, by special-use flag or by the names providers use for it.
    public var trashMailbox: IMAPMailbox? {
        if let flagged = first(where: \.isTrash) { return flagged }
        let known = ["trash", "deleted items", "deleted messages", "bin", "corbeille", "papierkorb",
                     "papelera", "cestino", "prullenbak", "lixeira", "papperskorg", "kosz"]
        return first { box in
            let leaf = box.displayName.split(separator: Character(box.delimiter ?? "/")).last.map(String.init) ?? box.displayName
            return known.contains(leaf.lowercased())
        }
    }

    /// Where archived mail goes on a non-Gmail server.
    public var archiveMailbox: IMAPMailbox? {
        first(where: \.isArchive)
            ?? first { $0.name.caseInsensitiveCompare("Archive") == .orderedSame }
    }
}
