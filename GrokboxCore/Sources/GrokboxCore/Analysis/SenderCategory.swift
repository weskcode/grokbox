import Foundation

/// What kind of sender this is. Drives the folder, the recommendation, and
/// the language the app uses about them.
public enum SenderCategory: String, Codable, Sendable, CaseIterable {
    case person
    case transactional
    case notification
    case newsletter
    case promotion
    case unknown

    public var label: String {
        switch self {
        case .person: "Person"
        case .transactional: "Receipts & records"
        case .notification: "Notifications"
        case .newsletter: "Newsletters"
        case .promotion: "Promotions"
        case .unknown: "Unsorted"
        }
    }

    /// Where swept mail from this kind of sender goes. Gmail label or IMAP folder.
    public var folderName: String {
        switch self {
        case .person: "Grokbox/People"
        case .transactional: "Grokbox/Receipts"
        case .notification: "Grokbox/Notifications"
        case .newsletter: "Grokbox/Newsletters"
        case .promotion: "Grokbox/Promotions"
        case .unknown: "Grokbox/Unsorted"
        }
    }

    public var icon: String {
        switch self {
        case .person: "person"
        case .transactional: "doc.text"
        case .notification: "bell"
        case .newsletter: "newspaper"
        case .promotion: "tag"
        case .unknown: "questionmark.circle"
        }
    }
}

/// Deterministic categorisation from headers and subjects. Explains itself.
/// Anything it cannot place with confidence stays `.unknown` for the model.
public enum SenderCategorizer {
    public struct Result: Sendable, Equatable {
        public var category: SenderCategory
        public var evidence: String
        public var confident: Bool
    }

    static let promoTerms = ["% off", "percent off", "sale", "deal", "deals", "offer", "offers", "discount", "coupon", "promo",
                             "free shipping", "limited time", "last chance", "ends tonight", "ends today", "flash", "save $",
                             "clearance", "exclusive", "early bird", "your cart", "new arrivals", "gift", "book now", "fares from",
                             "months free", "for free", "free trial", "trial", "upgrade", "premium", "unlock", "we miss you",
                             "bring a friend", "membership", "last 50", "tickets", "register now", "don't miss"]
    static let newsletterTerms = ["newsletter", "digest", "issue #", "issue ", "weekly", "daily", "roundup", "round-up", "briefing",
                                  "this week", "stories", "edition", "recap", "top launches", "reads", "what's new", "highlights"]
    static let notificationTerms = ["assigned you", "mentioned you", "commented", "unread messages", "new messages", "reminder:",
                                    "invitation:", "accepted:", "updated invitation", "liked your", "new follower", "new connection",
                                    "appeared in", "status changed", "moved to", "notification", "you have", "activity", "trending"]
    static let notificationAddresses = ["noreply", "no-reply", "notification", "notifications", "alerts", "calendar", "donotreply",
                                        "do-not-reply", "mailer", "bounce", "system", "automated"]

    /// Evidence string for "has an unsubscribe link and nothing else"; the model
    /// pass picks these up alongside `.unknown`.
    public static let unsureBulkEvidence = "Sends with an unsubscribe link"

    public static func categorize(_ cluster: SenderCluster) -> Result {
        let subjects = cluster.sampleSubjects.map { $0.lowercased() }
        let local = cluster.address.split(separator: "@").first.map(String.init)?.lowercased() ?? ""
        func hits(_ terms: [String]) -> Int {
            subjects.filter { subject in terms.contains { term in subject.contains(term) } }.count
        }

        // People first: the strongest signal is that the reader writes back.
        if cluster.everContacted {
            return Result(category: .person, evidence: "You have written to this address", confident: true)
        }

        let transactionalHits = subjects.filter { SweepGuard.looksTransactional($0) }.count
        if transactionalHits >= max(1, subjects.count / 2), !cluster.hasUnsubscribeLink || transactionalHits == subjects.count {
            return Result(category: .transactional, evidence: "Subjects look like receipts, bills, or records", confident: transactionalHits == subjects.count)
        }

        let promo = hits(promoTerms)
        let news = hits(newsletterTerms)
        let notif = hits(notificationTerms)
        let automatedAddress = notificationAddresses.contains { local.contains($0) }

        if cluster.hasUnsubscribeLink {
            // Strongest signal wins; activity-style subjects beat "digest" in a
            // task tracker's weekly summary.
            // An automated address alone is not enough: receipts come from no-reply too.
            let notifScore = notif + (automatedAddress ? 1 : 0)
            if notif > 0, notifScore >= news, notifScore >= promo {
                return Result(category: .notification, evidence: "Automated sender with activity-style subjects", confident: notif >= 2)
            }
            if promo > news, promo > 0 {
                return Result(category: .promotion, evidence: "Unsubscribe link and sales language in \(promo) of \(subjects.count) subjects", confident: promo >= 2)
            }
            if news > 0 {
                return Result(category: .newsletter, evidence: "Unsubscribe link and editorial subjects", confident: news >= 2)
            }
            // Bulk sender we cannot read: newsletter is the safer folder than
            // promotion. Marked with this exact evidence so the model gets asked.
            return Result(category: .newsletter, evidence: Self.unsureBulkEvidence, confident: false)
        }

        if notif >= 2 || (automatedAddress && notif >= 1) {
            return Result(category: .notification, evidence: "Automated address and activity-style subjects", confident: true)
        }
        if automatedAddress {
            return Result(category: .notification, evidence: "Automated address", confident: false)
        }
        if promo >= 2 {
            return Result(category: .promotion, evidence: "Sales language in subjects", confident: false)
        }
        if transactionalHits > 0 {
            return Result(category: .transactional, evidence: "Some subjects look like records", confident: false)
        }

        // A plausible human: a two-word display name that is not a company word.
        let words = cluster.displayName.split(separator: " ")
        let companyWords = ["team", "support", "inc", "ltd", "llc", "co", "news", "daily", "weekly", "app", "shop", "store", "mail"]
        if words.count == 2, words.allSatisfy({ $0.first?.isUppercase == true }), !words.contains(where: { companyWords.contains($0.lowercased()) }),
           cluster.messageCount <= 30 {
            return Result(category: .person, evidence: "Looks like an individual's name; low volume", confident: false)
        }

        return Result(category: .unknown, evidence: "Not enough signal from headers", confident: false)
    }
}

