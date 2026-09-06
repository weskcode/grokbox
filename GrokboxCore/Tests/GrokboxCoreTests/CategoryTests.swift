import Foundation
import Testing
@testable import GrokboxCore

struct SenderCategorizerTests {
    private func cluster(name: String, address: String, subjects: [String], unsub: Bool, contacted: Bool = false, count: Int = 10, unread: Int = 8, flagged: Int = 0) -> SenderCluster {
        SenderCluster(address: address, displayName: name, domain: "", mailbox: "", uids: [], unreadUIDs: [], messageCount: count, unreadCount: unread, flaggedCount: flagged, sweptCount: 0, newest: .now, oldest: .now, hasUnsubscribeLink: unsub, unsubscribeValue: unsub ? "<https://x/u>" : nil, supportsOneClickUnsubscribe: unsub, everContacted: contacted, sampleSubjects: subjects)
    }

    @Test func contactedSenderIsAPerson() {
        let r = SenderCategorizer.categorize(cluster(name: "Alice Adams", address: "alice@x", subjects: ["50% off"], unsub: true, contacted: true))
        #expect(r.category == .person && r.confident)
    }

    @Test func salesLanguageWithUnsubscribeIsPromotion() {
        let r = SenderCategorizer.categorize(cluster(name: "MegaMart", address: "offers@megamart", subjects: ["50% OFF everything — today only!", "FLASH SALE ends at midnight", "Your cart misses you"], unsub: true))
        #expect(r.category == .promotion && r.confident)
    }

    @Test func editorialWithUnsubscribeIsNewsletter() {
        let r = SenderCategorizer.categorize(cluster(name: "Swift Weekly", address: "newsletter@swiftweekly", subjects: ["Issue #412", "Issue #413: concurrency", "Issue #414"], unsub: true))
        #expect(r.category == .newsletter && r.confident)
    }

    @Test func automatedActivityIsNotification() {
        let r = SenderCategorizer.categorize(cluster(name: "TaskFlow", address: "notifications@taskflow", subjects: ["[ACME-1432] Marcus assigned you: Fix login", "[ACME-1401] Status changed to Done", "Weekly digest: 14 updates"], unsub: true))
        #expect(r.category == .notification)
    }

    @Test func receiptsAreTransactional() {
        let r = SenderCategorizer.categorize(cluster(name: "City Power", address: "billing@citypower", subjects: ["Your statement is ready", "Payment due in 5 days", "Autopay confirmation"], unsub: false))
        #expect(r.category == .transactional && r.confident)
    }

    @Test func noReplyReceiptsAreNotNotifications() {
        let r = SenderCategorizer.categorize(cluster(name: "Streamflix", address: "no-reply@streamflix", subjects: ["Your monthly receipt", "Price change notice", "New this month on Streamflix"], unsub: true))
        #expect(r.category != .notification, "an automated address alone must not make a notification")
        #expect(!r.confident, "left for the model")
    }

    @Test func softSellLanguageIsPromotion() {
        #expect(SenderCategorizer.categorize(cluster(name: "GymPro", address: "hello@gympro", subjects: ["New year, new you — 3 months free", "We miss you at the gym", "Bring a friend week"], unsub: true)).category == .promotion)
        #expect(SenderCategorizer.categorize(cluster(name: "CloudDrive Pro", address: "upgrade@clouddrive", subjects: ["You're almost out of storage", "Upgrade and get 2TB", "Your files are at risk"], unsub: true)).category == .promotion)
    }

    @Test func ambiguousStaysUnknownForTheModel() {
        let r = SenderCategorizer.categorize(cluster(name: "hello", address: "hello@x", subjects: ["Hi", "Re:"], unsub: false, count: 80))
        #expect(r.category == .unknown && !r.confident)
    }
}

struct RecommenderTests {
    private func assess(_ c: SenderCluster, _ v: Verdict) -> SenderAssessment { SenderAssessment(cluster: c, verdict: v, score: 0, reasons: []) }
    private func cluster(count: Int, unread: Int, unsub: Bool, contacted: Bool = false, flagged: Int = 0) -> SenderCluster {
        SenderCluster(address: "a@x", displayName: "A", domain: "", mailbox: "", uids: [], unreadUIDs: [], messageCount: count, unreadCount: unread, flaggedCount: flagged, sweptCount: 0, newest: .now, oldest: .now, hasUnsubscribeLink: unsub, unsubscribeValue: nil, supportsOneClickUnsubscribe: false, everContacted: contacted, sampleSubjects: [])
    }

    @Test func neverOpenedPromoGetsUnsubscribe() {
        let r = Recommender.recommend(assess(cluster(count: 87, unread: 87, unsub: true), .bulk), category: .promotion)
        #expect(r.recommendation == .unsubscribeAndSweep)
        #expect(r.reason == "You have never opened any of 87 messages.")
    }

    @Test func newsletterYouReadIsKept() {
        let r = Recommender.recommend(assess(cluster(count: 20, unread: 6, unsub: true), .review), category: .newsletter)
        #expect(r.recommendation == .keep)
        #expect(r.reason.contains("70%"))
    }

    @Test func newsletterYouSkimIsFiled() {
        let r = Recommender.recommend(assess(cluster(count: 20, unread: 14, unsub: true), .review), category: .newsletter)
        #expect(r.recommendation == .fileAutomatically)
    }

    @Test func notificationsAreMuted() {
        #expect(Recommender.recommend(assess(cluster(count: 60, unread: 55, unsub: true), .bulk), category: .notification).recommendation == .muteNotifications)
    }

    @Test func peopleFlagsAndReceiptsAreAlwaysKept() {
        #expect(Recommender.recommend(assess(cluster(count: 5, unread: 5, unsub: true, contacted: true), .bulk), category: .promotion).recommendation == .keep)
        #expect(Recommender.recommend(assess(cluster(count: 50, unread: 50, unsub: true, flagged: 1), .bulk), category: .promotion).recommendation == .keep)
        #expect(Recommender.recommend(assess(cluster(count: 12, unread: 12, unsub: false), .bulk), category: .transactional).recommendation == .keep)
    }

    @Test func planRoutesByCategoryFolder() {
        var promo = cluster(count: 10, unread: 10, unsub: true); promo.category = .promotion; promo.uids = [1, 2]
        var news = cluster(count: 10, unread: 10, unsub: true); news.category = .newsletter; news.address = "n@x"; news.uids = [3]
        let plan = CleanupPlan.suggested(from: [assess(promo, .bulk), assess(news, .bulk)])
        #expect(Set(plan.items.map(\.folder)) == ["Grokbox/Promotions", "Grokbox/Newsletters"])
        #expect(plan.byFolder.first?.folder == "Grokbox/Promotions", "largest folder first")
    }
}
