import Foundation
import SwiftData

/// Everything Grokbox knows that came from *you* — accounts (never passwords),
/// rules, the action log, and saved digests — as one JSON document.
///
/// Message headers and sender profiles are deliberately not included: they are
/// a cache of your mail server and can be rebuilt by re-indexing. What cannot
/// be rebuilt is your decisions, and that is what this preserves.
public enum DataExport {
    public struct Document: Codable, Sendable, Equatable {
        public var format = "grokbox-export"
        public var version = 1
        public var exportedAt: Date
        public var accounts: [Account]
        public var rules: [Rule]
        public var actions: [Action]
        public var digests: [Digest]

        public struct Account: Codable, Sendable, Equatable {
            public var id: UUID, displayName: String, username: String, host: String, port: Int
            public var kind: String, security: String, createdAt: Date
        }
        public struct Rule: Codable, Sendable, Equatable {
            public var address: String, decision: String, createdAt: Date, timesApplied: Int
        }
        public struct Action: Codable, Sendable, Equatable {
            public var id: UUID, accountID: UUID, performedAt: Date, kind: String
            public var senderAddress: String, senderName: String, mailbox: String
            public var uids: [UInt32], labelName: String?, isUndoable: Bool, undoneAt: Date?, errorMessage: String?
        }
        public struct Digest: Codable, Sendable, Equatable {
            public var id: UUID, generatedAt: Date, scopeKey: String, scopeLabel: String
            public var headline: String, narrative: String, topItems: [DigestItem]
            public var needsYou: Int, worthKnowing: Int, dueSoon: Int, overdue: Int, quickWins: Int
        }
    }

    @MainActor
    public static func document(from context: ModelContext, now: Date = Date()) throws -> Document {
        let accounts = try context.fetch(FetchDescriptor<MailAccount>(sortBy: [SortDescriptor(\.createdAt)]))
        let rules = try context.fetch(FetchDescriptor<SenderRule>(sortBy: [SortDescriptor(\.createdAt)]))
        let actions = try context.fetch(FetchDescriptor<CleanupAction>(sortBy: [SortDescriptor(\.performedAt)]))
        let digests = try context.fetch(FetchDescriptor<InboxDigest>(sortBy: [SortDescriptor(\.generatedAt)]))
        return Document(
            exportedAt: now,
            accounts: accounts.map {
                .init(id: $0.id, displayName: $0.displayName, username: $0.username, host: $0.host, port: $0.port,
                      kind: $0.kindRaw, security: $0.securityRaw, createdAt: $0.createdAt) },
            rules: rules.map { .init(address: $0.address, decision: $0.decisionRaw, createdAt: $0.createdAt, timesApplied: $0.timesApplied) },
            actions: actions.map {
                .init(id: $0.id, accountID: $0.accountID, performedAt: $0.performedAt, kind: $0.kindRaw,
                      senderAddress: $0.senderAddress, senderName: $0.senderName, mailbox: $0.mailbox,
                      uids: $0.uids, labelName: $0.labelName, isUndoable: $0.isUndoable,
                      undoneAt: $0.undoneAt, errorMessage: $0.errorMessage) },
            digests: digests.map {
                .init(id: $0.id, generatedAt: $0.generatedAt, scopeKey: $0.scopeKey, scopeLabel: $0.scopeLabel,
                      headline: $0.headline, narrative: $0.narrative, topItems: $0.topItems,
                      needsYou: $0.needsYou, worthKnowing: $0.worthKnowing, dueSoon: $0.dueSoon,
                      overdue: $0.overdue, quickWins: $0.quickWins) })
    }

    public static func encode(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> Document {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Document.self, from: data)
    }

    /// Restores rules from an export into a context. Accounts, actions and
    /// digests are history and are not re-imported; rules are the one thing
    /// worth carrying to a fresh install.
    @MainActor
    @discardableResult
    public static func importRules(from document: Document, into context: ModelContext) throws -> Int {
        var imported = 0
        for rule in document.rules {
            let address = rule.address
            let existing = try context.fetch(FetchDescriptor<SenderRule>(predicate: #Predicate { $0.address == address })).first
            if let existing {
                existing.decisionRaw = rule.decision
            } else {
                let fresh = SenderRule(address: rule.address, decision: RuleDecision(rawValue: rule.decision) ?? .sweep)
                fresh.createdAt = rule.createdAt
                fresh.timesApplied = rule.timesApplied
                context.insert(fresh)
            }
            imported += 1
        }
        try context.save()
        return imported
    }
}
