import Foundation
import Testing
@testable import GrokboxCore

struct DueDateParserTests {
    // Anchor: Wednesday 2 Sep 2026, 10:00 local
    private var anchor: Date {
        var parts = DateComponents(); parts.year = 2026; parts.month = 9; parts.day = 2; parts.hour = 10
        return Calendar.current.date(from: parts)!
    }
    private func day(_ date: Date?) -> Int? { date.map { Calendar.current.component(.day, from: $0) } }

    @Test func relativePhrases() {
        #expect(day(DueDateParser.parse("today", relativeTo: anchor)) == 2)
        #expect(day(DueDateParser.parse("EOD", relativeTo: anchor)) == 2)
        #expect(day(DueDateParser.parse("tomorrow", relativeTo: anchor)) == 3)
        #expect(day(DueDateParser.parse("in 5 days", relativeTo: anchor)) == 7)
        #expect(day(DueDateParser.parse("within 14 days", relativeTo: anchor)) == 16)
        #expect(day(DueDateParser.parse("in 2 weeks", relativeTo: anchor)) == 16)
        #expect(day(DueDateParser.parse("next week", relativeTo: anchor)) == 9)
    }

    @Test func weekdays() {
        #expect(day(DueDateParser.parse("by Friday", relativeTo: anchor)) == 4)
        #expect(day(DueDateParser.parse("Thursday", relativeTo: anchor)) == 3)
        #expect(day(DueDateParser.parse("by Wednesday", relativeTo: anchor)) == 9, "same weekday means next week")
        #expect(day(DueDateParser.parse("next Monday", relativeTo: anchor)) == 14)
        #expect(day(DueDateParser.parse("end of week", relativeTo: anchor)) == 4)
    }

    @Test func ordinalsAndMonths() {
        #expect(day(DueDateParser.parse("the 28th", relativeTo: anchor)) == 28)
        let month = DueDateParser.parse("the 1st", relativeTo: anchor).map { Calendar.current.component(.month, from: $0) }
        #expect(month == 10, "a day already passed rolls to next month")
        #expect(day(DueDateParser.parse("Sep 12", relativeTo: anchor)) == 12)
        #expect(day(DueDateParser.parse("15 October", relativeTo: anchor)) == 15)
    }

    @Test func refusesToGuess() {
        #expect(DueDateParser.parse(nil, relativeTo: anchor) == nil)
        #expect(DueDateParser.parse("", relativeTo: anchor) == nil)
        #expect(DueDateParser.parse("soon", relativeTo: anchor) == nil)
        #expect(DueDateParser.parse("when you get a chance", relativeTo: anchor) == nil)
    }
}

struct PriorityScorerTests {
    private let now = Date()

    @Test func billDueSoonOutranksCasualReply() {
        let bill = PriorityScorer.score(.init(importance: .needsYou, actionType: .pay,
                                              dueAt: Calendar.current.date(byAdding: .day, value: 2, to: now), receivedAt: now, now: now))
        let lunch = PriorityScorer.score(.init(importance: .needsYou, actionType: .reply, receivedAt: now, timesContacted: 5, now: now))
        #expect(bill.score > lunch.score)
        #expect(bill.dueLabel == "Due in 2 days")
        #expect(bill.reasons.contains("money"))
    }

    @Test func overdueIsNamed() {
        let late = PriorityScorer.score(.init(importance: .needsYou, dueAt: Calendar.current.date(byAdding: .day, value: -2, to: now), receivedAt: now, now: now))
        #expect(late.isOverdue)
        #expect(late.dueLabel == "Overdue")
    }

    @Test func flaggedAndKnownContactsRise() {
        let plain = PriorityScorer.score(.init(importance: .worthKnowing, receivedAt: now, now: now))
        let flagged = PriorityScorer.score(.init(importance: .worthKnowing, receivedAt: now, isFlagged: true, now: now))
        let friend = PriorityScorer.score(.init(importance: .worthKnowing, receivedAt: now, timesContacted: 4, now: now))
        #expect(flagged.score > plain.score)
        #expect(friend.score > plain.score)
        #expect(friend.reasons.contains("someone you talk to often"))
    }

    @Test func unansweredMailAgesUpButCaps() {
        let fresh = PriorityScorer.score(.init(importance: .needsYou, receivedAt: now, now: now))
        let week = PriorityScorer.score(.init(importance: .needsYou, receivedAt: Calendar.current.date(byAdding: .day, value: -8, to: now)!, now: now))
        let month = PriorityScorer.score(.init(importance: .needsYou, receivedAt: Calendar.current.date(byAdding: .day, value: -40, to: now)!, now: now))
        #expect(week.score > fresh.score)
        #expect(month.score == week.score, "age pressure is capped")
    }

    @Test func noiseScoresNothing() {
        #expect(PriorityScorer.score(.init(importance: .noise, receivedAt: now, now: now)).score == 0)
    }
}

struct SweepGuardTests {
    private func fact(_ uid: UInt32, _ subject: String, flagged: Bool = false, importance: Importance? = nil) -> SweepGuard.MessageFacts {
        .init(uid: uid, subject: subject, isFlagged: flagged, importance: importance)
    }

    @Test func holdsFlaggedNeedsYouAndTransactional() {
        let verdict = SweepGuard.check([
            fact(1, "50% off everything"),
            fact(2, "Weekend reads", flagged: true),
            fact(3, "Your cart misses you", importance: .needsYou),
            fact(4, "Your order #88213 has shipped"),
            fact(5, "Your receipt from MegaMart"),
            fact(6, "Security: new device sign-in"),
            fact(7, "Flash sale ends tonight", importance: .noise),
        ], keepTransactional: true)
        #expect(verdict.allowed == [1, 7])
        #expect(verdict.held.map(\.uid) == [2, 3, 4, 5, 6])
        #expect(verdict.summary == "Held 5: 3 look transactional, 1 flagged, 1 need you")
    }

    @Test func transactionalGuardCanBeTurnedOff() {
        let verdict = SweepGuard.check([fact(4, "Your order #88213 has shipped")], keepTransactional: false)
        #expect(verdict.allowed == [4])
        #expect(verdict.summary == nil)
    }

    @Test func wholeWordMatching() {
        #expect(SweepGuard.looksTransactional("Your ticket to CloudScale Conf"))
        #expect(!SweepGuard.looksTransactional("Sticket sale"), "no substring matches inside words")
        #expect(SweepGuard.looksTransactional("Appointment reminder"))
        #expect(!SweepGuard.looksTransactional("5 stories you missed"))
    }
}
