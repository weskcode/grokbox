import Foundation

/// The demo mailbox itself: generated messages plus the operations Grokbox
/// performs on a mailbox. No sockets. `DemoMailProvider` calls this directly
/// inside the app; `DemoMailServer` puts an IMAP front on it for the tests.
public final class DemoMailbox: @unchecked Sendable {
    public static let password = "demo"
    public static let uidValidity: UInt32 = 1_725_000_000
    public static let allMail = "[Gmail]/All Mail"

    /// The mailbox's UIDVALIDITY. An instance value so a test can simulate the
    /// one thing that makes stored UIDs meaningless: a server renumbering.
    public var uidValidity: UInt32 = DemoMailbox.uidValidity

    public let persona: DemoPersona
    public var username: String { persona.username }

    private let lock = NSLock()
    private var store: [String: [DemoMailServer.Message]]

    public init(persona: DemoPersona) {
        self.persona = persona
        store = DemoCorpus.generate(persona: persona)
    }

    public var capabilities: IMAPCapabilities {
        IMAPCapabilities(raw: ["IMAP4REV1", "UNSELECT", "IDLE", "NAMESPACE", "X-GM-EXT-1", "UIDPLUS", "MOVE"])
    }

    // MARK: - Reads

    public func listMailboxes() -> [IMAPMailbox] {
        [
            IMAPMailbox(name: "INBOX", attributes: ["\\HasNoChildren"]),
            IMAPMailbox(name: "[Gmail]", attributes: ["\\HasChildren", "\\Noselect"]),
            IMAPMailbox(name: Self.allMail, attributes: ["\\All", "\\HasNoChildren"]),
            IMAPMailbox(name: "[Gmail]/Sent Mail", attributes: ["\\HasNoChildren", "\\Sent"]),
            IMAPMailbox(name: "[Gmail]/Trash", attributes: ["\\HasNoChildren", "\\Trash"]),
        ]
    }

    public func exists(_ mailbox: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return store[mailbox] != nil || mailbox == "INBOX"
    }

    public func status(_ mailbox: String) -> MailboxStatus {
        MailboxStatus(exists: messages(in: mailbox).count, uidValidity: uidValidity)
    }

    /// Current messages in a mailbox, ascending UID. INBOX is virtual: the All
    /// Mail messages still carrying `\Inbox`, the way Gmail presents it.
    public func messages(in mailbox: String) -> [DemoMailServer.Message] {
        lock.lock(); defer { lock.unlock() }
        return unlockedMessages(in: mailbox)
    }

    private func unlockedMessages(in mailbox: String) -> [DemoMailServer.Message] {
        if mailbox == "INBOX" { return (store[Self.allMail] ?? []).filter { $0.labels.contains("\\Inbox") } }
        return store[mailbox] ?? []
    }

    public func nextUID(in mailbox: String) -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return (store[mailbox]?.last?.uid ?? 0) + 1
    }

    public func headers(in mailbox: String, from start: Int, to end: Int) -> [FetchedHeader] {
        let all = messages(in: mailbox)
        guard start >= 1, start <= all.count else { return [] }
        return all[(start - 1)..<min(end, all.count)].map(Self.header)
    }

    public func headers(in mailbox: String, uidsFrom start: UInt32) -> [FetchedHeader] {
        messages(in: mailbox).filter { $0.uid >= start }.map(Self.header)
    }

    public func flags(in mailbox: String, from start: Int, to end: Int) -> [FlagUpdate] {
        let all = messages(in: mailbox)
        guard start >= 1, start <= all.count else { return [] }
        return all[(start - 1)..<min(end, all.count)].map {
            FlagUpdate(uid: $0.uid, isUnread: !$0.flags.contains("\\Seen"), isFlagged: $0.flags.contains("\\Flagged"), gmailLabels: $0.labels.sorted())
        }
    }

    public func body(in mailbox: String, uid: UInt32) -> Data? {
        guard let message = messages(in: mailbox).first(where: { $0.uid == uid }) else { return nil }
        return Data(Self.renderBody(message).utf8)
    }

    // MARK: - Writes

    public func store(in mailbox: String, uids: Set<UInt32>, add: Bool, labels: [String]? = nil, flags: [String]? = nil) {
        lock.lock(); defer { lock.unlock() }
        for key in store.keys where key == mailbox || mailbox == "INBOX" || key == Self.allMail {
            store[key] = store[key]?.map { message in
                guard uids.contains(message.uid) else { return message }
                var updated = message
                for label in labels ?? [] { if add { updated.labels.insert(label) } else { updated.labels.remove(label) } }
                for flag in flags ?? [] { if add { updated.flags.insert(flag) } else { updated.flags.remove(flag) } }
                return updated
            }
        }
    }

    public func move(from mailbox: String, uids: Set<UInt32>, to target: String) {
        lock.lock(); defer { lock.unlock() }
        let moving = (store[mailbox] ?? []).filter { uids.contains($0.uid) }
        store[mailbox] = (store[mailbox] ?? []).filter { !uids.contains($0.uid) }
        store[target, default: []].append(contentsOf: moving)
    }

    public func create(_ mailbox: String) {
        lock.lock(); defer { lock.unlock() }
        if store[mailbox] == nil { store[mailbox] = [] }
    }

    // MARK: - Rendering shared with the IMAP front

    static func header(_ message: DemoMailServer.Message) -> FetchedHeader {
        FetchedHeader(
            uid: message.uid,
            subject: message.subject,
            senderName: message.fromName,
            senderAddress: message.fromAddress.lowercased(),
            recipients: AddressParser.all(in: message.to),
            date: message.date,
            isUnread: !message.flags.contains("\\Seen"),
            isFlagged: message.flags.contains("\\Flagged"),
            gmailLabels: message.labels.sorted(),
            listUnsubscribe: message.listUnsubscribe,
            listUnsubscribePost: message.oneClick ? "List-Unsubscribe=One-Click" : nil,
            listID: nil,
            messageID: "<demo-\(message.uid)@grokbox.local>"
        )
    }

    static func renderBody(_ message: DemoMailServer.Message) -> String {
        message.isHTML
            ? "--demo-boundary\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(message.body)\r\n--demo-boundary\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<html><body><p>\(message.body)</p></body></html>\r\n--demo-boundary--\r\n"
            : message.body
    }
}

