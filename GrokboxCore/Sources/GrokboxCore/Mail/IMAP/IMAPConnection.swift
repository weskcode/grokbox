import Foundation
import Network
import Synchronization

public enum IMAPSecurity: String, Codable, CaseIterable, Sendable {
    /// Implicit TLS from the first byte (port 993). The normal case.
    case tls
    /// TLS, but accept a self-signed certificate. **Refused for any host other
    /// than loopback** — it exists for Proton Mail Bridge, which terminates TLS
    /// on 127.0.0.1 with a certificate it generated itself.
    case tlsSelfSignedLoopback
    /// Cleartext. Only ever appropriate for loopback.
    case none
    /// Connects in cleartext, then upgrades with `STARTTLS` (RFC 3501 §6.2.1)
    /// before anything else is said, usually on port 143. The upgrade is
    /// required: if the server does not offer it, refuses it, or the
    /// certificate does not verify, the connection fails. Nothing, least of
    /// all the password, is ever sent in the clear.
    case starttls
    /// `STARTTLS`, accepting a self-signed certificate. Loopback only: Proton
    /// Mail Bridge's default mode.
    case starttlsSelfSignedLoopback

    public var label: String {
        switch self {
        case .tls: "TLS"
        case .tlsSelfSignedLoopback: "TLS, self-signed (loopback only)"
        case .none: "None (loopback only)"
        case .starttls: "STARTTLS"
        case .starttlsSelfSignedLoopback: "STARTTLS, self-signed (loopback only)"
        }
    }

    /// Anything other than a certificate that verifies is only permitted on this machine.
    public var requiresLoopback: Bool { self != .tls && self != .starttls }

    /// Whether the connection starts in cleartext and must be upgraded.
    public var usesStartTLS: Bool { self == .starttls || self == .starttlsSelfSignedLoopback }
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
    case startTLSUnavailable
    case startTLSInjection

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
        case .startTLSUnavailable:
            "The server did not offer STARTTLS, so the connection was not encrypted and nothing was sent. Choose TLS (usually port 993) instead."
        case .startTLSInjection:
            "The server sent data before encryption started, which is how a STARTTLS injection attack looks. The connection was closed and nothing was sent."
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
    /// The socket. Network.framework for implicit TLS and loopback cleartext;
    /// a `URLSessionStreamTask` for STARTTLS, because an `NWConnection` cannot
    /// add TLS to a connection that is already open and the stream task can
    /// (`startSecureConnection()`).
    private enum Transport {
        case network(NWConnection)
        case stream(URLSessionStreamTask, URLSession, StartTLSTrust)

        var box: ConnectionBox {
            switch self {
            case .network(let connection): ConnectionBox { connection.cancel() }
            case .stream(let task, _, _): ConnectionBox { task.cancel() }
            }
        }
    }

    private var transport: Transport?
    private var buffer: [UInt8] = []
    private var security: IMAPSecurity = .tls

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
        self.security = security
        if security.usesStartTLS {
            try await connectStream(host: host, port: port, acceptSelfSigned: security == .starttlsSelfSignedLoopback)
            return
        }

        let parameters: NWParameters
        switch security {
        case .tls, .starttls, .starttlsSelfSignedLoopback:
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
        self.transport = .network(connection)

        do {
            try await Self.withDeadline(connectTimeout, what: "connecting", on: ConnectionBox { connection.cancel() }) {
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
            self.transport = nil
            throw error
        }
    }

    /// Opens the cleartext half of a STARTTLS connection. A stream task has
    /// no "ready" state to wait for, so the server's greeting arriving is
    /// the proof of connection, under the connect deadline.
    private func connectStream(host: String, port: Int, acceptSelfSigned: Bool) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        let trust = StartTLSTrust(acceptSelfSigned: acceptSelfSigned)
        let session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
        let task = session.streamTask(withHostName: host, port: port)
        transport = .stream(task, session, trust)
        task.resume()
        do {
            let chunk = try await Self.withDeadline(connectTimeout, what: "connecting", on: ConnectionBox { task.cancel() }) {
                try await Self.receive(on: task, timeout: self.connectTimeout)
            }
            buffer.append(contentsOf: chunk)
        } catch {
            disconnect()
            throw error
        }
    }

    /// Switches the open connection to TLS, after the server has answered
    /// `STARTTLS` with OK. Anything the server sent after that OK arrived in
    /// cleartext and could have been injected by whoever is in the middle,
    /// so its presence ends the connection rather than being read as a
    /// reply once encryption starts.
    func startTLS() throws {
        guard case .stream(let task, _, _) = transport, security.usesStartTLS else { throw IMAPError.notConnected }
        guard buffer.isEmpty else {
            disconnect()
            throw IMAPError.startTLSInjection
        }
        task.startSecureConnection()
    }

    func disconnect() {
        switch transport {
        case .network(let connection): connection.cancel()
        case .stream(let task, let session, _):
            task.cancel()
            session.invalidateAndCancel()
        case nil: break
        }
        transport = nil
        buffer.removeAll()
    }

