import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

// MARK: - Wire-level pieces every non-Gmail server needs

struct IMAPUTF7Tests {
    @Test func roundTripsNonASCII() {
        for name in ["Entwürfe", "Envoyés", "Papelera", "受信トレイ", "Grokbox/Nyhetsbrev", "A&B", "plain"] {
            let encoded = IMAPUTF7.encode(name)
            #expect(encoded.utf8.allSatisfy { $0 < 0x80 }, "encoded form is ASCII: \(encoded)")
            #expect(IMAPUTF7.decode(encoded) == name)
        }
    }

    @Test func matchesKnownServerSpellings() {
        #expect(IMAPUTF7.decode("Entw&APw-rfe") == "Entwürfe")
        #expect(IMAPUTF7.encode("Entwürfe") == "Entw&APw-rfe")
        #expect(IMAPUTF7.decode("A&-B") == "A&B")
        #expect(IMAPUTF7.decode("INBOX") == "INBOX")
    }

    @Test func malformedInputIsLeftAlone() {
        #expect(IMAPUTF7.decode("Broken&APw") == "Broken&APw")
    }
}

struct ListAndCopyUIDParsingTests {
    @Test func listLineCarriesTheDelimiter() throws {
        let dot = try #require(IMAPResponseParser.parseListLine(#"* LIST (\HasNoChildren) "." "INBOX.Sent""#))
        #expect(dot.delimiter == "." && dot.name == "INBOX.Sent")
        let slash = try #require(IMAPResponseParser.parseListLine(#"* LIST (\HasNoChildren \Sent) "/" "[Gmail]/Sent Mail""#))
        #expect(slash.delimiter == "/" && slash.isSent)
        let flat = try #require(IMAPResponseParser.parseListLine(#"* LIST (\Noinferiors) NIL "INBOX""#))
        #expect(flat.delimiter == nil)
        let utf7 = try #require(IMAPResponseParser.parseListLine(#"* LIST (\Drafts) "/" "Entw&APw-rfe""#))
        #expect(utf7.displayName == "Entwürfe")
    }

    @Test func copyUIDExpandsRangesInOrder() throws {
        let parsed = try #require(IMAPResponseParser.parseCopyUID("a5 OK [COPYUID 1725000000 10,12:14 301:304] Success"))
        #expect(parsed.validity == 1_725_000_000)
        #expect(parsed.destination == [301, 302, 303, 304])
        #expect(IMAPResponseParser.parseCopyUID("a5 OK Success") == nil)
        #expect(IMAPResponseParser.expandUIDSet("7") == [7])
    }
}

struct MailboxNamingTests {
    private func box(_ name: String, _ attrs: [String] = [], _ d: String? = "/") -> IMAPMailbox {
        IMAPMailbox(name: name, attributes: attrs, delimiter: d)
    }

    @Test func gmailStyleKeepsLogicalNames() {
        let boxes = [box("INBOX"), box("[Gmail]/All Mail", ["\\All"]), box("[Gmail]/Sent Mail", ["\\Sent"])]
        #expect(boxes.serverName(forLogical: "Grokbox/Newsletters") == "Grokbox/Newsletters")
    }

    @Test func dotDelimiterWithInboxNamespace() {
        let boxes = [box("INBOX", [], "."), box("INBOX.Sent", ["\\Sent"], "."), box("INBOX.Archive", [], ".")]
        #expect(boxes.hierarchyDelimiter == ".")
        #expect(boxes.personalNamespacePrefix == "INBOX.")
        #expect(boxes.serverName(forLogical: "Grokbox/Newsletters") == "INBOX.Grokbox.Newsletters")
    }

    @Test func nonASCIIFoldersAreEncodedForTheServer() {
        let boxes = [box("INBOX"), box("Sent", ["\\Sent"])]
        #expect(boxes.serverName(forLogical: "Grokbox/Nyhetsbrev – Föräldrar") == "Grokbox/Nyhetsbrev &IBM- F&APY-r&AOQ-ldrar")
    }

    @Test func sentIsFoundWithoutSpecialUse() {
        #expect([box("INBOX"), box("Sent Items")].sentMailbox?.name == "Sent Items")
        #expect([box("INBOX"), box("Envoyés")].sentMailbox?.name == "Envoyés")
        #expect([box("INBOX", [], "."), box("INBOX.Gesendet", [], ".")].sentMailbox?.name == "INBOX.Gesendet")
        #expect([box("INBOX"), box("Sentinel Reports")].sentMailbox == nil, "no substring false positives")
        #expect([box("INBOX"), box("Anything", ["\\Sent"])].sentMailbox?.name == "Anything", "special-use wins")
    }
}