/// `MailProvider` backed by a `DemoMailbox` in the same process. What the app
/// uses for demo accounts — no socket, no entitlement, nothing listening.
public struct DemoMailProvider: MailProvider {
    private let mailbox: DemoMailbox
    private let selected: Selected

    private final class Selected: @unchecked Sendable {
        private let lock = NSLock()
        private var name: String?
        var current: String? {
            get { lock.lock(); defer { lock.unlock() }; return name }
            set { lock.lock(); name = newValue; lock.unlock() }
        }
    }

    public init(mailbox: DemoMailbox) {
        self.mailbox = mailbox
        self.selected = Selected()
    }

    public var capabilities: IMAPCapabilities { get async { mailbox.capabilities } }

    public func discoverMailboxes() async throws -> [IMAPMailbox] { mailbox.listMailboxes().filter(\.isSelectable) }

    public func openReadOnly(_ name: String) async throws -> MailboxStatus { try open(name) }
    public func openReadWrite(_ name: String) async throws -> MailboxStatus { try open(name) }

    private func open(_ name: String) throws -> MailboxStatus {
        guard mailbox.exists(name) else { throw IMAPError.commandFailed(command: "SELECT \(name)", response: "[NONEXISTENT] Unknown mailbox") }
        selected.current = name
        return mailbox.status(name)
    }

    private func requireSelected() throws -> String {
        guard let name = selected.current else { throw IMAPError.commandFailed(command: "FETCH", response: "No mailbox selected") }
        return name
    }

    public func headers(from start: Int, to end: Int) async throws -> [FetchedHeader] {
        mailbox.headers(in: try requireSelected(), from: start, to: end)
    }

    public func headers(uidsFrom start: UInt32) async throws -> [FetchedHeader] {
        mailbox.headers(in: try requireSelected(), uidsFrom: start)
    }

    public func flags(from start: Int, to end: Int) async throws -> [FlagUpdate] {
        mailbox.flags(in: try requireSelected(), from: start, to: end)
    }

    public func bodyExcerpt(uid: UInt32) async throws -> Data? {
        mailbox.body(in: try requireSelected(), uid: uid)
    }

    public func setFlags(uids: [UInt32], _ change: IMAPClient.FlagChange, flags: [String]) async throws {
        mailbox.store(in: try requireSelected(), uids: Set(uids), add: change == .add, flags: flags)
    }

    public func setGmailLabels(uids: [UInt32], _ change: IMAPClient.FlagChange, labels: [String]) async throws {
        mailbox.store(in: try requireSelected(), uids: Set(uids), add: change == .add, labels: labels)
    }

    public func move(uids: [UInt32], to target: String) async throws {
        mailbox.move(from: try requireSelected(), uids: Set(uids), to: target)
    }

    public func ensureMailbox(_ name: String) async throws { mailbox.create(name) }

    public func finish() async { selected.current = nil }
}

/// Where the app keeps its live demo mailboxes, keyed by account.
@MainActor
public final class DemoRegistry {
    public static let shared = DemoRegistry()
    private var mailboxes: [UUID: DemoMailbox] = [:]

    private init() {}

    public func mailbox(for accountID: UUID) -> DemoMailbox? { mailboxes[accountID] }

    public func register(_ mailbox: DemoMailbox, for accountID: UUID) { mailboxes[accountID] = mailbox }

    public func remove(_ accountID: UUID) { mailboxes[accountID] = nil }
}

/// Picks the backend for an account: the in-process demo mailbox when one is
/// registered, IMAP otherwise.
public enum MailProviderFactory {
    @MainActor
    public static func connect(to account: MailAccount) async throws -> any MailProvider {
        if account.kind.isDemo, let mailbox = DemoRegistry.shared.mailbox(for: account.id) {
            return DemoMailProvider(mailbox: mailbox)
        }
        return try await IMAPMailProvider.connect(to: account)
    }
}
