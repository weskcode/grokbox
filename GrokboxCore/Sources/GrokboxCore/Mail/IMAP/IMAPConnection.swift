import Foundation
import Network

public enum IMAPSecurity: String, Codable, CaseIterable, Sendable {
    /// Implicit TLS from the first byte (port 993). The normal case.
    case tls
    /// TLS, but accept a self-signed certificate. **Refused for any host other
    /// than loopback** — it exists for Proton Mail Bridge, which terminates TLS
    /// on 127.0.0.1 with a certificate it generated itself.
    case tlsSelfSignedLoopback
    /// Cleartext. Only ever appropriate for loopback.
    case none

    public var label: String {
        switch self {
        case .tls: "TLS"
        case .tlsSelfSignedLoopback: "TLS, self-signed (loopback only)"
        case .none: "None (loopback only)"
        }
    }

    /// Anything other than proper TLS is only permitted on this machine.
    public var requiresLoopback: Bool { self != .tls }
}

public enum IMAPError: LocalizedError {
    case connectionClosed
    case connectionFailed(String)
    case noNetwork
    case timedOut(String)
    case insecureForRemoteHost
    case commandFailed(command: String, response: String)
    case unexpectedResponse(String)
    case notConnected
    case mailboxChanged

    public var errorDescription: String? {
        switch self {
        case .connectionClosed:
            "The mail server closed the connection."
        case .connectionFailed(let detail):
            "Could not connect: \(detail)"
        case .noNetwork:
            "No network connection. Check Wi-Fi and try again."
        case .timedOut(let what):
            "Timed out \(what). The server may be slow or unreachable."
        case .insecureForRemoteHost:
            "Refusing an unencrypted or self-signed connection to a remote host. Those options are only allowed for 127.0.0.1."
        case .commandFailed(let command, let response):
            "Server rejected \(command) — \(response)"
        case .unexpectedResponse(let line):
            "Unexpected response from server: \(line)"
        case .notConnected:
            "Not connected to the mail server."
        case .mailboxChanged:
            "The mailbox was renumbered on the server since it was indexed. Re-index before sweeping."
        }
    }
}

/// A single IMAP protocol line, plus any literal blocks (`{123}` sections)
/// that the server inlined into it.
struct IMAPLine: Sendable {
    var text: String
    var literals: [Data]
}