// MARK: - Whole-feature flows against non-Gmail servers

@MainActor
@Suite(.serialized)
struct GenericServerFlowTests {
    private func setUp(flavor: DemoMailbox.Flavor, persona: DemoPersona = .personal)
        -> (ModelContainer, ModelContext, MailAccount, DemoMailbox) {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let mailbox = DemoMailbox(persona: persona, flavor: flavor)
        let account = MailAccount(displayName: "Generic", username: mailbox.username, host: "127.0.0.1",
                                  port: 0, kind: .demo, security: .none)
        context.insert(account); try! context.save()
        DemoRegistry.shared.register(mailbox, for: account.id)
        return (container, context, account, mailbox)
    }

    /// A plain RFC 3501 server: no labels, real folders, MOVE with COPYUID.
    /// Index → assess → sweep (moves into folders) → undo (moves back) →
    /// incremental re-index. Every step the UI exposes.
    @Test func plainIMAPServerSweepsAndUndoesByMoving() async throws {
        let (container, context, account, mailbox) = setUp(flavor: .generic(delimiter: "/", inboxPrefix: false))
        defer { DemoRegistry.shared.remove(account.id) }
        _ = container

        let engine = SyncEngine(modelContext: context)
        await engine.indexNow(account: account, mode: .full(limit: 10_000))
        guard case .finished = engine.phase else { Issue.record("index failed: \(engine.phase.label)"); return }

        let inboxBefore = mailbox.messages(in: "INBOX").count
        let id = account.id
        let indexed = try context.fetch(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == id }))
        #expect(indexed.count == inboxBefore, "on a plain server the inbox itself is indexed")
        let allInInbox = indexed.allSatisfy { $0.isInInbox }
        #expect(allInInbox)
        let contacts = try context.fetch(FetchDescriptor<ContactedAddress>())
        #expect(!contacts.isEmpty, "Sent was found by \\Sent and contacts learned")

        let plan = CleanupPlan.suggested(from: SenderProfileBuilder.assessments(for: account, in: context), rules: RuleStore.all(in: context))
        #expect(!plan.enabledItems.isEmpty)
        let executor = PlanExecutor(modelContext: context)
        await executor.apply(plan, to: account)
        guard case .finished = executor.phase else { Issue.record("sweep failed: \(executor.phase.label)"); return }

        let archives = try context.fetch(FetchDescriptor<CleanupAction>()).filter { $0.kind == .archive && $0.errorMessage == nil }
        #expect(!archives.isEmpty)
        for a in archives {
            #expect(a.isUndoable, "COPYUID made the move undoable")
            #expect(a.targetUIDs.count == a.uids.count)
            #expect(a.targetMailbox?.hasPrefix("Grokbox/") == true)
        }
        let moved = archives.reduce(0) { $0 + $1.uids.count }
        #expect(mailbox.messages(in: "INBOX").count == inboxBefore - moved, "messages left INBOX")
        let folders = Set(archives.compactMap(\.targetMailbox))
        #expect(folders.allSatisfy { mailbox.exists($0) }, "folders were created on the server")
        #expect(folders.reduce(0) { $0 + mailbox.messages(in: $1).count } == moved)

        // Undo one, by moving back from the folder.
        let first = try #require(archives.first)
        await executor.undo(first, on: account)
        #expect(first.isUndone, "undo phase: \(executor.phase.label)")
        #expect(mailbox.messages(in: "INBOX").count == inboxBefore - moved + first.uids.count)

        // A renumbered target folder is refused.
        let second = try #require(archives.dropFirst().first)
        mailbox.uidValidity += 1
        await executor.undo(second, on: account)
        #expect(!second.isUndone)
        guard case .failed(let why) = executor.phase else { Issue.record("expected refusal"); return }
        #expect(why.localizedCaseInsensitiveContains("renumbered"))
        mailbox.uidValidity -= 1

        // Incremental sync still works afterwards.
        await engine.indexNow(account: account, mode: .incremental(fallbackLimit: 100))
        guard case .finished = engine.phase else { Issue.record("incremental failed: \(engine.phase.label)"); return }
    }

    /// Courier/Dovecot style: `.` delimiter and everything under `INBOX.`.
    /// The folders Grokbox creates must land in that namespace.
    @Test func inboxPrefixedServerGetsCorrectlySpelledFolders() async throws {
        let (container, context, account, mailbox) = setUp(flavor: .generic(delimiter: ".", inboxPrefix: true))
        defer { DemoRegistry.shared.remove(account.id) }
        _ = container

        let boxes = mailbox.listMailboxes()
        #expect(boxes.hierarchyDelimiter == ".")
        #expect(boxes.personalNamespacePrefix == "INBOX.")
        #expect(boxes.sentMailbox?.name == "INBOX.Sent")
        #expect(boxes.contains { $0.displayName == "INBOX.Entwürfe" }, "UTF-7 name decodes for display")

        let engine = SyncEngine(modelContext: context)
        await engine.indexNow(account: account, mode: .full(limit: 10_000))
        guard case .finished = engine.phase else { Issue.record("index failed: \(engine.phase.label)"); return }

        let executor = PlanExecutor(modelContext: context)
        await executor.apply(CleanupPlan.suggested(from: SenderProfileBuilder.assessments(for: account, in: context)), to: account)
        guard case .finished = executor.phase else { Issue.record("sweep failed: \(executor.phase.label)"); return }

        let created = Set(try context.fetch(FetchDescriptor<CleanupAction>()).compactMap(\.targetMailbox))
        #expect(!created.isEmpty)
        for name in created {
            #expect(name.hasPrefix("INBOX.Grokbox."), Comment(rawValue: name))
            #expect(!name.contains("/"), "no foreign delimiter leaks: \(name)")
            #expect(mailbox.exists(name))
        }
        #expect(mailbox.messages(in: "INBOX").count < 1_000_000)   // sanity: still readable
        let undoable = try #require(try context.fetch(FetchDescriptor<CleanupAction>()).first { $0.isUndoable })
        await executor.undo(undoable, on: account)
        guard case .finished = executor.phase else { Issue.record("undo failed: \(executor.phase.label)"); return }
    }

    /// Every persona, every feature, on both server kinds: index, read with a
    /// model, digest, sweep, undo, export. The mock-data pass the UI relies on.
    @Test(arguments: [DemoPersona.personal, .work, .neglected])
    func everyFeatureOnEveryPersona(persona: DemoPersona) async throws {
        for flavor in [DemoMailbox.Flavor.gmail, .generic(delimiter: "/", inboxPrefix: false)] {
            let (container, context, account, _) = setUp(flavor: flavor, persona: persona)
            defer { DemoRegistry.shared.remove(account.id) }
            _ = container
            let label = "\(persona) / \(flavor.isGmail ? "gmail" : "generic")"

            let engine = SyncEngine(modelContext: context)
            await engine.indexNow(account: account, mode: .full(limit: 10_000))
            guard case .finished = engine.phase else { Issue.record("\(label): index \(engine.phase.label)"); continue }
            let id = account.id
            let count = try context.fetchCount(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == id }))
            #expect(count > 50, "\(label): indexed \(count)")

            await engine.readNow(account: account, model: StubModel(), limit: 30)
            guard case .finished = engine.phase else { Issue.record("\(label): read \(engine.phase.label)"); continue }
            let read = try context.fetch(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == id && $0.summary != nil }))
            #expect(!read.isEmpty, "\(label): summaries written")

            let digest = try DigestBuilder.build(for: [account], in: context)
            #expect(!digest.headline.isEmpty && !digest.narrative.isEmpty, Comment(rawValue: label))

            let assessed = SenderProfileBuilder.assessments(for: account, in: context)
            #expect(!assessed.isEmpty, "\(label): senders assessed")
            let executor = PlanExecutor(modelContext: context)
            await executor.apply(CleanupPlan.suggested(from: assessed), to: account)
            guard case .finished = executor.phase else { Issue.record("\(label): sweep \(executor.phase.label)"); continue }

            let actions = try context.fetch(FetchDescriptor<CleanupAction>()).filter { $0.errorMessage == nil }
            #expect(!actions.isEmpty, Comment(rawValue: label))
            if let undoable = actions.first(where: \.isUndoable) {
                await executor.undo(undoable, on: account)
                #expect(undoable.isUndone, "\(label): undo \(executor.phase.label)")
            }

            let export = try DataExport.encode(DataExport.document(from: context))
            let back = try DataExport.decode(export)
            let actionCount = try context.fetchCount(FetchDescriptor<CleanupAction>())
            #expect(back.actions.count == actionCount, Comment(rawValue: label))
            #expect(back.digests.count == 1, Comment(rawValue: label))
        }
    }
}
