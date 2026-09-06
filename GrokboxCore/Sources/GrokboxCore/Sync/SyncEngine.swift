import Foundation
import SwiftData

/// Drives the two read-only passes over an account: **index** (headers into
/// SwiftData) and **read** (a local model over the messages that matter).
///
/// Deliberately sequential and interruptible: the point of a first run is that
/// the user can watch it, stop it, and confirm it touched nothing.
@MainActor
@Observable
public final class SyncEngine {
    public enum Phase: Equatable, Sendable {
        case idle
        case connecting
        case discovering
        case learningContacts(done: Int, total: Int)
        case indexing(done: Int, total: Int)
        case reading(done: Int, total: Int, model: String)
        case finished(String)
        case failed(String)

        public var isRunning: Bool {
            switch self {
            case .idle, .finished, .failed: false
            default: true
            }
        }

        public var label: String {
            switch self {
            case .idle: "Ready"
            case .connecting: "Connecting…"
            case .discovering: "Finding mailboxes…"
            case .learningContacts(let done, let total): "Learning who you write to — \(done) of \(total)"
            case .indexing(let done, let total): "Indexing — \(done.formatted()) of \(total.formatted())"
            case .reading(let done, let total, let model): "Reading with \(model) — \(done) of \(total)"
            case .finished(let message): message
            case .failed(let message): message
            }
        }

        public var fraction: Double? {
            switch self {
            case .learningContacts(let done, let total), .indexing(let done, let total), .reading(let done, let total, _):
                total > 0 ? Double(done) / Double(total) : nil
            default:
                nil
            }
        }
    }

    /// What the read pass looks at.
    public enum ReadScope: Sendable, Equatable {
        /// Recent unread mail from anyone the heuristics did not call bulk.
        case recent
        /// Older unread mail, but only from people and record-keeping senders —
        /// the things an ignored inbox is actually hiding.
        case catchUp(days: Int)

        public var days: Int {
            switch self {
            case .recent: ImportanceScorer.defaultWindowDays
            case .catchUp(let days): days
            }
        }
    }

    public enum IndexMode: Sendable {
        /// Walk the newest `limit` messages. Resets the incremental watermark.
        case full(limit: Int)
        /// Fetch only what arrived since last time, plus a flags refresh of the
        /// most recent messages. Falls back to `.full` if the mailbox was
        /// renumbered or never indexed.
        case incremental(fallbackLimit: Int)
    }

    /// IMAP servers dislike very large FETCH ranges; this keeps each round trip
    /// modest and lets progress update at a useful granularity.
    private static let batchSize = 250
    /// How many recent messages get a flags refresh on an incremental pass.
    private static let flagRefreshWindow = 300