/// The plain-English answer to "what should I do about this sender?"
public enum Recommendation: String, Codable, Sendable, CaseIterable {
    /// Unsubscribe, sweep everything, never see them again.
    case unsubscribeAndSweep
    /// You read these sometimes: keep the subscription, file them automatically.
    case fileAutomatically
    /// Nothing to read; keep out of the inbox by rule.
    case muteNotifications
    /// Leave in the inbox.
    case keep
    /// Mixed signals — look at the messages first.
    case review

    public var label: String {
        switch self {
        case .unsubscribeAndSweep: "Unsubscribe & sweep"
        case .fileAutomatically: "File automatically"
        case .muteNotifications: "Mute"
        case .keep: "Keep"
        case .review: "Review"
        }
    }

    public var verb: String {
        switch self {
        case .unsubscribeAndSweep: "Get rid of it"
        case .fileAutomatically: "Keep, but out of the inbox"
        case .muteNotifications: "Silence it"
        case .keep: "Leave it"
        case .review: "Look first"
        }
    }
}

public enum Recommender {
    public struct Result: Sendable, Equatable {
        public var recommendation: Recommendation
        public var reason: String
    }

    public static func recommend(_ assessment: SenderAssessment, category: SenderCategory) -> Result {
        let c = assessment.cluster
        let unreadPct = Int(c.unreadRatio * 100)
        let never = c.unreadCount == c.messageCount && c.messageCount >= 3

        if category == .person || c.everContacted {
            return Result(recommendation: .keep, reason: c.everContacted ? "You write to them." : "Looks like a person.")
        }
        if c.flaggedCount > 0 {
            return Result(recommendation: .keep, reason: "You flagged \(c.flaggedCount) of their messages.")
        }
        if category == .transactional {
            return Result(recommendation: .keep, reason: "Receipts and records are worth keeping findable.")
        }

        switch category {
        case .promotion:
            if c.hasUnsubscribeLink, c.unreadRatio >= 0.7 {
                return Result(recommendation: .unsubscribeAndSweep,
                              reason: never ? "You have never opened any of \(c.messageCount) messages." : "\(unreadPct)% unopened across \(c.messageCount) messages.")
            }
            if c.unreadRatio < 0.4 {
                return Result(recommendation: .fileAutomatically, reason: "You open these fairly often (\(100 - unreadPct)%).")
            }
            return Result(recommendation: c.hasUnsubscribeLink ? .unsubscribeAndSweep : .fileAutomatically,
                          reason: "\(unreadPct)% unopened.")
        case .newsletter:
            if c.unreadRatio >= 0.85, c.hasUnsubscribeLink {
                return Result(recommendation: .unsubscribeAndSweep, reason: never ? "Never opened, \(c.messageCount) issues." : "\(unreadPct)% of issues unopened.")
            }
            if c.unreadRatio <= 0.5 {
                return Result(recommendation: .keep, reason: "You read about \(100 - unreadPct)% of these.")
            }
            return Result(recommendation: .fileAutomatically, reason: "Read sometimes (\(100 - unreadPct)%); worth keeping, not in the inbox.")
        case .notification:
            return Result(recommendation: .muteNotifications, reason: "Automated updates; \(unreadPct)% unopened.")
        case .unknown:
            if assessment.verdict == .bulk {
                return Result(recommendation: .review, reason: "Looks like bulk mail, but the type is unclear.")
            }
            return Result(recommendation: assessment.verdict == .keep ? .keep : .review, reason: "Not enough signal yet.")
        case .person, .transactional:
            return Result(recommendation: .keep, reason: "")
        }
    }
}
