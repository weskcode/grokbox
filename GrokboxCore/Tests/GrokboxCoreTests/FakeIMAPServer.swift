import Foundation
import Network

/// A scripted IMAP server on loopback. Speaks just enough of the protocol to
/// exercise the real client end to end — tags, untagged responses, literals —
/// with no credentials and no network.
final class FakeIMAPServer: @unchecked Sendable {
    typealias Script = [(commandPrefix: String, response: String)]

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-imap")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private(set) var receivedCommands: [String] = []
    private let script: Script
    private let greeting: String

    private(set) var port: UInt16 = 0

    init(greeting: String = "* OK Gimap ready for requests", script: Script) throws {
        self.script = script
        self.greeting = greeting
        // Loopback only, like the demo server; a fresh ephemeral port each time.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = OneShot()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard resumed.claim() else { return }
                    self?.port = self?.listener.port?.rawValue ?? 0
                    cont.resume()
                case .failed(let error):
                    guard resumed.claim() else { return }
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.lock(); connections.forEach { $0.cancel() }; lock.unlock()
    }

    /// Commands received so far, with their tags stripped.
    var commands: [String] {
        lock.lock(); defer { lock.unlock() }
        return receivedCommands
    }

    private func accept(_ connection: NWConnection) {
        lock.lock(); connections.append(connection); lock.unlock()
        connection.start(queue: queue)
        send("\(greeting)\r\n", on: connection)
        readLoop(connection, buffer: Data())
    }

    private func readLoop(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }

            while let range = buffer.range(of: Data("\r\n".utf8)) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                let line = String(decoding: lineData, as: UTF8.self)
                self.handle(line, on: connection)
            }

            if !isComplete { self.readLoop(connection, buffer: buffer) }
        }
    }

    private func handle(_ line: String, on connection: NWConnection) {
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return }
        let tag = String(parts[0])
        let command = String(parts[1])

        lock.lock(); receivedCommands.append(command); lock.unlock()

        let response = script.first { command.uppercased().hasPrefix($0.commandPrefix.uppercased()) }?.response
            ?? "{tag} BAD Unknown command in fake server: \(command)\r\n"
        send(response.replacingOccurrences(of: "{tag}", with: tag), on: connection)

        if command.uppercased().hasPrefix("LOGOUT") {
            connection.cancel()
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }
}

// MARK: - A Gmail-shaped fixture

enum GmailFixture {
    static func header(uid: Int, from: String, subject: String, extra: String = "") -> String {
        let block = "From: \(from)\r\nSubject: \(subject)\r\nDate: Fri, 05 Sep 2026 10:00:00 +0000\r\nMessage-ID: <m\(uid)@example.com>\r\n\(extra)\r\n"
        let literal = "{\(block.utf8.count)}\r\n\(block)"
        return "* \(uid) FETCH (UID \(uid * 10) FLAGS (\(uid == 3 ? "\\Seen" : "")) INTERNALDATE \"0\(uid)-Sep-2026 10:00:00 +0000\" BODY[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST LIST-ID)] \(literal))\r\n"
    }

    static let body = "This is the plain text body.\r\nPlease reply by Friday.\r\n"

    static var script: FakeIMAPServer.Script {
        let headers =
            header(uid: 1, from: "=?UTF-8?B?U2Now7ZuIE5ld3M=?= <news@shop.example>", subject: "=?UTF-8?Q?50=25_off_everything?=",
                   extra: "List-Unsubscribe: <https://shop.example/unsub?u=1>, <mailto:unsub@shop.example>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click")
            + header(uid: 2, from: "Alice Adams <alice@friend.example>", subject: "Lunch Friday?")
            + header(uid: 3, from: "billing@utility.example", subject: "Your bill is ready")
        let sentHeader = "* 1 FETCH (UID 500 FLAGS (\\Seen) INTERNALDATE \"01-Sep-2026 09:00:00 +0000\" BODY[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST LIST-ID)] {74}\r\nFrom: me@gmail.example\r\nTo: Alice Adams <alice@friend.example>\r\nSubject: Re: hi\r\n\r\n)\r\n"

        return [
            ("LOGIN", "{tag} OK me@gmail.example authenticated (Success)\r\n"),
            ("CAPABILITY", "* CAPABILITY IMAP4rev1 UNSELECT IDLE NAMESPACE QUOTA ID XLIST CHILDREN X-GM-EXT-1 UIDPLUS MOVE\r\n{tag} OK Success\r\n"),
            ("LIST", "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n* LIST (\\HasChildren \\Noselect) \"/\" \"[Gmail]\"\r\n* LIST (\\All \\HasNoChildren) \"/\" \"[Gmail]/All Mail\"\r\n* LIST (\\HasNoChildren \\Sent) \"/\" \"[Gmail]/Sent Mail\"\r\n* LIST (\\HasNoChildren \\Trash) \"/\" \"[Gmail]/Trash\"\r\n{tag} OK Success\r\n"),
            ("EXAMINE \"[Gmail]/All Mail\"", "* 3 EXISTS\r\n* 0 RECENT\r\n* OK [UIDVALIDITY 1] UIDs valid\r\n{tag} OK [READ-ONLY] [Gmail]/All Mail selected. (Success)\r\n"),
            ("EXAMINE \"[Gmail]/Sent Mail\"", "* 1 EXISTS\r\n{tag} OK [READ-ONLY] [Gmail]/Sent Mail selected. (Success)\r\n"),
            ("SELECT \"[Gmail]/All Mail\"", "* 3 EXISTS\r\n{tag} OK [READ-WRITE] [Gmail]/All Mail selected. (Success)\r\n"),
            ("FETCH 1:3", headers + "{tag} OK Success\r\n"),
            ("FETCH 1:1", sentHeader + "{tag} OK Success\r\n"),
            ("UID FETCH 20 (BODY.PEEK[TEXT]", "* 2 FETCH (UID 20 BODY[TEXT]<0> {\(body.utf8.count)}\r\n\(body))\r\n{tag} OK Success\r\n"),
            ("UID STORE", "{tag} OK Success\r\n"),
            ("UID MOVE", "{tag} OK [COPYUID 1 10 99] Success\r\n"),
            ("CREATE", "{tag} OK Success\r\n"),
            ("LOGOUT", "* BYE LOGOUT Requested\r\n{tag} OK 73 good day (Success)\r\n"),
        ]
    }
}

private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