    func write(_ string: String) async throws {
        guard let transport else { throw IMAPError.notConnected }
        let data = Data(string.utf8)
        let box = transport.box
        let timeout = readTimeout
        do {
        try await Self.withDeadline(readTimeout, what: "sending", on: box) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let once = OneShot()
                    let finish: @Sendable (Error?) -> Void = { error in
                        guard once.claim() else { return }
                        if let error {
                            cont.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                        } else {
                            cont.resume()
                        }
                    }
                    switch transport {
                    case .network(let connection):
                        connection.send(content: data, completion: .contentProcessed { finish($0) })
                    case .stream(let task, _, _):
                        task.write(data, timeout: timeout.timeInterval) { finish($0) }
                    }
                }
            } onCancel: {
                box.cancel()
            }
        }
        } catch {
            throw certificateFailure ?? error
        }
    }

    /// A refused certificate, as the error to show in place of the
    /// cancellation it caused.
    private var certificateFailure: IMAPError? {
        guard case .stream(_, _, let trust) = transport, let reason = trust.trustFailure else { return nil }
        return .connectionFailed("the server's certificate could not be verified (\(reason)). Nothing was sent.")
    }

    /// Reads one complete server response line, following any literal blocks.
    ///
    /// IMAP servers may split a logical response across a line, a counted byte
    /// blob, and more line — e.g. a FETCH whose header block arrives as `{87}`
    /// followed by 87 raw bytes. This reassembles that into one `IMAPLine`.
    /// `timeout` replaces the read deadline for this one response. IDLE uses
    /// it, since a server legitimately says nothing for many minutes there.
    func readResponseLine(timeout: Duration? = nil) async throws -> IMAPLine {
        var text = ""
        var literals: [Data] = []

        while true {
            let line = try await readLine(timeout: timeout)
            text += line
            guard let count = Self.trailingLiteralLength(in: line) else { break }
            literals.append(try await readBytes(count))
        }

        return IMAPLine(text: text, literals: literals)
    }

    // MARK: - Buffered reading

    private func readLine(timeout: Duration? = nil) async throws -> String {
        while true {
            if let index = indexOfCRLF() {
                let lineBytes = Array(buffer[0..<index])
                buffer.removeFirst(index + 2)
                return String(decoding: lineBytes, as: UTF8.self)
            }
            try await fill(timeout: timeout)
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

    private func fill(timeout custom: Duration? = nil) async throws {
        guard let transport else { throw IMAPError.notConnected }
        let timeout = custom ?? readTimeout
        do {
            let chunk = try await Self.withDeadline(timeout, what: "waiting for the server", on: transport.box) {
                switch transport {
                case .network(let connection): try await Self.receive(on: connection)
                case .stream(let task, _, _): try await Self.receive(on: task, timeout: timeout)
                }
            }
            buffer.append(contentsOf: chunk)
        } catch {
            throw certificateFailure ?? error
        }
    }

    /// One `receive`, made cancellation-aware.
    ///
    /// `withCheckedThrowingContinuation` on its own cannot be cancelled: if the
    /// server never sends, the continuation is parked forever and no amount of
    /// task cancellation reaches it. Cancelling the connection is what forces
    /// the completion handler to fire, which is what resumes the continuation.
    private static func receive(on connection: NWConnection) async throws -> Data {
        let box = ConnectionBox { connection.cancel() }
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

    /// The stream-task equivalent. Its own timeout is only a backstop, set
    /// past the deadline that wraps every call, which is what actually ends a
    /// silent read.
    private static func receive(on task: URLSessionStreamTask, timeout: Duration) async throws -> Data {
        let box = ConnectionBox { task.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                let once = OneShot()
                task.readData(ofMinLength: 1, maxLength: 64 * 1024, timeout: timeout.timeInterval + 5) { data, atEOF, error in
                    guard once.claim() else { return }
                    if let error {
                        cont.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if atEOF {
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
        on box: ConnectionBox,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
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

/// Carries a socket's teardown across concurrency domains so a deadline or a
/// cancellation handler can call it. `NWConnection.cancel()` and
/// `URLSessionTask.cancel()` are both documented as safe from any thread.
private struct ConnectionBox: Sendable {
    let cancel: @Sendable () -> Void
    init(_ cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
}

/// Certificate policy for the TLS half of a STARTTLS connection. By default
/// the system checks the chain and the host name, exactly as for implicit
/// TLS. Accepting a self-signed certificate is only reachable for loopback,
/// which `IMAPConnection.connect` enforces before this is ever created.
///
/// A certificate that fails is recorded and the task cancelled, so the
/// pending read or write ends at once with a reason, instead of the stream
/// waiting out the read deadline in silence.
private final class StartTLSTrust: NSObject, URLSessionTaskDelegate, Sendable {
    let acceptSelfSigned: Bool
    private let failure = Mutex<String?>(nil)

    init(acceptSelfSigned: Bool) { self.acceptSelfSigned = acceptSelfSigned }

    /// Why the certificate was refused, if it was.
    var trustFailure: String? { failure.withLock { $0 } }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        if acceptSelfSigned { return (.useCredential, URLCredential(trust: trust)) }
        // The trust object already carries the SSL policy for this host name.
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return (.useCredential, URLCredential(trust: trust)) }
        let reason = (error as Error?)?.localizedDescription ?? "not trusted"
        failure.withLock { $0 = reason }
        return (.cancelAuthenticationChallenge, nil)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
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
