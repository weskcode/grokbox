import Foundation
import Testing
@testable import GrokboxCore

/// STARTTLS must fail closed: on every path where the upgrade does not
/// happen, the connection ends and LOGIN, which carries the password, is
/// never sent. The scripted server speaks cleartext only, so it can prove
/// the refusals; the upgrade itself is exercised against a real server.
@Suite(.serialized)
struct StartTLSTests {
    private static let login = ("LOGIN", "{tag} OK logged in\r\n")

    private func run(greeting: String = "* OK ready", _ script: FakeIMAPServer.Script) async throws -> (Error?, [String]) {
        let server = try FakeIMAPServer(greeting: greeting, script: script + [Self.login])
        try await server.start()
        defer { server.stop() }
        let client = IMAPClient(connectTimeout: .seconds(3), readTimeout: .seconds(3))
        var failure: Error?
        do {
            try await client.connect(host: "127.0.0.1", port: Int(server.port), security: .starttls)
            // Only reached if connect wrongly succeeded; this is the leak to catch.
            try await client.login(username: "me@example.com", password: "secret")
        } catch {
            failure = error
        }
        await client.abort()
        return (failure, server.commands.map { $0.uppercased() })
    }

    @Test(.timeLimit(.minutes(1)))
    func aServerThatDoesNotOfferItIsRefused() async throws {
        let (error, commands) = try await run([("CAPABILITY", "* CAPABILITY IMAP4rev1 IDLE\r\n{tag} OK\r\n")])
        #expect({ if case .startTLSUnavailable = error as? IMAPError { true } else { false } }())
        #expect(!commands.contains { $0.hasPrefix("STARTTLS") })
        #expect(!commands.contains { $0.hasPrefix("LOGIN") })
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedUpgradeFailsClosed() async throws {
        let (error, commands) = try await run([
            ("CAPABILITY", "* CAPABILITY IMAP4rev1 STARTTLS\r\n{tag} OK\r\n"),
            ("STARTTLS", "{tag} NO not today\r\n"),
        ])
        #expect(error != nil)
        #expect(!commands.contains { $0.hasPrefix("LOGIN") })
    }

    /// Bytes after the OK arrived before encryption, so a man in the middle
    /// could have written them. The connection ends; they are never read as
    /// a reply. (If the bytes land in a later read, the handshake fails
    /// instead; either way nothing is sent.)
    @Test(.timeLimit(.minutes(1)))
    func dataInjectedAfterTheOKEndsTheConnection() async throws {
        let (error, commands) = try await run([
            ("CAPABILITY", "* CAPABILITY IMAP4rev1 STARTTLS\r\n{tag} OK\r\n"),
            ("STARTTLS", "{tag} OK Begin TLS\r\n* OK [ALERT] injected\r\n"),
        ])
        #expect(error is IMAPError)
        #expect(!commands.contains { $0.hasPrefix("LOGIN") })
    }

    /// The server says OK, then keeps talking cleartext: the handshake cannot
    /// complete and the client gives up without sending credentials.
    @Test(.timeLimit(.minutes(1)))
    func aHandshakeThatNeverCompletesSendsNothing() async throws {
        let (error, commands) = try await run([
            ("CAPABILITY", "* CAPABILITY IMAP4rev1 STARTTLS\r\n{tag} OK\r\n"),
            ("STARTTLS", "{tag} OK Begin TLS\r\n"),
        ])
        #expect(error != nil)
        #expect(!commands.contains { $0.hasPrefix("LOGIN") })
    }

    @Test(.timeLimit(.minutes(1)))
    func aPreauthGreetingCannotBeSecuredAndIsRefused() async throws {
        let (error, commands) = try await run(greeting: "* PREAUTH welcome back", [
            ("CAPABILITY", "* CAPABILITY IMAP4rev1 STARTTLS\r\n{tag} OK\r\n"),
        ])
        #expect({ if case .startTLSUnavailable = error as? IMAPError { true } else { false } }())
        #expect(!commands.contains { $0.hasPrefix("LOGIN") })
    }

    @Test func selfSignedSTARTTLSIsLoopbackOnly() async {
        let client = IMAPClient(connectTimeout: .seconds(2), readTimeout: .seconds(2))
        do {
            try await client.connect(host: "imap.example.com", port: 143, security: .starttlsSelfSignedLoopback)
            Issue.record("a self-signed STARTTLS connection to a remote host must be refused")
        } catch {
            #expect({ if case .insecureForRemoteHost = error as? IMAPError { true } else { false } }())
        }
        #expect(IMAPSecurity.starttls.requiresLoopback == false)
        #expect(IMAPSecurity.starttlsSelfSignedLoopback.requiresLoopback)
    }
}