/// Byte-level transport for IMAP: a TCP/TLS socket with the buffered
/// line-and-literal reader the protocol needs, and timeouts on everything.
///
/// This is an actor so the read buffer can never be torn by concurrent reads —
/// IMAP is a strictly ordered request/response protocol and interleaving would
/// corrupt it.
actor IMAPConnection {
    private var connection: NWConnection?
    private var buffer: [UInt8] = []

    /// Deadlines. Per instance so a test can shorten its own connection's
    /// without affecting suites running alongside it.
    let connectTimeout: Duration
    let readTimeout: Duration

    init(connectTimeout: Duration = .seconds(20), readTimeout: Duration = .seconds(90)) {
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
    }

    private static let crlf: [UInt8] = [0x0D, 0x0A]

    func connect(host: String, port: Int, security: IMAPSecurity) async throws {
        let isLoopback = ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
        if security.requiresLoopback && !isLoopback {
            throw IMAPError.insecureForRemoteHost
        }

        let parameters: NWParameters
        switch security {
        case .tls:
            parameters = NWParameters(tls: NWProtocolTLS.Options())
        case .tlsSelfSignedLoopback:
            let tls = NWProtocolTLS.Options()
            // Trust whatever certificate loopback presents. Safe only because the
            // bytes never leave the machine, which the guard above ensures.
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
                complete(true)
            }, DispatchQueue.global(qos: .userInitiated))
            parameters = NWParameters(tls: tls)
        case .none:
            parameters = NWParameters.tcp
        }

        // OS-level backstop. Even with the deadline below, a half-open socket
        // should be torn down by the transport rather than lingering.
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 20
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 10
            tcp.keepaliveCount = 3
        }

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw IMAPError.connectionFailed("Invalid port \(port)")
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        self.connection = connection

        do {
            try await Self.withDeadline(connectTimeout, what: "connecting", on: connection) {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let resumed = OneShot()
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if resumed.claim() { cont.resume() }
                        case .waiting(let error):
                            // No viable path (offline, DNS down). Fail fast rather
                            // than sit until the timeout.
                            if resumed.claim() {
                                let noRoute = error.localizedDescription.localizedCaseInsensitiveContains("network is down")
                                    || error.localizedDescription.localizedCaseInsensitiveContains("no route")
                                cont.resume(throwing: noRoute ? IMAPError.noNetwork : IMAPError.connectionFailed(error.localizedDescription))
                            }
                        case .failed(let error):
                            if resumed.claim() { cont.resume(throwing: IMAPError.connectionFailed(error.localizedDescription)) }
                        case .cancelled:
                            if resumed.claim() { cont.resume(throwing: IMAPError.connectionClosed) }
                        default:
                            break
                        }
                    }
                    connection.start(queue: .global(qos: .userInitiated))
                }
            }
        } catch {
            connection.cancel()
            self.connection = nil
            throw error
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        buffer.removeAll()
    }

    func write(_ string: String) async throws {
        guard let connection else { throw IMAPError.notConnected }
        let data = Data(string.utf8)
        try await Self.withDeadline(readTimeout, what: "sending", on: connection) {
            let box = ConnectionBox(connection)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let once = OneShot()
                    connection.send(content: data, completion: .contentProcessed { error in
                        guard once.claim() else { return }
                        if let error {
                            cont.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                        } else {
                            cont.resume()
                        }
                    })
                }
            } onCancel: {
                box.cancel()
            }
        }
    }

    /// Reads one complete server response line, following any literal blocks.
    ///
    /// IMAP servers may split a logical response across a line, a counted byte
    /// blob, and more line — e.g. a FETCH whose header block arrives as `{87}`
    /// followed by 87 raw bytes. This reassembles that into one `IMAPLine`.
    func readResponseLine() async throws -> IMAPLine {
        var text = ""
        var literals: [Data] = []

        while true {
            let line = try await readLine()
            text += line
            guard let count = Self.trailingLiteralLength(in: line) else { break }
            literals.append(try await readBytes(count))
        }

        return IMAPLine(text: text, literals: literals)
    }

    // MARK: - Buffered reading

    private func readLine() async throws -> String {
        while true {
            if let index = indexOfCRLF() {
                let lineBytes = Array(buffer[0..<index])
                buffer.removeFirst(index + 2)
                return String(decoding: lineBytes, as: UTF8.self)
            }
            try await fill()
        }
    }

    private func readBytes(_ count: Int) async throws -> Data {
        while buffer.count < count {
            try await fill()
        }
        let bytes = Array(buffer[0..<count])
        buffer.removeFirst(count)
        return Data(bytes)
    }

    private func indexOfCRLF() -> Int? {
        guard buffer.count >= 2 else { return nil }
        for i in 0...(buffer.count - 2) where buffer[i] == Self.crlf[0] && buffer[i + 1] == Self.crlf[1] {
            return i
        }
        return nil
    }

    private func fill() async throws {
        guard let connection else { throw IMAPError.notConnected }
        let chunk = try await Self.withDeadline(readTimeout, what: "waiting for the server", on: connection) {
            try await Self.receive(on: connection)
        }
        buffer.append(contentsOf: chunk)
    }

    /// One `receive`, made cancellation-aware.
    ///
    /// `withCheckedThrowingContinuation` on its own cannot be cancelled: if the
    /// server never sends, the continuation is parked forever and no amount of
    /// task cancellation reaches it. Cancelling the connection is what forces
    /// the completion handler to fire, which is what resumes the continuation.
    private static func receive(on connection: NWConnection) async throws -> Data {
        let box = ConnectionBox(connection)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                let once = OneShot()
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    guard once.claim() else { return }
                    if let error {
                        cont.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(throwing: IMAPError.connectionClosed)
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Detects a trailing `{123}` or `{123+}` literal marker on a response line.
    private static func trailingLiteralLength(in line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        var digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        if digits.hasSuffix("+") { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// Races an operation against a deadline, and tears the socket down when the
    /// deadline wins.
    ///
    /// The teardown is the whole point. A throwing task group awaits **every**
    /// child before it propagates, so a sleeper that merely throws can never end
    /// the scope while the operation child sits parked on an `NWConnection`
    /// callback — the deadline wins the race and then waits forever for the
    /// loser. Cancelling the connection fires the pending completion handler,
    /// which resumes the parked continuation, which lets the group unwind.
    /// Verified by repro: before this, a 3-second deadline had not fired after
    /// twelve seconds against a server that accepts TCP and then goes silent.
    private static func withDeadline<T: Sendable>(
        _ limit: Duration,
        what: String,
        on connection: NWConnection,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = ConnectionBox(connection)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                box.cancel()
                throw IMAPError.timedOut(what)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// Carries an `NWConnection` across concurrency domains so a deadline or a
/// cancellation handler can tear it down. `cancel()` is documented as safe to
/// call from any thread.
private final class ConnectionBox: @unchecked Sendable {
    private let connection: NWConnection
    init(_ connection: NWConnection) { self.connection = connection }
    func cancel() { connection.cancel() }
}

/// Tiny thread-safe latch so a continuation resumes exactly once.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
