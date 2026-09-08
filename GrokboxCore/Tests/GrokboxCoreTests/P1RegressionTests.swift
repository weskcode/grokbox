import Foundation
import Network
import Testing
import SwiftData
@testable import GrokboxCore

/// A server that completes the TCP handshake and then says nothing, forever.
/// This is the failure the deadline exists for: not a refused connection, not a
/// reset — a socket that is open and silent.
final class SilentServer: @unchecked Sendable {
    private let listener: NWListener
    private var held: [NWConnection] = []
    private let lock = NSLock()
    private(set) var port: UInt16 = 0

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }
    func start() async throws {
        listener.newConnectionHandler = { [weak self] c in
            c.start(queue: .global())
            self?.lock.lock(); self?.held.append(c); self?.lock.unlock()   // accept, never send
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OneShotLatch()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: if once.claim() { self?.port = self?.listener.port?.rawValue ?? 0; cont.resume() }
                case .failed(let e): if once.claim() { cont.resume(throwing: e) }
                default: break }
            }
            listener.start(queue: .global())
        }
    }
    func stop() { listener.cancel(); lock.lock(); held.forEach { $0.cancel() }; held.removeAll(); lock.unlock() }
}

@Suite(.serialized)
struct IMAPDeadlineTests {
    /// Regression for the P1 found in the audit: `withTimeout` raced a sleeper
    /// against a parked `NWConnection` continuation inside a throwing task group.
    /// The sleeper won the race but the group could not unwind, so the deadline
    /// never fired and one silent server wedged the whole engine for the session.
    /// Reproduced before the fix: a 3-second deadline had not fired after 12 s.
    @Test(.timeLimit(.minutes(1)))
    func readDeadlineActuallyFires() async throws {
        let server = try SilentServer()
        try await server.start()
        defer { server.stop() }

        let client = IMAPClient(connectTimeout: .seconds(20), readTimeout: .seconds(2))
        let start = ContinuousClock.now
        // The greeting read is the first thing connect() does, and it never comes.
        await #expect(throws: IMAPError.self) {
            try await client.connect(host: "127.0.0.1", port: Int(server.port), security: .none)
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(15), "deadline did not fire; took \(elapsed)")
        await client.logout()
    }

    /// A connect to a black hole must also give up rather than hang forever.
    @Test(.timeLimit(.minutes(1)))
    func connectDeadlineActuallyFires() async throws {
        let client = IMAPClient(connectTimeout: .seconds(2), readTimeout: .seconds(90))
        let start = ContinuousClock.now
        // 198.51.100.0/24 is TEST-NET-2: routable-looking, never answers.
        await #expect(throws: IMAPError.self) {
            try await client.connect(host: "198.51.100.7", port: 993, security: .tls)
        }
        #expect(ContinuousClock.now - start < .seconds(25))
        await client.logout()
    }

    /// Stop must work even while a read is parked on a silent socket — the case
    /// where `Task.checkCancellation()` can never be reached.
    @Test(.timeLimit(.minutes(1)))
    func disconnectUnblocksAParkedRead() async throws {
        let server = try SilentServer()
        try await server.start()
        defer { server.stop() }

        // Long enough that only the disconnect can free it.
        let conn = IMAPConnection(readTimeout: .seconds(120))
        try await conn.connect(host: "127.0.0.1", port: Int(server.port), security: .none)
        let reader = Task { try await conn.readResponseLine() }
        try await Task.sleep(for: .milliseconds(400))
        await conn.disconnect()

        let start = ContinuousClock.now
        await #expect(throws: Error.self) { try await reader.value }
        #expect(ContinuousClock.now - start < .seconds(10), "disconnect did not free the parked read")
    }
}

