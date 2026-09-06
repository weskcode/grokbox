import Foundation
import Network

/// A small, real IMAP server on loopback with a generated mailbox.
///
/// Exists so anyone can watch Grokbox work — index, read, sweep, undo —
/// before pointing it at mail they care about. Also what the UI tests drive.
/// Speaks the subset of IMAP the client uses, with Gmail's label extension,
/// and its state actually mutates: archive really removes `\Inbox`.
public final class DemoMailServer: @unchecked Sendable {
    public static var password: String { DemoMailbox.password }
    public static var uidValidity: UInt32 { DemoMailbox.uidValidity }

    public let mailbox: DemoMailbox
    public var persona: DemoPersona { mailbox.persona }
    public var username: String { mailbox.username }

    public struct Message: Sendable {
        public var uid: UInt32
        public var fromName: String
        public var fromAddress: String
        public var to: String
        public var subject: String
        public var date: Date
        public var body: String
        public var isHTML: Bool
        public var flags: Set<String>
        public var labels: Set<String>
        public var listUnsubscribe: String?
        public var oneClick: Bool
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "grokbox.demo-imap")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    public private(set) var port: UInt16 = 0

    public init(persona: DemoPersona = .personal) throws {
        self.mailbox = DemoMailbox(persona: persona)
        // Loopback only. Never reachable from another machine.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    public var isRunning: Bool { listener.state == .ready }

    public func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OneShotLatch()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    self?.port = self?.listener.port?.rawValue ?? 0
                    cont.resume()
                case .failed(let error):
                    guard once.claim() else { return }
                    cont.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
        lock.lock(); connections.forEach { $0.cancel() }; connections.removeAll(); lock.unlock()
    }

    /// Test hook: current messages in a mailbox (INBOX is virtual, like Gmail's).
    public func messages(in name: String) -> [Message] { mailbox.messages(in: name) }

    // MARK: - Connection handling

    private final class Session {
        var selected: String?
        var buffer = Data()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock(); connections.append(connection); lock.unlock()
        let session = Session()
        connection.start(queue: queue)
        send("* OK Grokbox demo IMAP ready\r\n", on: connection)
        readLoop(connection, session)
    }

