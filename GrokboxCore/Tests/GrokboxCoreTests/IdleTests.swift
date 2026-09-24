import Foundation
import Testing
@testable import GrokboxCore

/// IMAP IDLE (RFC 2177) as the inbox watcher uses it: listen on the open
/// mailbox, report new mail, and never mistake mail leaving for mail arriving.
@Suite(.serialized)
struct IdleTests {
    private func idle(_ idleResponse: String, maxWait: Duration) async throws -> (Bool, [String]) {
        let server = try FakeIMAPServer(script: [
            ("LOGIN", "{tag} OK\r\n"),
            ("CAPABILITY", "* CAPABILITY IMAP4rev1 IDLE\r\n{tag} OK\r\n"),
            ("EXAMINE", "* 3 EXISTS\r\n* OK [UIDVALIDITY 1] ok\r\n{tag} OK [READ-ONLY] done\r\n"),
            ("IDLE", idleResponse),
            ("LOGOUT", "* BYE\r\n{tag} OK\r\n"),
        ])
        try await server.start()
        defer { server.stop() }
        let client = IMAPClient(connectTimeout: .seconds(5), readTimeout: .seconds(5))
        try await client.connect(host: "127.0.0.1", port: Int(server.port), security: .none)
        try await client.login(username: "u", password: "p")
        #expect(await client.capabilities.supportsIdle)
        try await client.examine("INBOX")
        let newMail = try await client.idle(maxWait: maxWait)
        await client.logout()
        return (newMail, server.commands.map { $0.uppercased() })
    }

    @Test(.timeLimit(.minutes(1)))
    func newMailEndsTheIdleAtOnce() async throws {
        let start = ContinuousClock.now
        let (newMail, commands) = try await idle("+ idling\r\n* 4 EXISTS\r\n", maxWait: .seconds(30))
        #expect(newMail)
        #expect(ContinuousClock.now - start < .seconds(10), "should not wait out maxWait")
        #expect(commands.filter { $0 == "DONE" }.count == 1, "DONE exactly once")
    }

    @Test(.timeLimit(.minutes(1)))
    func quietTimeRunsOutAndReportsNothing() async throws {
        let (newMail, commands) = try await idle("+ idling\r\n", maxWait: .seconds(1))
        #expect(!newMail)
        #expect(commands.contains("DONE"))
    }

    /// What Grokbox's own archiving looks like from an idle inbox.
    @Test(.timeLimit(.minutes(1)))
    func mailLeavingIsNotNewMail() async throws {
        let (newMail, _) = try await idle("+ idling\r\n* 2 EXPUNGE\r\n* 1 EXPUNGE\r\n", maxWait: .seconds(1))
        #expect(!newMail)
    }

    /// One left and one arrived: the count is back where it was, but a
    /// message is new.
    @Test(.timeLimit(.minutes(1)))
    func anArrivalAfterARemovalIsStillNewMail() async throws {
        let (newMail, _) = try await idle("+ idling\r\n* 3 EXPUNGE\r\n* 3 EXISTS\r\n", maxWait: .seconds(5))
        #expect(newMail)
    }

    @Test(.timeLimit(.minutes(1)))
    func aServerThatRefusesIdleIsAnError() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await idle("{tag} BAD not here\r\n", maxWait: .seconds(1))
        }
    }
}

/// When new mail brings a tidy-up forward, and when it does not.
struct NewMailSchedulingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func waitsForABurstToSettle() {
        #expect(!Maintainer.newMailIsDue(now: now, newMailAt: now.addingTimeInterval(-5), lastRunAt: nil))
        #expect(Maintainer.newMailIsDue(now: now, newMailAt: now.addingTimeInterval(-25), lastRunAt: nil))
    }

    @Test func neverSoonerThanFiveMinutesAfterTheLastPass() {
        let arrived = now.addingTimeInterval(-60)
        #expect(!Maintainer.newMailIsDue(now: now, newMailAt: arrived, lastRunAt: now.addingTimeInterval(-120)))
        #expect(Maintainer.newMailIsDue(now: now, newMailAt: arrived, lastRunAt: now.addingTimeInterval(-301)))
    }

    @Test func nothingWaitingMeansNothingDue() {
        #expect(!Maintainer.newMailIsDue(now: now, newMailAt: nil, lastRunAt: nil))
    }
}
