import Foundation

/// Reads one message's body on demand, for display only.
///
/// Wraps the same three calls `SyncEngine.runRead` already makes
/// (`MailProviderFactory.connect` → `openReadOnly` (`EXAMINE`) →
/// `bodyExcerpt(uid:)` (`BODY.PEEK`) → `BodyExtractor.plainText`), but always
/// opens its own connection — never `AppState`'s sync-engine or executor
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

    @MainActor
    public static func read(uid: UInt32, mailbox: String, account: MailAccount) async throws -> String {
        let provider = try await MailProviderFactory.connect(to: account)
        defer { Task { await provider.finish() } }
        _ = try await provider.openReadOnly(mailbox)
        guard let raw = try await provider.bodyExcerpt(uid: uid) else { throw ReaderError.empty }
        let text = BodyExtractor.plainText(from: raw)
        guard !text.isEmpty else { throw ReaderError.empty }
        return text
    }
}
