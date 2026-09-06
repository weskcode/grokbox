import Foundation

/// Deterministic generator for the demo mailbox. Same seed, same inbox.
enum DemoCorpus {
    struct Sender {
        enum Kind { case human, bill, newsletter, promo, social, shipping }
        var kind: Kind
        var name: String
        var address: String
        var contacted: Bool
        var perMonth: Double
        var readRate: Double
        var unsubscribe: String?
        var oneClick: Bool
        var subjects: [String]
        var bodies: [String]
        /// Which sample mailboxes this sender shows up in. Empty means all.
        var personas: Set<DemoPersona> = []
    }

    static func generate(persona: DemoPersona) -> [String: [DemoMailServer.Message]] {
        var rng = SplitMix(seed: persona.seed)
        let now = Date()
        let days = 120
        var all: [DemoMailServer.Message] = []
        var sent: [DemoMailServer.Message] = []
        var uid: UInt32 = 1000
        var sentUID: UInt32 = 5000

        let cast = (senders + workSenders).filter { $0.personas.isEmpty || $0.personas.contains(persona) }

        for sender in cast {
            // The neglected inbox drowns in bulk and hears from almost nobody.
            let multiplier: Double = switch (persona, sender.kind) {
            case (.neglected, .promo), (.neglected, .social), (.neglected, .newsletter): 2.4
            case (.neglected, .human): 0.25
            case (.neglected, .bill): 0.4
            case (.work, .promo): 0.3
            default: 1.0
            }
            let count = Int(sender.perMonth * multiplier * Double(days) / 30.0 * (0.7 + rng.next() * 0.6))
            for _ in 0..<max(1, count) {
                uid += 1
                let age = rng.next() * Double(days)
                let date = now.addingTimeInterval(-age * 86_400 - rng.next() * 3600 * 8)
                let read = rng.next() < sender.readRate
                var flags: Set<String> = read ? ["\\Seen"] : []
                if sender.kind == .human && rng.next() < 0.08 { flags.insert("\\Flagged") }
                var labels: Set<String> = ["\\Inbox"]
                if sender.kind == .human { labels.insert("\\Important") }
                // A slice of old bulk mail was already archived by hand.
                if sender.kind != .human && age > 60 && rng.next() < 0.3 { labels.remove("\\Inbox") }

                // Subject i goes with body i, so every message reads coherently.
                let pairs = min(sender.subjects.count, sender.bodies.count)
                let pick = Int(rng.next() * Double(pairs)) % pairs
                all.append(DemoMailServer.Message(
                    uid: uid, fromName: sender.name, fromAddress: sender.address, to: persona.username,
                    subject: sender.subjects[pick],
                    date: date,
                    body: sender.bodies[pick],
                    isHTML: sender.kind != .human && rng.next() < 0.6,
                    flags: flags, labels: labels,
                    listUnsubscribe: sender.unsubscribe, oneClick: sender.oneClick
                ))
            }

            if sender.contacted && !(persona == .neglected && rng.next() < 0.5) {
                for _ in 0..<(2 + Int(rng.next() * 5)) {
                    sentUID += 1
                    sent.append(DemoMailServer.Message(
                        uid: sentUID, fromName: "You", fromAddress: persona.username,
                        to: "\(sender.name) <\(sender.address)>", subject: "Re: \(sender.subjects[0])",
                        date: now.addingTimeInterval(-rng.next() * Double(days) * 86_400),
                        body: "Sounds good, thanks!", isHTML: false, flags: ["\\Seen"], labels: ["\\Sent"],
                        listUnsubscribe: nil, oneClick: false
                    ))
                }
            }
        }

        all.sort { $0.uid < $1.uid }
        sent.sort { $0.uid < $1.uid }
        return ["[Gmail]/All Mail": all, "[Gmail]/Sent Mail": sent, "[Gmail]/Trash": []]
    }

    // MARK: - The cast

