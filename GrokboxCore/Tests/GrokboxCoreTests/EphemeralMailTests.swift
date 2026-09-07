import Foundation
import Testing
@testable import GrokboxCore

struct EphemeralMailTests {
    @Test func recognisesTheUsualShapes() {
        #expect(EphemeralMail.kind(subject: "830324 is your X verification code") == .oneTimeCode)
        #expect(EphemeralMail.kind(subject: "Your one-time passcode") == .oneTimeCode)
        #expect(EphemeralMail.kind(subject: "Reset your Coddy password") == .resetLink)
        #expect(EphemeralMail.kind(subject: "Confirm your email address") == .resetLink)
        #expect(EphemeralMail.kind(subject: "Security alert") == .securityAlert)
        #expect(EphemeralMail.kind(subject: "Your parcel is out for delivery") == .timedEvent)
    }

    @Test func leavesOrdinaryMailAlone() {
        for subject in ["Invoice for March", "Re: Q3 plan", "Your monthly statement",
                        "Weekly digest: 14 updates", "Dinner on Sunday?"] {
            #expect(EphemeralMail.kind(subject: subject) == nil, Comment(rawValue: subject))
        }
    }

    /// A reset mail usually quotes a code too; the reset is the better label.
    @Test func resetBeatsCodeWhenBothAppear() {
        #expect(EphemeralMail.kind(subject: "Reset your password", summary: "Use code 1234") == .resetLink)
    }

    @Test func expiryDependsOnAgeAndKind() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ daysAgo: Int) -> Date { Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)! }

        #expect(EphemeralMail.hasExpired(subject: "Your verification code", receivedAt: at(0), now: now) == nil, "today's code still counts")
        #expect(EphemeralMail.hasExpired(subject: "Your verification code", receivedAt: at(3), now: now) == .oneTimeCode)
        #expect(EphemeralMail.hasExpired(subject: "Security alert", receivedAt: at(3), now: now) == nil, "alerts stay relevant longer")
        #expect(EphemeralMail.hasExpired(subject: "Security alert", receivedAt: at(30), now: now) == .securityAlert)
        #expect(EphemeralMail.hasExpired(subject: "Invoice for March", receivedAt: at(90), now: now) == nil, "ordinary mail never expires")
    }
}

struct PriorityDecayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ daysAgo: Int) -> Date { Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)! }

    /// The bug this fixes, found on a real mailbox: a three-month-old
    /// verification code was the top item in the Brief, above a live question
    /// from a colleague.
    @Test func anOldCodeDoesNotOutrankRealMail() {
        let staleCode = PriorityScorer.score(.init(
            importance: .needsYou, actionType: .reply, receivedAt: at(90), isUnread: true,
            isQuick: true, timesContacted: 0, now: now,
            subject: "830324 is your X verification code", summary: "X sends verification code 830324."))

        let realQuestion = PriorityScorer.score(.init(
            importance: .needsYou, actionType: .reply, receivedAt: at(2), isUnread: true,
            isQuick: false, timesContacted: 4, now: now,
            subject: "Re: the contract", summary: "Asks whether you want to proceed."))

        #expect(staleCode.score < realQuestion.score, "stale \(staleCode.score) vs real \(realQuestion.score)")
        #expect(staleCode.reasons == ["a code that has long since expired"], "and it says why, plainly")
        #expect(staleCode.dueLabel == nil, "an expired code has no deadline worth showing")
    }

    /// A code that arrived this morning is exactly what someone needs.
    @Test func aFreshCodeIsStillUrgent() {
        let fresh = PriorityScorer.score(.init(
            importance: .needsYou, actionType: .reply, receivedAt: now, isUnread: true, isQuick: true,
            now: now, subject: "Your login code is 123456"))
        #expect(fresh.score > 50)
        #expect(!fresh.reasons.contains("a code that has long since expired"))
    }

    /// Ageing still makes ordinary unanswered mail more pressing.
    @Test func ordinaryMailStillGetsHeavierWithAge() {
        func score(_ daysAgo: Int) -> Int {
            PriorityScorer.score(.init(importance: .needsYou, actionType: .reply, receivedAt: at(daysAgo),
                                       isUnread: true, now: now, subject: "Re: the contract")).score
        }
        #expect(score(10) > score(1))
    }
}