    public private(set) var phase: Phase = .idle
    private var currentTask: Task<Void, Never>?
    /// The connection a run is currently using. `cancel()` disconnects it, which
    /// is what unblocks a read parked on a server that has gone quiet — task
    /// cancellation alone cannot reach into an NWConnection callback.
    private var activeProvider: (any MailProvider)?

    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
        if let provider = activeProvider {
            activeProvider = nil
            Task { await provider.finish() }
        }
        phase = .idle
    }

    // MARK: - Index

    public func index(account: MailAccount, messageLimit: Int) {
        guard !phase.isRunning else { return }
        currentTask = Task { [weak self] in
            await self?.runIndex(account: account, mode: .full(limit: messageLimit))
        }
    }

    /// Awaitable form, for callers that sequence passes (the maintainer).
    public func indexNow(account: MailAccount, mode: IndexMode) async {
        guard !phase.isRunning else { return }
        // Registered so Stop can reach it — the awaited form previously left
        // currentTask nil, which made cancel() a no-op on this path.
        let task = Task { await self.runIndex(account: account, mode: mode) }
        currentTask = task
        await task.value
        currentTask = nil
    }

    private func runIndex(account: MailAccount, mode: IndexMode) async {
        phase = .connecting
        let accountID = account.id
        do {
            let provider = try await MailProviderFactory.connect(to: account)
            activeProvider = provider
            defer { activeProvider = nil; Task { await provider.finish() } }

            phase = .discovering
            let mailboxes = try await provider.discoverMailboxes()
            try Task.checkCancellation()

            // Contacts change slowly: learn them on a full pass, and on the very
            // first pass of any kind — the first tidy-up must know who you talk to.
            let isFirstIndex = (try? modelContext.fetchCount(FetchDescriptor<MailboxSnapshot>(
                predicate: #Predicate { $0.accountID == accountID }))) == 0
            var shouldLearnContacts = isFirstIndex
            if case .full = mode { shouldLearnContacts = true }
            if shouldLearnContacts, let sent = mailboxes.sentMailbox {
                try await learnContacts(from: sent, using: provider)
            }
            try Task.checkCancellation()

            guard let archive = mailboxes.primaryArchive else {
                phase = .failed("Could not find a mailbox to index on this server.")
                return
            }

            let indexed = try await indexMailbox(archive, using: provider, account: account, mode: mode)

            // One pass over headers into per-sender rows; everything the UI shows
            // about senders comes from these, never from re-clustering in a view.
            phase = .indexing(done: indexed, total: max(indexed, 1))
            try SenderProfileBuilder.rebuild(for: account, in: modelContext)

            account.lastSyncedAt = Date()
            account.lastSyncError = nil
            try modelContext.save()
            phase = .finished(indexed == 0 ? "Nothing new" : "Indexed \(indexed.formatted()) messages")
        } catch is CancellationError {
            try? modelContext.save()
            phase = .idle
        } catch {
            account.lastSyncError = error.localizedDescription
            try? modelContext.save()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Walks the Sent mailbox recording every address the user has written to.
    /// Capped, because recent correspondence is what carries the signal.
    private func learnContacts(from mailbox: IMAPMailbox, using provider: MailProvider) async throws {
        let total = try await provider.openReadOnly(mailbox.name).exists
        guard total > 0 else { return }

        let cap = 2_000
        let start = max(1, total - cap + 1)
        var processed = 0

        var index = start
        while index <= total {
            try Task.checkCancellation()
            let end = min(index + Self.batchSize - 1, total)
            let batch = try await provider.headers(from: index, to: end)

            for header in batch {
                for address in header.recipients {
                    recordContact(address, at: header.date)
                }
            }

            processed += batch.count
            phase = .learningContacts(done: processed, total: total - start + 1)
            index = end + 1
        }

        try modelContext.save()
    }

    private func recordContact(_ address: String, at date: Date) {
        let descriptor = FetchDescriptor<ContactedAddress>(
            predicate: #Predicate { $0.address == address }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.timesContacted += 1
            existing.lastContactedAt = max(existing.lastContactedAt, date)
        } else {
            modelContext.insert(ContactedAddress(address: address, lastContactedAt: date))
        }
    }

    private func indexMailbox(
        _ mailbox: IMAPMailbox,
        using provider: MailProvider,
        account: MailAccount,
        mode: IndexMode
    ) async throws -> Int {
        let status = try await provider.openReadOnly(mailbox.name)
        let snapshot = self.snapshot(for: account, mailbox: mailbox.name)

        // Decide whether the stored UIDs still mean anything.
        let canGoIncremental: Bool
        if case .incremental = mode, let snapshot, let validity = status.uidValidity, snapshot.uidValidity == validity, snapshot.highestUID > 0 {
            canGoIncremental = true
        } else {
            canGoIncremental = false
        }

        if let snapshot, let validity = status.uidValidity, snapshot.uidValidity != validity {
            // Renumbered: everything we hold for this mailbox is wrong.
            for message in messages(in: account, mailbox: mailbox.name) { modelContext.delete(message) }
            modelContext.delete(snapshot)
            try modelContext.save()
        }

        let indexed: Int
        var highest = canGoIncremental ? snapshot!.highestUID : 0

        if canGoIncremental {
            indexed = try await indexIncrementally(mailbox, using: provider, account: account, status: status, highest: &highest)
        } else {
            let limit: Int = switch mode {
            case .full(let limit): limit
            case .incremental(let fallback): fallback
            }
            indexed = try await indexFully(mailbox, using: provider, account: account, status: status, limit: limit, highest: &highest)
        }

        if let validity = status.uidValidity {
            let current = self.snapshot(for: account, mailbox: mailbox.name)
                ?? MailboxSnapshot(accountID: account.id, mailbox: mailbox.name, uidValidity: validity, highestUID: 0, messageCountOnServer: 0)
            if current.modelContext == nil { modelContext.insert(current) }
            current.uidValidity = validity
            current.highestUID = max(current.highestUID, highest)
            current.messageCountOnServer = status.exists
            current.lastIndexedAt = Date()
        }
        try modelContext.save()
        return indexed
    }

    /// Full walk of the newest `limit` messages by sequence number.
    private func indexFully(
        _ mailbox: IMAPMailbox, using provider: MailProvider, account: MailAccount,
        status: MailboxStatus, limit: Int, highest: inout UInt32
    ) async throws -> Int {
        let total = status.exists
        guard total > 0 else { return 0 }

        // Sequence numbers run oldest to newest, so the newest `limit` messages
        // are the tail of the range.
        let start = max(1, total - limit + 1)
        let plannedCount = total - start + 1
        var indexed = 0

        let existing = Dictionary(messages(in: account, mailbox: mailbox.name).map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<UInt32>()

        var index = start
        while index <= total {
            try Task.checkCancellation()
            let end = min(index + Self.batchSize - 1, total)
            let batch = try await provider.headers(from: index, to: end)
            for header in batch where !header.senderAddress.isEmpty {
                seen.insert(header.uid)
                highest = max(highest, header.uid)
                upsert(header, into: existing, mailbox: mailbox.name, account: account)
                indexed += 1
            }
            phase = .indexing(done: indexed, total: plannedCount)
            try modelContext.save()
            index = end + 1
        }

        // Anything previously indexed in the walked range that the server no
        // longer reports is gone. Older-than-walk messages are left alone.
        for (uid, message) in existing where !seen.contains(uid) && uid >= (batchFloorUID(existing: existing, seen: seen)) {
            modelContext.delete(message)
        }
        return indexed
    }

    /// New messages by UID range, then a cheap flags refresh of the recent tail.
    private func indexIncrementally(
        _ mailbox: IMAPMailbox, using provider: MailProvider, account: MailAccount,
        status: MailboxStatus, highest: inout UInt32
    ) async throws -> Int {
        let existing = Dictionary(messages(in: account, mailbox: mailbox.name).map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        var indexed = 0

        let fresh = try await provider.headers(uidsFrom: highest + 1)
        for header in fresh where !header.senderAddress.isEmpty && existing[header.uid] == nil {
            highest = max(highest, header.uid)
            upsert(header, into: existing, mailbox: mailbox.name, account: account)
            indexed += 1
        }
        phase = .indexing(done: indexed, total: max(indexed, 1))
        try modelContext.save()

        // Read/unread and inbox membership drift constantly; refresh the tail.
        let total = status.exists
        if total > 0 {
            let start = max(1, total - Self.flagRefreshWindow + 1)
            let updates = try await provider.flags(from: start, to: total)
            for update in updates {
                guard let message = existing[update.uid] else { continue }
                message.isUnread = update.isUnread
                message.isFlagged = update.isFlagged
                message.isInInbox = update.isInInbox
                // If the server says it is back in the inbox, our local sweep mark is stale.
                if update.isInInbox { message.isSweptLocally = false }
            }
            try modelContext.save()
        }
        return indexed
    }

    private func upsert(_ header: FetchedHeader, into existing: [UInt32: MessageHeader], mailbox: String, account: MailAccount) {
        if let current = existing[header.uid] {
            current.isUnread = header.isUnread
            current.isFlagged = header.isFlagged
            current.isInInbox = header.isInInbox
            if header.isInInbox { current.isSweptLocally = false }
        } else {
            let message = MessageHeader(
                accountID: account.id,
                uid: header.uid,
                mailbox: mailbox,
                subject: header.subject,
                senderName: header.senderName,
                senderAddress: header.senderAddress,
                receivedAt: header.date,
                isUnread: header.isUnread,
                isFlagged: header.isFlagged,
                listUnsubscribe: header.listUnsubscribe,
                listUnsubscribePost: header.listUnsubscribePost,
                listID: header.listID,
                messageID: header.messageID,
                isInInbox: header.isInInbox
            )
            modelContext.insert(message)
        }
    }

    /// The lowest UID the full walk covered. Messages below it were outside the
    /// walk and must not be deleted just because they were not seen.
    private func batchFloorUID(existing: [UInt32: MessageHeader], seen: Set<UInt32>) -> UInt32 {
        seen.min() ?? UInt32.max
    }

    // MARK: - Read

    /// Runs a local model over the messages most likely to matter, storing a
    /// one-line summary and an importance call on each. Bodies are fetched,
    /// read, and dropped; they never touch disk.
    public func read(account: MailAccount, model: any TextModel, limit: Int = 150, scope: ReadScope = .recent) {
        guard !phase.isRunning else { return }
        currentTask = Task { [weak self] in
            await self?.runRead(account: account, model: model, limit: limit, scope: scope)
        }
    }

    public func readNow(account: MailAccount, model: any TextModel, limit: Int = 150, scope: ReadScope = .recent) async {
        guard !phase.isRunning else { return }
        let task = Task { await self.runRead(account: account, model: model, limit: limit, scope: scope) }
        currentTask = task
        await task.value
        currentTask = nil
    }

    private func runRead(account: MailAccount, model: any TextModel, limit: Int, scope: ReadScope) async {
        phase = .connecting
        do {
            // Only the unread, unswept window is ever loaded — not the whole
            // mailbox — so this stays cheap at 40,000 messages.
            var all = recentUnreadMessages(in: account, days: scope.days)
            let contacted = Set(((try? modelContext.fetch(FetchDescriptor<ContactedAddress>())) ?? []).map(\.address))
            let profiles = SenderProfileBuilder.profiles(for: account, in: modelContext)
            let verdicts = Dictionary(profiles.map { ($0.address, $0.verdict) }, uniquingKeysWith: { a, _ in a })

            if case .catchUp = scope {
                // Older mail is only worth the model's time if a person or a
                // record-keeper sent it, or the reader flagged it.
                let worthIt = Set(profiles.filter { $0.category == .person || $0.category == .transactional }.map(\.address))
                all = all.filter { worthIt.contains($0.senderAddress) || $0.isFlagged }
            }

            let candidates = ImportanceScorer.candidates(
                in: all,
                verdictFor: { verdicts[$0] },
                contacted: contacted,
                windowDays: scope.days,
                limit: limit
            )
            let byUID = Dictionary(all.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })

            // Free tier: heuristics already decided these.
            for candidate in candidates where candidate.skipModel {
                guard let message = byUID[candidate.uid] else { continue }
                message.importance = candidate.baseline
                message.importanceReason = "Bulk sender"
                message.readAt = Date()
            }
            try modelContext.save()

            let toRead = candidates.filter { !$0.skipModel }
            guard !toRead.isEmpty else {
                phase = .finished("Nothing new to read")
                return
            }

            let provider = try await MailProviderFactory.connect(to: account)
            activeProvider = provider
            defer { activeProvider = nil; Task { await provider.finish() } }

            var done = 0
            var consecutiveModelFailures = 0
            var openMailbox: String?

            for candidate in toRead {
                try Task.checkCancellation()
                guard let message = byUID[candidate.uid] else { continue }

                if openMailbox != message.mailbox {
                    _ = try await provider.openReadOnly(message.mailbox)
                    openMailbox = message.mailbox
                }

                let excerpt = (try? await provider.bodyExcerpt(uid: message.uid))
                    .map { BodyExtractor.plainText(from: $0) } ?? ""

                let request = ReadRequest(
                    subject: message.subject,
                    senderName: message.senderName,
                    senderAddress: message.senderAddress,
                    senderIsKnownContact: contacted.contains(message.senderAddress),
                    receivedAt: message.receivedAt,
                    bodyExcerpt: excerpt
                )

                do {
                    let result = try await model.read(request)
                    message.summary = ReaderPrompt.sanitize(result.summary)
                    message.importance = result.importance
                    message.importanceReason = result.reason
                    message.actionType = result.importance == .needsYou ? result.actionType : .none
                    message.dueHint = result.dueHint
                    message.dueAt = DueDateParser.parse(result.dueHint, relativeTo: message.receivedAt)
                    message.isQuick = result.isQuick && result.importance == .needsYou
                    consecutiveModelFailures = 0
                } catch {
                    // One bad message should not sink the pass (a guardrail refusal
                    // on a single email is normal). A long run of failures means the
                    // model itself is broken, and we should stop and say so.
                    message.importance = candidate.baseline
                    message.importanceReason = "Model could not read this; heuristic guess"
                    consecutiveModelFailures += 1
                    if consecutiveModelFailures >= 8 {
                        throw error
                    }
                }
                message.readAt = Date()

                done += 1
                phase = .reading(done: done, total: toRead.count, model: model.name)
                if done % 10 == 0 { try modelContext.save() }
            }

            let sorted = await categorizeUnsorted(account: account, model: model, limit: 40)

            account.lastReadAt = Date()
            try modelContext.save()
            phase = .finished("Read \(done) messages with \(model.name)" + (sorted > 0 ? ", sorted \(sorted) senders" : ""))
        } catch is CancellationError {
            try? modelContext.save()
            phase = .idle
        } catch {
            try? modelContext.save()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Asks the model about senders the heuristics could not place. Capped;
    /// every call is one sender, never one message, so this stays cheap.
    private func categorizeUnsorted(account: MailAccount, model: any TextModel, limit: Int) async -> Int {
        // Only senders the heuristics could not place at all. An unconfident but
        // evidence-based placement is still explainable; a model override is not.
        let unsorted = SenderProfileBuilder.profiles(for: account, in: modelContext)
            .filter { !$0.categoryFromModel && $0.messageCount >= 2 }
            .filter { $0.category == .unknown || (!$0.categoryConfident && $0.categoryEvidence == SenderCategorizer.unsureBulkEvidence) }
            .sorted { $0.messageCount > $1.messageCount }
            .prefix(limit)
        var done = 0
        for profile in unsorted {
            guard !Task.isCancelled else { break }
            let request = CategorizeRequest(
                displayName: profile.displayName, address: profile.address, sampleSubjects: profile.sampleSubjects,
                messageCount: profile.messageCount, unreadRatio: profile.unreadRatio, hasUnsubscribeLink: profile.hasUnsubscribeLink
            )
            guard let result = try? await model.categorize(request), result.category != .unknown else { continue }
            SenderProfileBuilder.setModelCategory(result.category, evidence: result.reason, on: profile)
            done += 1
        }
        try? modelContext.save()
        return done
    }

    // MARK: - Queries

    private func recentUnreadMessages(in account: MailAccount, days: Int) -> [MessageHeader] {
        let accountID = account.id
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        var descriptor = FetchDescriptor<MessageHeader>(
            predicate: #Predicate { $0.accountID == accountID && $0.receivedAt >= cutoff && $0.isSweptLocally == false && $0.readAt == nil },
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 2_000
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func messages(in account: MailAccount, mailbox: String?) -> [MessageHeader] {
        let accountID = account.id
        let descriptor: FetchDescriptor<MessageHeader>
        if let mailbox {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.accountID == accountID && $0.mailbox == mailbox })
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.accountID == accountID })
        }
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func snapshot(for account: MailAccount, mailbox: String) -> MailboxSnapshot? {
        let key = MailboxSnapshot.key(accountID: account.id, mailbox: mailbox)
        return try? modelContext.fetch(FetchDescriptor<MailboxSnapshot>(predicate: #Predicate { $0.key == key })).first
    }
}
