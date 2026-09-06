import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

struct PublicHostPolicyTests {
    private func refusal(_ s: String) -> PublicHostPolicy.Refusal? { PublicHostPolicy.check(URL(string: s)!) }

    @Test func publicHTTPSIsAllowed() {
        #expect(refusal("https://news.example.com/unsub?u=1") == nil)
        #expect(refusal("https://8.8.8.8/x") == nil)
        #expect(refusal("https://[2606:4700::1111]/x") == nil)
    }

    @Test func plainHTTPIsRefused() {
        #expect(refusal("http://news.example.com/unsub") == .notHTTPS)
    }

    @Test func loopbackIsRefused() {
        #expect(refusal("https://127.0.0.1/admin") == .loopback)
        #expect(refusal("https://127.8.9.10/") == .loopback)
        #expect(refusal("https://localhost/") == .loopback)
        #expect(refusal("https://[::1]/") == .loopback)
        #expect(refusal("https://[::ffff:127.0.0.1]/") == .loopback)
    }

    @Test func privateNetworksAreRefused() {
        for host in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0"] {
            #expect(refusal("https://\(host)/") == .privateNetwork, Comment(rawValue: host))
        }
        #expect(refusal("https://172.32.0.1/") == nil, "172.32/12 is public")
        #expect(refusal("https://[fd00::1]/") == .privateNetwork)
        #expect(refusal("https://[fe80::1]/") == .privateNetwork)
        #expect(refusal("https://router.local/") == .loopback)
    }

    /// A sender pointing the one-click POST at the LAN is handed to the browser
    /// instead, and no request is made.
    @Test func serviceRefusesToPostToPrivateAddresses() async {
        var cluster = SenderCluster(address: "x@example.com", displayName: "x", domain: "example.com", mailbox: "INBOX",
                                    uids: [], unreadUIDs: [], messageCount: 1, unreadCount: 1, flaggedCount: 0, sweptCount: 0,
                                    newest: .now, oldest: .now, hasUnsubscribeLink: true,
                                    unsubscribeValue: "<https://192.168.1.1/admin/reboot>", supportsOneClickUnsubscribe: true,
                                    everContacted: false, sampleSubjects: [])
        let outcome = await UnsubscribeService.unsubscribe(from: cluster)
        #expect(outcome == .openInBrowser(URL(string: "https://192.168.1.1/admin/reboot")!))
        cluster.unsubscribeValue = "<https://[::1]/x>"
        #expect(await UnsubscribeService.unsubscribe(from: cluster) == .openInBrowser(URL(string: "https://[::1]/x")!))
    }
}

/// A public-looking first hop that redirects to the LAN must not be followed.
@Suite(.serialized)
struct UnsubscribeRedirectTests {
    @Test func redirectToLoopbackIsNotFollowed() async throws {
        let trap = try FakeHTTPServer { _ in (200, "you should never see this") }
        try await trap.start(); defer { trap.stop() }
        let first = try FakeHTTPServer { _ in (302, "") }   // redirect target set below
        try await first.start(); defer { first.stop() }
        first.redirectLocation = "http://127.0.0.1:\(trap.port)/trap"

        let url = URL(string: "http://127.0.0.1:\(first.port)/unsub")!
        let outcome = await UnsubscribeService.performOneClick(to: url, allowingLoopbackForTests: true)
        #expect(outcome == .openInBrowser(url), "3xx not followed → not a success")
        #expect(trap.recorded.isEmpty, "the redirect target was never contacted")
        #expect(first.recorded.count == 1)
    }
}

@MainActor
struct DataExportTests {
    @Test func roundTripsRulesActionsAndDigests() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let account = MailAccount(displayName: "Me", username: "me@example.com", host: "imap.example.com", port: 993, kind: .generic, security: .tls)
        context.insert(account)
        context.insert(SenderRule(address: "deals@shop.example", decision: .sweep))
        context.insert(CleanupAction(accountID: account.id, kind: .archive, senderAddress: "deals@shop.example", senderName: "Shop",
                                     mailbox: "[Gmail]/All Mail", uids: [1, 2, 3], isUndoable: true, uidValidity: 7))
        let digest = InboxDigest(scopeKey: "all", scopeLabel: "All accounts")
        digest.headline = "Quiet day"; digest.narrative = "Nothing urgent."
        context.insert(digest)
        try context.save()

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let doc = try DataExport.document(from: context, now: now)
        let data = try DataExport.encode(doc)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("password"), "no secrets in an export")
        #expect(text.contains("deals@shop.example"))

        // ISO 8601 carries whole seconds; compare fields, not sub-second dates.
        let back = try DataExport.decode(data)
        #expect(back.rules == doc.rules.map { var r = $0; r.createdAt = Date(timeIntervalSince1970: r.createdAt.timeIntervalSince1970.rounded()); return r }
                    || back.rules.map(\.address) == doc.rules.map(\.address))
        #expect(back.accounts.map(\.username) == ["me@example.com"])
        #expect(back.digests.map(\.headline) == ["Quiet day"])
        #expect(back.accounts.count == 1 && back.rules.count == 1 && back.actions.count == 1 && back.digests.count == 1)
        #expect(back.actions[0].uids == [1, 2, 3])
    }

    @Test func importingRulesIntoAFreshStoreIsIdempotent() throws {
        let source = ModelContainer.grokboxTestContainer()
        source.mainContext.insert(SenderRule(address: "a@x.example", decision: .keep))
        source.mainContext.insert(SenderRule(address: "b@x.example", decision: .sweep))
        try source.mainContext.save()
        let doc = try DataExport.document(from: source.mainContext)

        let target = ModelContainer.grokboxTestContainer()
        #expect(try DataExport.importRules(from: doc, into: target.mainContext) == 2)
        #expect(try DataExport.importRules(from: doc, into: target.mainContext) == 2)
        #expect(try target.mainContext.fetchCount(FetchDescriptor<SenderRule>()) == 2, "no duplicates on re-import")
    }
}
