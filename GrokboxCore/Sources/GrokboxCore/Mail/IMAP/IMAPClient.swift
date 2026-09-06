import Foundation

/// A message as it comes off the wire, before it becomes a SwiftData object.
/// Sendable so it can cross from the IMAP actor to the main actor safely.
public struct FetchedHeader: Sendable {
    public var uid: UInt32
    public var subject: String
    public var senderName: String
    public var senderAddress: String
    public var recipients: [String]
    public var date: Date
    public var isUnread: Bool
    public var isFlagged: Bool
    /// Gmail's labels for the message, when the server supports them. Nil otherwise.
    public var gmailLabels: [String]?
    public var listUnsubscribe: String?
    public var listUnsubscribePost: String?
    public var listID: String?
    public var messageID: String?

    /// On Gmail, "in the inbox" means it carries `\Inbox`. Elsewhere we index
    /// INBOX itself, so everything is.
    public var isInInbox: Bool {
        guard let gmailLabels else { return true }
        return gmailLabels.contains { $0.caseInsensitiveCompare("\\Inbox") == .orderedSame }
    }
}

/// A flags-only refresh for an already-indexed message.
public struct FlagUpdate: Sendable {
    public var uid: UInt32
    public var isUnread: Bool
    public var isFlagged: Bool
    public var gmailLabels: [String]?

    public var isInInbox: Bool {
        guard let gmailLabels else { return true }
        return gmailLabels.contains { $0.caseInsensitiveCompare("\\Inbox") == .orderedSame }
    }
}

public struct IMAPMailbox: Sendable, Hashable {
    public var name: String
    public var attributes: [String]
    /// The hierarchy delimiter the server reported for this entry (`/`, `.`,
    /// or nil for a flat namespace).
    public var delimiter: String?

    public init(name: String, attributes: [String], delimiter: String? = "/") {
        self.name = name
        self.attributes = attributes
        self.delimiter = delimiter
    }

    /// The name as a person would read it: modified UTF-7 decoded.
    public var displayName: String { IMAPUTF7.decode(name) }

    private func has(_ attribute: String) -> Bool {
        attributes.contains { $0.caseInsensitiveCompare(attribute) == .orderedSame }
    }

    /// Gmail tags its virtual folders with RFC 6154 special-use attributes.
    public var isAllMail: Bool { has("\\All") }
    public var isSent: Bool { has("\\Sent") }
    public var isTrash: Bool { has("\\Trash") }
    public var isJunk: Bool { has("\\Junk") }
    public var isArchive: Bool { has("\\Archive") }
    public var isDrafts: Bool { has("\\Drafts") }
    public var isSelectable: Bool { !has("\\Noselect") }
}

/// What the server told us it can do, from CAPABILITY.
public struct IMAPCapabilities: Sendable {
    public var raw: Set<String>

    public var supportsMove: Bool { raw.contains("MOVE") }
    public var supportsUIDPlus: Bool { raw.contains("UIDPLUS") }
    /// Gmail's extensions: labels as first-class, thread IDs, and so on.
    public var supportsGmailExtensions: Bool { raw.contains("X-GM-EXT-1") }
}

/// What a MOVE produced on the other side.
public struct MoveResult: Sendable, Equatable {
    public var targetUIDValidity: UInt32?
    /// UIDs the moved messages now have in the target mailbox, in the order the
    /// server listed them. Nil when the server gave no COPYUID.
    public var targetUIDs: [UInt32]?
    public init(targetUIDValidity: UInt32? = nil, targetUIDs: [UInt32]? = nil) {
        self.targetUIDValidity = targetUIDValidity; self.targetUIDs = targetUIDs
    }
}

/// What EXAMINE/SELECT reported about a mailbox.
public struct MailboxStatus: Sendable {
    public var exists: Int
    /// Changes only when the server renumbers the mailbox. If it differs from
    /// what we indexed against, every stored UID is meaningless.
    public var uidValidity: UInt32?
}