@MainActor
@Suite(.serialized)
struct UndoSafetyTests {
    /// Builds the exact state a completed sweep leaves behind, without running
    /// the whole index/sweep pipeline: one archived message and the
    /// `CleanupAction` that archived it, stamped with the validity it ran under.
    private func sweptState(validity: UInt32)
        -> (ModelContainer, ModelContext, MailAccount, CleanupAction, DemoMailbox) {
        // The container is returned, not discarded: `mainContext` does not keep
        // its container alive, and a context whose container has been released
        // traps on the first insert.
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let mailbox = DemoMailbox(persona: .personal)
        mailbox.uidValidity = validity

        let account = MailAccount(displayName: "Demo", username: DemoMailbox.password,
                                  host: "127.0.0.1", port: 0, kind: .demo, security: .none)
        context.insert(account)
        DemoRegistry.shared.register(mailbox, for: account.id)

        // Archive one real message in the demo mailbox, the way a sweep would.
        let target = mailbox.messages(in: DemoMailbox.allMail).first { $0.labels.contains("\\Inbox") }!
        mailbox.store(in: DemoMailbox.allMail, uids: [target.uid], add: false, labels: ["\\Inbox"])

        let header = MessageHeader(
            accountID: account.id, uid: target.uid, mailbox: DemoMailbox.allMail,
            subject: target.subject, senderName: target.fromName, senderAddress: target.fromAddress,
            receivedAt: target.date, isUnread: true, isFlagged: false,
            listUnsubscribe: nil, listUnsubscribePost: nil, listID: nil, messageID: nil,
            isInInbox: false)
        header.isSweptLocally = true
        context.insert(header)

        let action = CleanupAction(
            accountID: account.id, kind: .archive, senderAddress: target.fromAddress,
            senderName: target.fromName, mailbox: DemoMailbox.allMail, uids: [target.uid],
            isUndoable: true, uidValidity: validity)
        context.insert(action)
        try! context.save()
        return (container, context, account, action, mailbox)
    }

    /// Regression for the P1. The guard used to compare the server's UIDVALIDITY
    /// against the `MailboxSnapshot` — but an index pass overwrites that snapshot
    /// with whatever the server now reports, so after a renumber the snapshot
    /// agreed with the server, the guard passed, and Undo pushed stale UIDs at
    /// whatever messages now held those numbers.
    @Test func undoRefusesAfterTheMailboxIsRenumbered() async throws {
        let (container, context, account, action, mailbox) = sweptState(validity: 1_000)
        defer { DemoRegistry.shared.remove(account.id) }
        _ = container   // held for the duration of the test
        #expect(action.uidValidity == 1_000, "the action records the validity it ran under")

        mailbox.uidValidity = 1_001          // the server renumbered
        let executor = PlanExecutor(modelContext: context)
        await executor.undo(action, on: account)

        guard case .failed(let message) = executor.phase else {
            Issue.record("undo should have refused; phase was \(executor.phase.label)"); return
        }
        #expect(message.localizedCaseInsensitiveContains("renumbered"))
        #expect(!action.isUndone, "nothing was undone")
        let restored = mailbox.messages(in: DemoMailbox.allMail).first { $0.uid == action.uids[0] }!
        #expect(!restored.labels.contains("\\Inbox"), "the mailbox was not touched")
    }

    /// The guard must not be so eager that it blocks the ordinary case.
    @Test func undoStillWorksWhenNothingChanged() async throws {
        let (container, context, account, action, mailbox) = sweptState(validity: 1_000)
        defer { DemoRegistry.shared.remove(account.id) }
        _ = container   // held for the duration of the test

        let executor = PlanExecutor(modelContext: context)
        await executor.undo(action, on: account)

        #expect(action.isUndone, "phase was \(executor.phase.label)")
        let restored = mailbox.messages(in: DemoMailbox.allMail).first { $0.uid == action.uids[0] }!
        #expect(restored.labels.contains("\\Inbox"), "the message is back in the inbox")
    }

    /// Actions written before the stamp existed fall back to the old snapshot
    /// check rather than becoming permanently un-undoable.
    @Test func unstampedActionsStillUndo() async throws {
        let (container, context, account, action, _) = sweptState(validity: 1_000)
        defer { DemoRegistry.shared.remove(account.id) }
        _ = container   // held for the duration of the test
        action.uidValidity = 0               // as an action recorded by an older build
        try context.save()

        let executor = PlanExecutor(modelContext: context)
        await executor.undo(action, on: account)
        #expect(action.isUndone, "phase was \(executor.phase.label)")
    }
}

struct StoreVersioningTests {
    @Test func openingInMemoryNeverReportsRecovery() {
        let opened = GrokboxStore.open(inMemory: true)
        #expect(opened.recovery == nil)
        #expect(opened.isEphemeral)
    }
}

extension ModelContainer {
    /// One place for the test schema, so adding a model does not mean editing
    /// six test files.
    static func grokboxTestContainer() -> ModelContainer {
        let schema = Schema(versionedSchema: GrokboxSchemaV1.self)
        return try! ModelContainer(for: schema, migrationPlan: GrokboxMigrationPlan.self,
                                   configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }
}
