import Foundation

/// Reads one message's body on demand, for display only.
///
/// Wraps the same three calls `SyncEngine.runRead` already makes
/// (`MailProviderFactory.connect` → `openReadOnly` (`EXAMINE`) →
/// `bodyExcerpt(uid:)` (`BODY.PEEK`) → `BodyExtractor.plainText`), adds a
/// `LinkHygiene` check of the same body, and always opens its own connection — never `AppState`'s sync-engine or executor
/// connection — so an unrelated Stop action can never tear this down, and it
/// never contends with the sync engine for ownership of the account's
/// connection. Nothing is written back to `MessageHeader`; the caller
/// discards the text when it is done with it.
public enum MessageBodyReader {
    public enum ReaderError: LocalizedError, Sendable, Equatable {
        case empty

        public var errorDescription: String? {
            switch self {
            case .empty: "This message has no readable body."
            }
        }
    }

    /// What the reader shows: the text, and any phishing tells in its links.
    public struct Reading: Sendable, Equatable {
        public var text: String
        public var linkWarnings: [String]
    }

    @MainActor
    public static func read(uid: UInt32, mailbox: String, account: MailAccount, senderDomain: String) async throws -> Reading {
        let provider = try await MailProviderFactory.connect(to: account)
        defer { Task { await provider.finish() } }
        _ = try await provider.openReadOnly(mailbox)
        guard let raw = try await provider.bodyExcerpt(uid: uid) else { throw ReaderError.empty }
        let parts = BodyExtractor.extract(from: raw)
        let text = BodyExtractor.plainText(from: parts)
        guard !text.isEmpty else { throw ReaderError.empty }
        return Reading(text: text, linkWarnings: LinkHygiene.inspect(parts, senderDomain: senderDomain).warnings)
    }
}
