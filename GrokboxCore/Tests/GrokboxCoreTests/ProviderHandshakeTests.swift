import Foundation
import Testing
@testable import GrokboxCore

/// The transport layer against the real servers people actually use: TLS
/// handshake with certificate validation, greeting, CAPABILITY. No credentials
/// are sent. If one of these fails, "any provider" is not true yet.
@Suite(.serialized)
struct ProviderHandshakeTests {
    struct Provider: CustomTestStringConvertible {
        let name: String, host: String
        var testDescription: String { name }
    }
    static let providers = [
        Provider(name: "Gmail", host: "imap.gmail.com"),
        Provider(name: "iCloud", host: "imap.mail.me.com"),
        Provider(name: "Outlook / Microsoft 365", host: "outlook.office365.com"),
        Provider(name: "Yahoo", host: "imap.mail.yahoo.com"),
        Provider(name: "Fastmail", host: "imap.fastmail.com"),
    ]

    @Test(arguments: providers) func tlsHandshakeAndCapabilities(provider: Provider) async throws {
        let client = IMAPClient(connectTimeout: .seconds(15), readTimeout: .seconds(15))
        defer { Task { await client.logout() } }
        try await client.connect(host: provider.host, port: 993, security: .tls)
        let caps = try await client.preLoginCapabilities()
        #expect(caps.contains("IMAP4REV1"), "\(provider.name): \(caps.sorted())")
        // What Grokbox relies on downstream, per provider — recorded so a
        // change on their side shows up here first.
        let move = caps.contains("MOVE"), uidplus = caps.contains("UIDPLUS"), gmail = caps.contains("X-GM-EXT-1")
        print("HANDSHAKE \(provider.name): MOVE=\(move) UIDPLUS=\(uidplus) X-GM-EXT-1=\(gmail) (\(caps.count) capabilities)")
    }
}