    private func readLoop(_ connection: NWConnection, _ session: Session) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }
            if let data { session.buffer.append(data) }
            while let range = session.buffer.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: session.buffer.subdata(in: session.buffer.startIndex..<range.lowerBound), as: UTF8.self)
                session.buffer.removeSubrange(session.buffer.startIndex..<range.upperBound)
                self.handle(line, session, connection)
            }
            if !isComplete { self.readLoop(connection, session) }
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    // MARK: - Commands

    private func handle(_ line: String, _ session: Session, _ connection: NWConnection) {
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return }
        let tag = String(parts[0])
        let command = String(parts[1])
        let upper = command.uppercased()

        func ok(_ text: String = "Success", untagged: String = "") {
            send(untagged + "\(tag) OK \(text)\r\n", on: connection)
        }
        func no(_ text: String) { send("\(tag) NO \(text)\r\n", on: connection) }
        func bad(_ text: String) { send("\(tag) BAD \(text)\r\n", on: connection) }

        switch true {
        case upper.hasPrefix("CAPABILITY"):
            ok(untagged: "* CAPABILITY IMAP4rev1 UNSELECT IDLE NAMESPACE X-GM-EXT-1 UIDPLUS MOVE\r\n")

        case upper.hasPrefix("LOGIN"):
            let args = Self.quotedArguments(command)
            if args.count == 2, args[0].caseInsensitiveCompare(username) == .orderedSame, args[1] == Self.password {
                ok("\(username) authenticated")
            } else {
                no("[AUTHENTICATIONFAILED] Invalid credentials")
            }

        case upper.hasPrefix("NOOP"):
            ok()

        case upper.hasPrefix("LIST"):
            ok(untagged: """
            * LIST (\\HasNoChildren) "/" "INBOX"\r
            * LIST (\\HasChildren \\Noselect) "/" "[Gmail]"\r
            * LIST (\\All \\HasNoChildren) "/" "[Gmail]/All Mail"\r
            * LIST (\\HasNoChildren \\Sent) "/" "[Gmail]/Sent Mail"\r
            * LIST (\\HasNoChildren \\Trash) "/" "[Gmail]/Trash"\r

            """)

        case upper.hasPrefix("EXAMINE"), upper.hasPrefix("SELECT"):
            let name = Self.quotedArgument(command)
            guard mailbox.exists(name) else { no("[NONEXISTENT] Unknown mailbox"); return }
            let count = mailbox.messages(in: name).count
            let next = mailbox.nextUID(in: name)
            session.selected = name
            let mode = upper.hasPrefix("EXAMINE") ? "READ-ONLY" : "READ-WRITE"
            ok("[\(mode)] \(name) selected", untagged: "* \(count) EXISTS\r\n* 0 RECENT\r\n* OK [UIDVALIDITY \(Self.uidValidity)] UIDs valid\r\n* OK [UIDNEXT \(next)] Predicted next UID\r\n")

        case upper.hasPrefix("FETCH"), upper.hasPrefix("UID FETCH"):
            guard let selected = session.selected else { no("No mailbox selected"); return }
            let byUID = upper.hasPrefix("UID ")
            let rest = byUID ? String(command.dropFirst(10)) : String(command.dropFirst(6))
            guard let space = rest.firstIndex(of: " ") else { bad("FETCH needs a set and items"); return }
            let set = String(rest[..<space])
            let items = String(rest[rest.index(after: space)...]).uppercased()

            let messages = mailbox.messages(in: selected)
            let maxKey = byUID ? (messages.last?.uid ?? 0) : UInt32(messages.count)
            let wanted = Self.parseSet(set, max: maxKey)
            var out = ""
            for (index, message) in messages.enumerated() {
                let key = byUID ? message.uid : UInt32(index + 1)
                guard wanted.contains(key) else { continue }
                out += Self.render(message, seq: index + 1, items: items)
            }
            ok(untagged: out)

        case upper.hasPrefix("UID STORE"):
            guard let selected = session.selected else { no("No mailbox selected"); return }
            let rest = String(command.dropFirst(10))
            let tokens = rest.split(separator: " ", maxSplits: 2).map(String.init)
            guard tokens.count == 3 else { bad("STORE syntax"); return }
            let attribute = tokens[1].uppercased()
            let values = Self.parseList(tokens[2])
            let add = attribute.hasPrefix("+")
            let isLabels = attribute.contains("X-GM-LABELS")
            let wanted = Self.parseSet(tokens[0], max: mailbox.nextUID(in: selected) - 1)
            mailbox.store(in: selected, uids: wanted, add: add, labels: isLabels ? values : nil, flags: isLabels ? nil : values)
            ok()

        case upper.hasPrefix("UID MOVE"):
            guard let selected = session.selected else { no("No mailbox selected"); return }
            let rest = String(command.dropFirst(9))
            guard let space = rest.firstIndex(of: " ") else { bad("MOVE syntax"); return }
            let target = Self.quotedArgument(String(rest[rest.index(after: space)...]))
            let wanted = Self.parseSet(String(rest[..<space]), max: mailbox.nextUID(in: selected) - 1)
            mailbox.move(from: selected, uids: wanted, to: target)
            ok("[COPYUID \(Self.uidValidity) 1 1] Moved")

        case upper.hasPrefix("CREATE"):
            mailbox.create(Self.quotedArgument(command))
            ok()

        case upper.hasPrefix("LOGOUT"):
            send("* BYE Grokbox demo signing off\r\n\(tag) OK LOGOUT completed\r\n", on: connection)
            connection.cancel()

        default:
            bad("Demo server does not implement: \(command.prefix(30))")
        }
    }


    // MARK: - Rendering

    private static func render(_ message: Message, seq: Int, items: String) -> String {
        var parts: [String] = ["UID \(message.uid)"]
        if items.contains("FLAGS") { parts.append("FLAGS (\(message.flags.sorted().joined(separator: " ")))") }
        if items.contains("X-GM-LABELS") {
            let rendered = message.labels.sorted().map { $0.hasPrefix("\\") ? $0 : "\"\($0)\"" }
            parts.append("X-GM-LABELS (\(rendered.joined(separator: " ")))")
        }
        if items.contains("INTERNALDATE") { parts.append("INTERNALDATE \"\(internalDate(message.date))\"") }
        if items.contains("HEADER.FIELDS") {
            var block = "From: \(message.fromName.isEmpty ? message.fromAddress : "\(message.fromName) <\(message.fromAddress)>")\r\n"
            block += "To: \(message.to)\r\nSubject: \(message.subject)\r\nDate: \(rfc2822(message.date))\r\nMessage-ID: <demo-\(message.uid)@grokbox.local>\r\n"
            if let unsub = message.listUnsubscribe {
                block += "List-Unsubscribe: \(unsub)\r\n"
                if message.oneClick { block += "List-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n" }
            }
            block += "\r\n"
            parts.append("BODY[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST LIST-ID)] {\(block.utf8.count)}\r\n\(block)")
        }
        if items.contains("BODY.PEEK[TEXT]") {
            let body = DemoMailbox.renderBody(message)
            parts.append("BODY[TEXT]<0> {\(body.utf8.count)}\r\n\(body)")
        }
        return "* \(seq) FETCH (\(parts.joined(separator: " ")))\r\n"
    }

    private static func internalDate(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    private static func rfc2822(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    // MARK: - Parsing helpers

    /// Every `"..."` argument on the line, in order.
    static func quotedArguments(_ command: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for char in command {
            if escaped { current.append(char); escaped = false; continue }
            if inQuotes && char == "\\" { escaped = true; continue }
            if char == "\"" {
                if inQuotes { out.append(current); current = "" }
                inQuotes.toggle()
                continue
            }
            if inQuotes { current.append(char) }
        }
        return out
    }

    static func quotedArgument(_ command: String) -> String {
        if let open = command.firstIndex(of: "\""), let close = command[command.index(after: open)...].firstIndex(of: "\"") {
            return String(command[command.index(after: open)..<close])
        }
        return command.split(separator: " ").last.map(String.init) ?? ""
    }

    static func parseList(_ text: String) -> [String] {
        var inner = text.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("(") { inner.removeFirst() }
        if inner.hasSuffix(")") { inner.removeLast() }
        var out: [String] = []
        var current = ""
        var inQuotes = false
        for char in inner {
            if char == "\"" { inQuotes.toggle(); continue }
            if char == " " && !inQuotes { if !current.isEmpty { out.append(current) }; current = ""; continue }
            current.append(char)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// `1:3,5,9:*` → the set of numbers it names.
    static func parseSet(_ set: String, max: UInt32) -> Set<UInt32> {
        var out = Set<UInt32>()
        for piece in set.split(separator: ",") {
            let bounds = piece.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            func value(_ s: String) -> UInt32 { s == "*" ? max : (UInt32(s) ?? 0) }
            if bounds.count == 2 {
                let a = value(bounds[0]), b = value(bounds[1])
                guard a > 0 || b > 0 else { continue }
                for n in Swift.min(a, b)...Swift.max(a, b) { out.insert(n) }
            } else if bounds.count == 1, let n = UInt32(bounds[0]) {
                out.insert(n)
            } else if bounds.count == 1, bounds[0] == "*" {
                out.insert(max)
            }
        }
        return out
    }
}

final class OneShotLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}