/// Command-level IMAP client.
///
/// Two tiers of operation, separated on purpose:
///
/// - **Read-only**: `examine`, `fetchHeaders`, `fetchFlags`, `fetchBodyExcerpt`.
///   Indexing and reading use only these. `EXAMINE` asks the server itself to
///   refuse writes.
/// - **Mutating**: `select`, `store`, `move`. Reached only through
///   `PlanExecutor`, only after a user has approved a plan, and every call is
///   preceded by a `CleanupAction` record so it can be undone.
///
/// There is no `EXPUNGE` and no way to set `\Deleted`. Grokbox does not delete.
public actor IMAPClient {
    private let connection: IMAPConnection
    private var tagCounter = 0
    private var isLoggedIn = false
    public private(set) var capabilities = IMAPCapabilities(raw: [])

    struct Result: Sendable {
        var untagged: [IMAPLine]
        var completion: String
    }

    private static let headerFields = "FROM TO CC SUBJECT DATE MESSAGE-ID LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST LIST-ID"

    public init() { connection = IMAPConnection() }

    /// For tests that need a short deadline.
    public init(connectTimeout: Duration, readTimeout: Duration) {
        connection = IMAPConnection(connectTimeout: connectTimeout, readTimeout: readTimeout)
    }

    // MARK: - Session

    public func connect(host: String, port: Int, security: IMAPSecurity) async throws {
        try await connection.connect(host: host, port: port, security: security)
        // Every IMAP server opens with an untagged greeting; consume it.
        let greeting = try await connection.readResponseLine()
        guard greeting.text.hasPrefix("* OK") || greeting.text.hasPrefix("* PREAUTH") else {
            throw IMAPError.unexpectedResponse(greeting.text)
        }
    }

    public func login(username: String, password: String) async throws {
        let result = try await execute("LOGIN \(Self.quoted(username)) \(Self.quoted(password))")
        guard result.isOK else {
            // Never echo the command back — it contains the password.
            throw IMAPError.commandFailed(command: "LOGIN", response: result.completionDetail)
        }
        isLoggedIn = true
        try await loadCapabilities()
    }

    public func logout() async {
        if isLoggedIn { _ = try? await execute("LOGOUT") }
        isLoggedIn = false
        await connection.disconnect()
    }

    /// CAPABILITY before LOGIN — permitted by RFC 3501, and the cheapest way to
    /// prove transport and parser against a real server with no credentials.
    public func preLoginCapabilities() async throws -> Set<String> {
        let result = try await execute("CAPABILITY")
        guard result.isOK else { throw IMAPError.commandFailed(command: "CAPABILITY", response: result.completionDetail) }
        for line in result.untagged {
            if let caps = IMAPResponseParser.parseCapability(line.text) { return caps }
        }
        // Some servers put it in the tagged OK: `a1 OK [CAPABILITY ...]`.
        if let range = result.completion.range(of: "[CAPABILITY ") {
            let tail = result.completion[range.upperBound...]
            return Set(tail.prefix { $0 != "]" }.split(separator: " ").map { $0.uppercased() })
        }
        return []
    }

    private func loadCapabilities() async throws {
        let result = try await execute("CAPABILITY")
        guard result.isOK else { return }
        for line in result.untagged {
            if let caps = IMAPResponseParser.parseCapability(line.text) {
                capabilities = IMAPCapabilities(raw: caps)
            }
        }
    }

    private var headerItems: String {
        let labels = capabilities.supportsGmailExtensions ? " X-GM-LABELS" : ""
        return "(UID FLAGS\(labels) INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(Self.headerFields))])"
    }

    // MARK: - Read-only operations

    public func listMailboxes() async throws -> [IMAPMailbox] {
        let result = try await execute("LIST \"\" \"*\"")
        guard result.isOK else {
            throw IMAPError.commandFailed(command: "LIST", response: result.completionDetail)
        }
        return result.untagged.compactMap { IMAPResponseParser.parseListLine($0.text) }
    }

    /// Opens a mailbox read-only.
    @discardableResult
    public func examine(_ mailbox: String) async throws -> MailboxStatus {
        try await open(mailbox, command: "EXAMINE")
    }

    /// Fetches headers for a sequence-number range (1-based, inclusive).
    ///
    /// Uses `BODY.PEEK` rather than `BODY` so that reading a message here does
    /// not mark it as read in the user's actual mailbox.
    public func fetchHeaders(from start: Int, to end: Int) async throws -> [FetchedHeader] {
        guard start <= end else { return [] }
        let result = try await execute("FETCH \(start):\(end) \(headerItems)")
        guard result.isOK else {
            throw IMAPError.commandFailed(command: "FETCH", response: result.completionDetail)
        }
        return result.untagged.compactMap { IMAPResponseParser.parseFetchLine($0) }
    }

    /// Fetches headers for every message with a UID at or above `start`.
    /// The incremental-sync path: one round trip for "what is new".
    public func fetchHeaders(uidsFrom start: UInt32) async throws -> [FetchedHeader] {
        let result = try await execute("UID FETCH \(start):* \(headerItems)")
        guard result.isOK else {
            throw IMAPError.commandFailed(command: "UID FETCH", response: result.completionDetail)
        }
        // `n:*` where n exceeds the highest UID returns the highest message, so
        // filter rather than trust the range.
        return result.untagged.compactMap { IMAPResponseParser.parseFetchLine($0) }.filter { $0.uid >= start }
    }

    /// Flags (and Gmail labels) only, for refreshing read/unread state cheaply.
    public func fetchFlags(from start: Int, to end: Int) async throws -> [FlagUpdate] {
        guard start <= end else { return [] }
        let labels = capabilities.supportsGmailExtensions ? " X-GM-LABELS" : ""
        let result = try await execute("FETCH \(start):\(end) (UID FLAGS\(labels))")
        guard result.isOK else {
            throw IMAPError.commandFailed(command: "FETCH flags", response: result.completionDetail)
        }
        return result.untagged.compactMap { IMAPResponseParser.parseFlagsLine($0.text) }
    }

    /// Fetches the first `maxBytes` of a message body without marking it read.
    ///
    /// The result is handed to the local model and discarded. It is never
    /// written to disk.
    public func fetchBodyExcerpt(uid: UInt32, maxBytes: Int = 8_000) async throws -> Data? {
        let result = try await execute("UID FETCH \(uid) (BODY.PEEK[TEXT]<0.\(maxBytes)>)")
        guard result.isOK else {
            throw IMAPError.commandFailed(command: "UID FETCH body", response: result.completionDetail)
        }
        return result.untagged.first { $0.text.contains(" FETCH ") }?.literals.first
    }

    // MARK: - Mutating operations

    /// Opens a mailbox read-write. The only caller is `PlanExecutor`.
    @discardableResult
    public func select(_ mailbox: String) async throws -> MailboxStatus {
        try await open(mailbox, command: "SELECT")
    }

    public enum FlagChange: Sendable {
        case add, remove
        var sign: String { self == .add ? "+" : "-" }
    }

    /// `UID STORE uids ±FLAGS (\Seen)` and friends. Silent variant so the
    /// server does not echo every changed message back.
    public func store(uids: [UInt32], _ change: FlagChange, flags: [String]) async throws {
        try await storeAttribute(uids: uids, "\(change.sign)FLAGS.SILENT", values: flags)
    }

    /// Gmail-only: `UID STORE uids ±X-GM-LABELS (label)`. System labels such as
    /// `\Inbox` arrive as-is; user labels are quoted.
    public func storeGmailLabels(uids: [UInt32], _ change: FlagChange, labels: [String]) async throws {
        let rendered = labels.map { $0.hasPrefix("\\") ? $0 : Self.quoted($0) }
        try await storeAttribute(uids: uids, "\(change.sign)X-GM-LABELS.SILENT", values: rendered)
    }

    /// RFC 6851 `UID MOVE`. Used only on non-Gmail servers that advertise it.
    /// `UID MOVE`. Returns the messages' UIDs in the target mailbox when the
    /// server reports them (`[COPYUID validity src dst]`, RFC 4315), which is
    /// what makes a move undoable. Nil when the server did not say.
    @discardableResult
    public func move(uids: [UInt32], to mailbox: String) async throws -> MoveResult {
        var newUIDs: [UInt32] = []
        var validity: UInt32?
        var complete = true
        for chunk in Self.uidSets(uids) {
            let result = try await execute("UID MOVE \(chunk) \(Self.quoted(mailbox))")
            guard result.isOK else {
                throw IMAPError.commandFailed(command: "UID MOVE", response: result.completionDetail)
            }
            // COPYUID may arrive on the tagged OK or as an untagged OK.
            let candidates = [result.completion] + result.untagged.map(\.text)
            if let parsed = candidates.lazy.compactMap(IMAPResponseParser.parseCopyUID).first {
                validity = parsed.validity
                newUIDs.append(contentsOf: parsed.destination)
            } else {
                complete = false
            }
        }
        return MoveResult(targetUIDValidity: validity, targetUIDs: complete ? newUIDs : nil)
    }

    public func createMailbox(_ name: String) async throws {
        let result = try await execute("CREATE \(Self.quoted(name))")
        // "Already exists" is fine; anything else is not.
        guard result.isOK || result.completionDetail.localizedCaseInsensitiveContains("exist") else {
            throw IMAPError.commandFailed(command: "CREATE", response: result.completionDetail)
        }
    }

    private func storeAttribute(uids: [UInt32], _ attribute: String, values: [String]) async throws {
        guard !uids.isEmpty, !values.isEmpty else { return }
        let list = "(\(values.joined(separator: " ")))"
        for chunk in Self.uidSets(uids) {
            let result = try await execute("UID STORE \(chunk) \(attribute) \(list)")
            guard result.isOK else {
                throw IMAPError.commandFailed(command: "UID STORE", response: result.completionDetail)
            }
        }
    }

    // MARK: - Plumbing

    private func open(_ mailbox: String, command: String) async throws -> MailboxStatus {
        let result = try await execute("\(command) \(Self.quoted(mailbox))")
        guard result.isOK else {
            throw IMAPError.commandFailed(command: "\(command) \(mailbox)", response: result.completionDetail)
        }
        var status = MailboxStatus(exists: 0, uidValidity: nil)
        for line in result.untagged {
            if let count = IMAPResponseParser.parseExists(line.text) { status.exists = count }
            if let validity = IMAPResponseParser.parseUIDValidity(line.text) { status.uidValidity = validity }
        }
        return status
    }

    private func execute(_ command: String) async throws -> Result {
        tagCounter += 1
        let tag = String(format: "g%04d", tagCounter)
        try await connection.write("\(tag) \(command)\r\n")

        var untagged: [IMAPLine] = []
        while true {
            let line = try await connection.readResponseLine()
            if line.text.hasPrefix("\(tag) ") {
                return Result(untagged: untagged, completion: line.text)
            }
            // A `+` line is a continuation request; we never send literals, so
            // seeing one means we and the server have lost sync.
            if line.text.hasPrefix("+") {
                throw IMAPError.unexpectedResponse(line.text)
            }
            untagged.append(line)
        }
    }

    /// IMAP quoted-string: wrap in quotes, backslash-escape quotes and backslashes.
    static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Renders UIDs as compact IMAP sequence sets (`1:5,9,12:14`), chunked so
    /// no single command line grows unreasonably.
    static func uidSets(_ uids: [UInt32], chunk: Int = 500) -> [String] {
        let sorted = Array(Set(uids)).sorted()
        var sets: [String] = []
        for start in stride(from: 0, to: sorted.count, by: chunk) {
            let slice = Array(sorted[start..<min(start + chunk, sorted.count)])
            var parts: [String] = []
            var rangeStart = slice[0]
            var previous = slice[0]
            for uid in slice.dropFirst() {
                if uid == previous + 1 {
                    previous = uid
                    continue
                }
                parts.append(rangeStart == previous ? "\(rangeStart)" : "\(rangeStart):\(previous)")
                rangeStart = uid
                previous = uid
            }
            parts.append(rangeStart == previous ? "\(rangeStart)" : "\(rangeStart):\(previous)")
            sets.append(parts.joined(separator: ","))
        }
        return sets
    }
}

extension IMAPClient.Result {
    var isOK: Bool {
        completion.split(separator: " ").dropFirst().first?.uppercased() == "OK"
    }

    /// The human-readable tail of a tagged completion, minus the tag and status.
    var completionDetail: String {
        completion.split(separator: " ", maxSplits: 2).dropFirst(2).first.map(String.init) ?? completion
    }
}
