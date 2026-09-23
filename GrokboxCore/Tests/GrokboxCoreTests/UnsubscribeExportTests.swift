import Foundation
import Testing
@testable import GrokboxCore

struct UnsubscribeExportTests {
    private func cluster(
        address: String, unsubscribeValue: String?, category: SenderCategory = .promotion
    ) -> SenderCluster {
        SenderCluster(
            address: address, displayName: address, domain: "example.com", mailbox: "INBOX",
            uids: [], unreadUIDs: [], messageCount: 10, unreadCount: 9, flaggedCount: 0, sweptCount: 0,
            newest: .now, oldest: .now, hasUnsubscribeLink: unsubscribeValue != nil,
            unsubscribeValue: unsubscribeValue, supportsOneClickUnsubscribe: false,
            everContacted: false, sampleSubjects: [], category: category
        )
    }

    @Test func includesOnlyClustersWithAResolvableURL() {
        let withLink = cluster(address: "promo@example.com", unsubscribeValue: "<https://example.com/unsub>")
        let mailtoOnly = cluster(address: "digest@example.com", unsubscribeValue: "<mailto:unsub@example.com>")
        let noLink = cluster(address: "person@example.com", unsubscribeValue: nil, category: .person)

        let document = UnsubscribeExport.document(from: [withLink, mailtoOnly, noLink])

        #expect(document.senders.map(\.address) == ["promo@example.com"])
        #expect(document.senders.first?.unsubscribeURL == "https://example.com/unsub")
        #expect(document.senders.first?.category == "promotion")
    }

    @Test func formatAndVersionAreStable() {
        let document = UnsubscribeExport.document(from: [])
        #expect(document.format == "grokbox-unsubscribe-export")
        #expect(document.version == 1)
        #expect(document.senders.isEmpty)
    }

    @Test func encodesToValidJSON() throws {
        let cluster = cluster(address: "promo@example.com", unsubscribeValue: "<https://example.com/unsub>")
        // A whole-second timestamp: ISO 8601 round-trips it exactly, unlike `Date.now`'s fractional seconds.
        let document = UnsubscribeExport.document(from: [cluster], now: Date(timeIntervalSince1970: 1_700_000_000))

        let data = try UnsubscribeExport.encode(document)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UnsubscribeExport.Document.self, from: data)

        #expect(decoded == document)
    }
}