    static let senders: [Sender] = [
        // People you actually talk to
        Sender(kind: .human, name: "Alice Adams", address: "alice@adamsfamily.example", contacted: true, perMonth: 4, readRate: 0.9, unsubscribe: nil, oneClick: false,
               subjects: ["Lunch Friday?", "Re: that thing we talked about", "Can you send the photos?", "Quick question"],
               bodies: ["Are you free Friday around noon? The place on 5th has a new menu. Let me know by Thursday so I can book.",
                        "Following up on what we discussed. Do you still want to go ahead with it? I need an answer this week.",
                        "Could you send me the photos from the weekend when you get a chance? No rush."]),
        Sender(kind: .human, name: "Ben Okafor", address: "ben.okafor@workmail.example", contacted: true, perMonth: 6, readRate: 0.85, unsubscribe: nil, oneClick: false,
               subjects: ["Invoice for March", "Re: project timeline", "Meeting moved to 3pm", "Contract draft attached"],
               bodies: ["Attached is the invoice for March. Payment is due within 14 days. Let me know if anything looks off.",
                        "Heads up — tomorrow's meeting moved to 3pm. Same room. Can you confirm you can still make it?",
                        "Here is the contract draft. Please review sections 3 and 7 and send back any changes by Monday."]),
        Sender(kind: .human, name: "Mum", address: "mum@family.example", contacted: true, perMonth: 3, readRate: 0.95, unsubscribe: nil, oneClick: false,
               subjects: ["Sunday dinner", "Have you called your grandmother?", "Photos from the garden"],
               bodies: ["Are you coming to Sunday dinner? Your sister is bringing the kids. Let me know what you want me to cook.",
                        "Your grandmother has been asking about you. Give her a call this week, it would mean a lot to her."]),
        Sender(kind: .human, name: "Dr. Patel's Office", address: "reception@patelclinic.example", contacted: false, perMonth: 0.6, readRate: 0.7, unsubscribe: nil, oneClick: false,
               subjects: ["Appointment reminder", "Your test results are available"],
               bodies: ["This is a reminder of your appointment on Tuesday at 10:30am. Please arrive 10 minutes early. Reply CONFIRM or call to reschedule.",
                        "Your recent test results are now available in the patient portal. Dr. Patel would like to discuss them; please book a follow-up."]),
        Sender(kind: .human, name: "Sam Rivera", address: "sam@rivera.example", contacted: true, perMonth: 2, readRate: 0.8, unsubscribe: nil, oneClick: false,
               subjects: ["Weekend plans", "That book you mentioned", "Re: Re: hiking"],
               bodies: ["Still up for the hike Saturday? Forecast looks good. I can drive if you bring snacks.",
                        "Finished the book you recommended — you were right. Want it back or should I pass it on?"]),
        Sender(kind: .human, name: "Jordan Lee", address: "jordan.lee@recruiter.example", contacted: false, perMonth: 1, readRate: 0.5, unsubscribe: nil, oneClick: false,
               subjects: ["Opportunity at a fast-growing startup", "Following up"],
               bodies: ["I came across your profile and think you'd be a great fit for a senior role at my client. Would you be open to a 15-minute call this week?"],
               personas: [.personal, .neglected]),

        // Bills and services
        Sender(kind: .bill, name: "City Power & Light", address: "billing@citypower.example", contacted: false, perMonth: 1, readRate: 0.6, unsubscribe: nil, oneClick: false,
               subjects: ["Your statement is ready", "Payment due in 5 days", "Autopay confirmation"],
               bodies: ["Your electricity statement for last month is ready. Amount due: $142.17. Due date: the 28th. Log in to view or pay.",
                        "Reminder: your payment of $142.17 is due in 5 days. Avoid a late fee by paying before the due date."]),
        Sender(kind: .bill, name: "Northbank", address: "alerts@northbank.example", contacted: false, perMonth: 3, readRate: 0.5, unsubscribe: nil, oneClick: false,
               subjects: ["Large transaction alert", "Your statement is available", "Security: new device sign-in"],
               bodies: ["A transaction of $890.00 was made on your card ending 4417 at ELECTRONICS DEPOT. If this wasn't you, contact us immediately.",
                        "We noticed a sign-in from a new device. If this was you, no action is needed. Otherwise, secure your account now."]),
        Sender(kind: .bill, name: "Streamflix", address: "no-reply@streamflix.example", contacted: false, perMonth: 1, readRate: 0.2, unsubscribe: "<https://streamflix.example/email-prefs>", oneClick: false,
               subjects: ["Your monthly receipt", "Price change notice", "New this month on Streamflix"],
               bodies: ["Thanks for your payment of $15.99. Your next billing date is next month. No action needed.",
                        "Starting next month, your plan will increase from $15.99 to $17.99. You can change your plan anytime in settings."]),
        Sender(kind: .bill, name: "Lease Manager", address: "portal@leasemanager.example", contacted: false, perMonth: 0.8, readRate: 0.7, unsubscribe: nil, oneClick: false,
               subjects: ["Rent receipt", "Lease renewal — action required", "Maintenance visit scheduled"],
               bodies: ["Your lease expires in 60 days. To renew, sign the attached renewal by the 15th or the unit will be listed. Contact the office with questions.",
                        "A maintenance technician will visit on Thursday between 1pm and 4pm to service the HVAC. Please ensure access."]),
        Sender(kind: .shipping, name: "Parcelly", address: "tracking@parcelly.example", contacted: false, perMonth: 4, readRate: 0.4, unsubscribe: nil, oneClick: false,
               subjects: ["Your package has shipped", "Out for delivery today", "Delivered", "Delivery attempted — action needed"],
               bodies: ["Your order #88213 has shipped and will arrive in 2-3 days. Track it using the link in your account.",
                        "We attempted delivery today but nobody was home. Reschedule within 3 days or the package will be returned."]),

        // Newsletters
        Sender(kind: .newsletter, name: "The Morning Digest", address: "hello@morningdigest.example", contacted: false, perMonth: 22, readRate: 0.15, unsubscribe: "<https://morningdigest.example/unsub/abc>, <mailto:unsub@morningdigest.example>", oneClick: true,
               subjects: ["Your Tuesday briefing", "5 stories you missed", "Weekend reads", "The week ahead"],
               bodies: ["Good morning. Here are today's top stories: markets edge higher, a new study on sleep, and what to watch this weekend. Read the full digest online."]),
        Sender(kind: .newsletter, name: "Swift Weekly", address: "newsletter@swiftweekly.example", contacted: false, perMonth: 4, readRate: 0.55, unsubscribe: "<https://swiftweekly.example/unsubscribe?id=9>", oneClick: true,
               subjects: ["Issue #412", "Issue #413: Swift 6.3 concurrency", "Issue #414"],
               bodies: ["This week: a deep dive on actor isolation, three new packages worth a look, and a reader question about SwiftData migrations."]),
        Sender(kind: .newsletter, name: "Recipe of the Day", address: "daily@recipeoftheday.example", contacted: false, perMonth: 30, readRate: 0.05, unsubscribe: "<https://recipeoftheday.example/u/1>", oneClick: true,
               subjects: ["Tonight: 20-minute pasta", "Weekend brunch ideas", "One-pan chicken", "Meal prep Sunday"],
               bodies: ["Tonight's recipe is a 20-minute lemon garlic pasta. You'll need spaghetti, two lemons, garlic, and parmesan. Full recipe on the site."]),
        Sender(kind: .newsletter, name: "Product Hunt Daily", address: "digest@producthunt.example", contacted: false, perMonth: 30, readRate: 0.08, unsubscribe: "<https://producthunt.example/unsubscribe>", oneClick: true,
               subjects: ["Today's top launches", "A new AI notebook is #1", "The best of this week"],
               bodies: ["Today's top products: an AI meeting notetaker, a habit tracker for teams, and a browser that blocks everything. Upvote your favorites."]),
        Sender(kind: .newsletter, name: "Medium Daily Digest", address: "noreply@medium.example", contacted: false, perMonth: 30, readRate: 0.03, unsubscribe: "<https://medium.example/me/email-settings>", oneClick: false,
               subjects: ["Stories for you", "Why I quit my job to write", "10 habits of productive people", "Highlights from your network"],
               bodies: ["Based on your reading history, we think you'll like these stories. Read on Medium."]),
        Sender(kind: .newsletter, name: "Neighborhood Watch", address: "updates@nextdoor.example", contacted: false, perMonth: 15, readRate: 0.1, unsubscribe: "<mailto:unsubscribe@nextdoor.example>", oneClick: false,
               subjects: ["Trending in your neighborhood", "Lost cat near Elm Street", "Garage sale this Saturday"],
               bodies: ["Here's what's trending near you this week. Three new posts in Elm Street, a lost cat, and a garage sale on Saturday."]),

        // Promotions
        Sender(kind: .promo, name: "MegaMart", address: "offers@megamart.example", contacted: false, perMonth: 25, readRate: 0.02, unsubscribe: "<https://megamart.example/unsub?c=7>", oneClick: true,
               subjects: ["50% OFF everything — today only!", "Your cart misses you", "FLASH SALE ends at midnight", "Exclusive member deals inside"],
               bodies: ["Don't miss it! 50% off sitewide for 24 hours only. Use code SAVE50 at checkout. Terms apply. Shop now."]),
        Sender(kind: .promo, name: "SkyJet Airways", address: "deals@skyjet.example", contacted: false, perMonth: 12, readRate: 0.04, unsubscribe: "<https://skyjet.example/email/unsubscribe>", oneClick: true,
               subjects: ["Fares from $49 — book by Sunday", "Your next getaway awaits", "Last chance: sale fares"],
               bodies: ["Fly for less this spring. Fares from $49 one way to select destinations. Book by Sunday. Restrictions apply."]),
        Sender(kind: .promo, name: "GymPro", address: "hello@gympro.example", contacted: false, perMonth: 10, readRate: 0.03, unsubscribe: "<https://gympro.example/unsubscribe>", oneClick: true,
               subjects: ["New year, new you — 3 months free", "We miss you at the gym", "Bring a friend week"],
               bodies: ["Your membership has been inactive for a while. Come back this month and get your first three months at half price."]),
        Sender(kind: .promo, name: "Pixel Prints", address: "promo@pixelprints.example", contacted: false, perMonth: 8, readRate: 0.05, unsubscribe: "<https://pixelprints.example/u>", oneClick: false,
               subjects: ["Turn your photos into canvas — 40% off", "Mother's Day gifts", "Free shipping this weekend"],
               bodies: ["Turn your favorite photos into wall art. 40% off all canvas prints this week. Free shipping on orders over $50."]),
        Sender(kind: .promo, name: "CloudDrive Pro", address: "upgrade@clouddrive.example", contacted: false, perMonth: 6, readRate: 0.06, unsubscribe: "<https://clouddrive.example/unsub>", oneClick: true,
               subjects: ["You're almost out of storage", "Upgrade and get 2TB", "Your files are at risk"],
               bodies: ["You've used 94% of your storage. Upgrade to Pro for 2TB and never worry about space again. Plans from $9.99/month."]),

        // Social notifications
        Sender(kind: .social, name: "LinkedIn", address: "notifications@linkedin.example", contacted: false, perMonth: 20, readRate: 0.05, unsubscribe: "<https://linkedin.example/unsubscribe>", oneClick: true,
               subjects: ["You appeared in 9 searches this week", "Ben Okafor posted: Excited to announce", "3 new connection requests", "Congratulate Sam on the new job"],
               bodies: ["You have new activity on LinkedIn. See who's viewed your profile and what your network is talking about."]),
        Sender(kind: .social, name: "Instagram", address: "no-reply@instagram.example", contacted: false, perMonth: 18, readRate: 0.02, unsubscribe: "<https://instagram.example/emails/unsubscribe>", oneClick: true,
               subjects: ["alice_adams liked your photo", "You have 4 new followers", "See what you've missed"],
               bodies: ["alice_adams and 3 others liked your photo. Open the app to see more."]),
        Sender(kind: .social, name: "Discord", address: "noreply@discord.example", contacted: false, perMonth: 8, readRate: 0.1, unsubscribe: "<https://discord.example/unsubscribe>", oneClick: true,
               subjects: ["You have unread messages in Swift Devs", "New announcement in Indie Hackers"],
               bodies: ["You have 12 unread messages in the Swift Devs server. Jump back in."]),
    ]

