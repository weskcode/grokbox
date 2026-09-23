import Foundation

/// The list of senders a user approved for unsubscribing, as a JSON file —
/// for handing to a browser-automation tool the user runs and controls
/// themselves. Grokbox does not visit these URLs and makes no network
/// connection here; the only thing this does is read `SenderCluster` values
/// already computed on-device and write them to a `Data` blob. The one thing
/// that actually unsubscribes on Grokbox's own behalf is `UnsubscribeService`.
public enum UnsubscribeExport {
    public struct Document: Codable, Sendable, Equatable {
        public var format = "grokbox-unsubscribe-export"
        public var version = 1
        public var exportedAt: Date
        public var senders: [Sender]

        public struct Sender: Codable, Sendable, Equatable {
            public var displayName: String
            public var address: String
            public var unsubscribeURL: String
            public var category: String
        }
    }

    /// Only clusters with a concrete http/https unsubscribe target are
    /// included — a mailto-only sender needs the mail app, not a browser.
    public static func document(from candidates: [SenderCluster], now: Date = Date()) -> Document {
        Document(
            exportedAt: now,
            senders: candidates.compactMap { cluster in
                guard let url = cluster.unsubscribeURL else { return nil }
                return Document.Sender(displayName: cluster.displayName, address: cluster.address,
                                        unsubscribeURL: url.absoluteString, category: cluster.category.rawValue)
            }
        )
    }

    public static func encode(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }
}