    // MARK: - Work-only cast

    static let workSenders: [Sender] = [
        Sender(kind: .human, name: "Priya Nair (CEO)", address: "priya@acme-work.demo", contacted: true, perMonth: 5, readRate: 0.95, unsubscribe: nil, oneClick: false,
               subjects: ["Need your numbers by EOD", "Re: Q3 plan", "Can we talk before the board meeting?", "Great work on the launch"],
               bodies: ["I need the updated forecast numbers by end of day today for the board deck. Just the summary tab is fine.",
                        "Do you have 15 minutes before Thursday's board meeting? I want to align on the hiring ask.",
                        "Just wanted to say the launch went really well. Thank you and the team. No action needed."],
               personas: [.work]),
        Sender(kind: .human, name: "Marcus Chen", address: "marcus.chen@acme-work.demo", contacted: true, perMonth: 12, readRate: 0.8, unsubscribe: nil, oneClick: false,
               subjects: ["PR review?", "Re: flaky test on main", "Standup notes", "Lunch?"],
               bodies: ["Could you review my PR when you have a sec? It's the auth refactor, about 200 lines. Blocking the release branch.",
                        "The integration test on main is flaky again. I think it's the same timing issue. Want to pair on it this afternoon?",
                        "Notes from standup: deploy is Thursday, Sam is out Friday, and we need someone to own the on-call rotation doc."],
               personas: [.work]),
        Sender(kind: .human, name: "Dana Whitfield (HR)", address: "hr@acme-work.demo", contacted: false, perMonth: 2, readRate: 0.7, unsubscribe: nil, oneClick: false,
               subjects: ["Action required: benefits enrollment closes Friday", "Updated remote work policy", "Your performance review is scheduled"],
               bodies: ["Open enrollment for health benefits closes this Friday at 5pm. If you take no action your current plan will roll over. Log in to the HR portal to make changes.",
                        "Your mid-year performance review is scheduled for next Wednesday at 2pm with your manager. Please complete the self-assessment form beforehand."],
               personas: [.work]),
        Sender(kind: .bill, name: "TaskFlow", address: "notifications@taskflow.example", contacted: false, perMonth: 60, readRate: 0.12, unsubscribe: "<https://taskflow.example/notifications/unsubscribe>", oneClick: true,
               subjects: ["[ACME-1432] Marcus Chen assigned you: Fix login redirect", "[ACME-1401] Status changed to Done", "[ACME-1440] New comment from Priya Nair", "Weekly digest: 14 updates in your projects"],
               bodies: ["Marcus Chen assigned you to ACME-1432: Fix login redirect on expired session. Priority: High. Due: Friday.",
                        "ACME-1401 was moved to Done by Sam Rivera. No action needed.",
                        "Priya Nair commented on ACME-1440: 'Can we get this into Thursday's release?'"],
               personas: [.work]),
        Sender(kind: .bill, name: "Calendar", address: "calendar-notification@acme-work.demo", contacted: false, perMonth: 40, readRate: 0.3, unsubscribe: nil, oneClick: false,
               subjects: ["Invitation: Board prep @ Thu 2pm", "Reminder: Standup in 10 minutes", "Updated invitation: 1:1 with Priya", "Accepted: Design review"],
               bodies: ["You have been invited to Board prep on Thursday at 2:00pm. Organizer: Priya Nair. Please respond.",
                        "Reminder: Daily standup starts in 10 minutes."],
               personas: [.work]),
        Sender(kind: .social, name: "Slack", address: "no-reply@slack.example", contacted: false, perMonth: 35, readRate: 0.05, unsubscribe: "<https://slack.example/unsubscribe>", oneClick: true,
               subjects: ["You have 7 unread messages in #engineering", "Marcus mentioned you in #release", "New messages while you were away"],
               bodies: ["While you were away: 7 new messages in #engineering, 2 mentions, 1 direct message from Marcus Chen."],
               personas: [.work]),
        Sender(kind: .newsletter, name: "SaaS Metrics Weekly", address: "hello@saasmetrics.example", contacted: false, perMonth: 4, readRate: 0.2, unsubscribe: "<https://saasmetrics.example/unsub>", oneClick: true,
               subjects: ["Why churn is a leading indicator", "Benchmarks: net revenue retention in 2026"],
               bodies: ["This week we look at churn as a leading indicator and share NRR benchmarks from 400 companies."],
               personas: [.work]),
        Sender(kind: .promo, name: "CloudScale Conf", address: "events@cloudscaleconf.example", contacted: false, perMonth: 8, readRate: 0.05, unsubscribe: "<https://cloudscaleconf.example/unsubscribe>", oneClick: true,
               subjects: ["Early bird ends Friday", "Speaker lineup announced", "Last 50 tickets"],
               bodies: ["Early bird pricing for CloudScale Conf ends Friday. Save $400 on a full pass. Register now."],
               personas: [.work]),
        Sender(kind: .human, name: "Jordan Lee", address: "jordan.lee@recruiter.example", contacted: false, perMonth: 3, readRate: 0.3, unsubscribe: nil, oneClick: false,
               subjects: ["Opportunity: Staff Engineer, remote", "Following up", "Quick question"],
               bodies: ["I came across your profile and think you'd be a great fit for a Staff role at my client. Would you be open to a 15-minute call this week?"],
               personas: [.work]),
    ]
}

/// Tiny deterministic RNG so the demo mailbox is identical every launch.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
