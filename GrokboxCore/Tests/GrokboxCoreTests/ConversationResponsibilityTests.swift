import Foundation
import Testing
@testable import GrokboxCore

typealias CR = ConversationResponsibility

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func day(_ n: Double) -> Date { t0.addingTimeInterval(n * 86_400) }

private let me = "me@example.com"
private let priya = "priya@example.com"
private let dana = "dana@example.com"

private func inbound(_ key: String, _ d: Double, from author: String = priya, to addressed: Bool? = true,
                     parent: CR.Parent = .unknown, automation: CR.Automation? = .human,
                     reading: CR.Reading = .read(.needsYou, .reply)) -> CR.Message {
    CR.Message(key: key, date: day(d), author: author, isFromUser: false, isAddressedToUser: addressed,
               parent: parent, automation: automation, reading: reading)
}

private func mine(_ key: String, _ d: Double, parent: CR.Parent = .unknown,
                  automation: CR.Automation? = .human) -> CR.Message {
    CR.Message(key: key, date: day(d), author: me, isFromUser: true, isAddressedToUser: nil,
               parent: parent, automation: automation, reading: .notRead)
}

/// Each message whose parent is left `.unknown` replies to the one before it.
private func chain(_ messages: [CR.Message], identity: CR.IdentitySource? = .headers,
                   coverage: CR.SentCoverage = .since(day(-30))) -> CR.Conversation {
    var linked = messages
    for i in linked.indices where linked[i].parent == .unknown {
        linked[i].parent = i == 0 ? .root : .message(linked[i - 1].key ?? "")
    }
    return CR.Conversation(identity: identity, sentCoverage: coverage, messages: linked)
}

private func permutations<T>(_ items: [T]) -> [[T]] {
    guard items.count > 1 else { return [items] }
    return items.indices.flatMap { i -> [[T]] in
        var rest = items
        let head = rest.remove(at: i)
        return permutations(rest).map { [head] + $0 }
    }
}

/// Derives once, then asserts every arrival order, with a duplicate added, agrees.
private func derive(_ conversation: CR.Conversation, correction: CR.Correction? = nil,
                    sourceLocation: SourceLocation = #_sourceLocation) -> CR.Result? {
    let expected = CR.derive(conversation, correction: correction)
    for order in permutations(conversation.messages) {
        var shuffled = conversation
        shuffled.messages = order
        #expect(CR.derive(shuffled, correction: correction) == expected, "arrival order changed the result",
                sourceLocation: sourceLocation)
        if let first = order.first {
            shuffled.messages.append(first)
            #expect(CR.derive(shuffled, correction: correction) == expected, "a duplicate changed the result",
                    sourceLocation: sourceLocation)
        }
    }
    return expected
}

struct ConversationResponsibilityTests {
    // MARK: Needs reply and waiting

    @Test func unansweredAskNeedsReply() {
        let r = derive(chain([inbound("a", 0)]))
        #expect(r?.state == .needsReply)
        #expect(r?.reason == .asked(author: priya, day(0)))
    }

    @Test func yourReplyMeansWaitingNeverResolved() {
        let r = derive(chain([inbound("a", 0), mine("b", 1)]))
        #expect(r?.state == .waiting)
        #expect(r?.reason == .youReplied(day(1)))
        #expect(r?.lastFromUser == day(1))
    }

    @Test func recipientAcknowledgesYourMessage() {
        let r = derive(chain([mine("a", 0), inbound("b", 1, reading: .read(.worthKnowing, .none))]))
        #expect(r?.state == .waiting)
        #expect(r?.reason == .acknowledged(day(1)))
    }

    @Test func theirAskAfterYourReplyNeedsReply() {
        let r = derive(chain([mine("a", 0), inbound("b", 1)]))
        #expect(r?.state == .needsReply)
        #expect(r?.reason == .asked(author: priya, day(1)))
    }

    @Test func decideCountsAsAReply() {
        #expect(derive(chain([inbound("a", 0, reading: .read(.needsYou, .decide))]))?.state == .needsReply)
    }

    @Test func thanksAfterAnAskKeepsItOpen() {
        let r = derive(chain([inbound("a", 0), inbound("b", 1, reading: .read(.worthKnowing, .none))]))
        #expect(r?.state == .needsReply)
        #expect(r?.followUp == ActionType.none)
    }

    @Test func taskAfterAnOpenAskIsNamed() {
        let r = derive(chain([inbound("a", 0), inbound("b", 1, reading: .read(.needsYou, .pay))]))
        #expect(r?.state == .needsReply)
        #expect(r?.followUp == .pay)
    }

    @Test(arguments: [ActionType.pay, .attend, .review, .none])
    func nonReplyTasksAreUncertain(_ action: ActionType) {
        let r = derive(chain([mine("a", 0), inbound("b", 1, reading: .read(.needsYou, action))]))
        #expect(r?.state == .uncertain)
        #expect(r?.reason == .taskNotReply(action))
    }

    @Test func waitingGoesStaleAfterFourteenDays() {
        #expect(!CR.isWaitingStale(since: day(0), now: day(14)))
        #expect(CR.isWaitingStale(since: day(0), now: day(14.01)))
    }

    // MARK: Automatic mail

    @Test func outOfOfficeAfterYourReplyIsEvidenceOnly() {
        let r = derive(chain([inbound("a", 0), mine("b", 1), inbound("c", 2, automation: .other, reading: .notRead)]))
        #expect(r?.state == .waiting)
        #expect(r?.reason == .youReplied(day(1)))
        #expect(r?.automaticReplies == [day(2)])
    }

    @Test func readReceiptIsEvidenceOnly() {
        let receipt = inbound("c", 2, from: "postmaster@example.com", automation: .other, reading: .notRead)
        let r = derive(chain([mine("a", 0), inbound("b", 1, reading: .read(.worthKnowing, .none)), mine("d", 1.5), receipt]))
        #expect(r?.state == .waiting)
        #expect(r?.reason == .youReplied(day(1.5)))
        #expect(r?.automaticReplies == [day(2)])
    }

    @Test func yourOwnAutoReplyDoesNotAnswerAnAsk() {
        let r = derive(chain([inbound("a", 0), mine("b", 1, automation: .other)]))
        #expect(r?.state == .needsReply)
        #expect(r?.automaticReplies == [day(1)])
    }

    @Test func automatedMailAloneDoesNotStartTracking() {
        #expect(derive(chain([mine("a", 0, automation: .other)])) == nil)
        #expect(derive(chain([inbound("a", 0, automation: .other, reading: .read(.needsYou, .pay))])) == nil)
    }

    @Test func automatedInboundNeedsAnAddresseeFact() {
        let r = derive(chain([inbound("a", 0), mine("b", 1), inbound("c", 2, to: nil, automation: .other, reading: .notRead)]))
        #expect(r?.reason == .missingFact(.addressee))
    }

    @Test func bounceAfterYourReplyIsUncertain() {
        let r = derive(chain([inbound("a", 0), mine("b", 1), inbound("c", 2, automation: .deliveryFailure, reading: .notRead)]))
        #expect(r?.reason == .replyMayNotHaveArrived(day(2)))
    }

    @Test func unclassifiedMessageIsNeverTreatedAsHuman() {
        let r = derive(chain([inbound("a", 0), mine("b", 1), inbound("c", 2, automation: nil, reading: .notRead)]))
        #expect(r?.reason == .missingFact(.automation))
    }

    // MARK: Reader state

    @Test(arguments: [CR.Reading.notRead, .rulesOnly, .modelFailed])
    func replyNotReadByTheModelIsUncertain(_ reading: CR.Reading) {
        let r = derive(chain([mine("a", 0), inbound("b", 1, reading: reading)]))
        #expect(r?.reason == .notReadByModel(key: "b", reading))
    }

    @Test func earlierUnreadMessageIsNamed() {
        let r = derive(chain([mine("a", 0), inbound("b", 1, reading: .rulesOnly),
                              inbound("c", 2, reading: .read(.worthKnowing, .none))]))
        #expect(r?.reason == .notReadByModel(key: "b", .rulesOnly))
    }

    // MARK: Tracking and participants

    @Test func noActionMailYouNeverJoinedIsNotTracked() {
        #expect(derive(chain([inbound("a", 0, reading: .read(.worthKnowing, .none))])) == nil)
    }

    @Test func copiedOnlyIsNotTracked() {
        #expect(derive(chain([inbound("a", 0, to: false)])) == nil)
    }

    @Test func laterCopyKeepsAnEarlierDirectAskTracked() {
        let r = derive(chain([inbound("a", 0), inbound("b", 1, to: false, reading: .read(.worthKnowing, .none))]))
        #expect(r?.state == .needsReply)
    }

    @Test func copiedReplyAfterYoursIsUncertain() {
        let r = derive(chain([mine("a", 0), inbound("b", 1, to: false)]))
        #expect(r?.reason == .copiedOnReply(day(1), .reply))
    }

    @Test func latestTaskIsNamedWhenNothingElseMatches() {
        let r = derive(chain([inbound("a", 0, reading: .read(.needsYou, .pay)), inbound("b", 1, reading: .read(.worthKnowing, .none))]))
        #expect(r?.reason == .unmatched(task: .pay))
    }

    @Test func someoneElseAnsweringIsUncertain() {
        let r = derive(chain([inbound("a", 0), inbound("b", 1, from: dana, reading: .read(.worthKnowing, .none))]))
        #expect(r?.reason == .othersReplied(author: dana, day(1)))
    }

    // MARK: Missing or conflicting facts

    @Test func subjectFallbackIsUncertain() {
        #expect(derive(chain([inbound("a", 0)], identity: .subjectFallback))?.reason == .groupedBySubject)
        #expect(derive(chain([inbound("a", 0)], identity: nil))?.reason == .missingFact(.identitySource))
    }

    @Test func missingFactsAreUncertain() {
        var noKey = mine("b", 1); noKey.key = nil
        #expect(derive(chain([inbound("a", 0), noKey]))?.reason == .missingFact(.key))
        var unknownSender = inbound("a", 0); unknownSender.isFromUser = nil
        #expect(derive(chain([unknownSender]))?.reason == .missingFact(.direction))
        #expect(derive(chain([inbound("a", 0, automation: nil)]))?.reason == .missingFact(.automation))
        var noDirection = inbound("b", 1); noDirection.isFromUser = nil
        #expect(derive(chain([mine("a", 0), noDirection]))?.reason == .missingFact(.direction))
        #expect(derive(chain([mine("a", 0), inbound("b", 1, to: nil)]))?.reason == .missingFact(.addressee))
    }

    @Test func unkeyedMessagesGiveNoOrderDependentEvidence() {
        var you = mine("a", 0); you.key = nil
        var receipt = inbound("b", 0, automation: .other, reading: .notRead); receipt.key = nil
        let r = derive(chain([you, receipt]))
        #expect(r?.reason == .missingFact(.key))
        #expect(r?.automaticReplies == [])
        #expect(r?.lastFromUser == day(0))
    }

    @Test func disagreeingCopiesAreUncertain() {
        var asMine = inbound("a", 0, parent: .root); asMine.isFromUser = true; asMine.author = me
        let asTheirs = inbound("a", 0, parent: .root)
        #expect(derive(CR.Conversation(identity: .headers, sentCoverage: .since(day(-30)), messages: [asMine, asTheirs]))?.reason
                == .conflictingCopies(key: "a"))
        let reply = inbound("a", 0, parent: .root)
        let pay = inbound("a", 0, parent: .root, reading: .read(.needsYou, .pay))
        #expect(derive(CR.Conversation(identity: .headers, sentCoverage: .since(day(-30)), messages: [reply, pay]))?.reason
                == .conflictingCopies(key: "a"))
    }

    @Test func aReadCopyFillsInAnUnreadOne() {
        let unread = inbound("a", 0, parent: .root, reading: .notRead)
        let read = inbound("a", 0, parent: .root)
        let r = derive(CR.Conversation(identity: .headers, sentCoverage: .since(day(-30)), messages: [unread, read]))
        #expect(r?.state == .needsReply)
    }

    @Test func outboundNeedsNoAddresseeFact() {
        #expect(derive(chain([inbound("a", 0), mine("b", 1)]))?.state == .waiting)
    }

    @Test func sentCoverageGaps() {
        #expect(derive(chain([inbound("a", 0)], coverage: .unknown))?.reason == .missingFact(.sentCoverage))
        #expect(derive(chain([inbound("a", 0)], coverage: .since(day(1))))?.reason == .sentNotCheckedBefore(day(1)))
        let askBeforeCoverage = chain([inbound("a", 0), inbound("b", 20, reading: .read(.worthKnowing, .none))],
                                      coverage: .since(day(15)))
        #expect(derive(askBeforeCoverage)?.reason == .sentNotCheckedBefore(day(15)))
    }

    @Test func parentProblemsAreUncertain() {
        #expect(derive(chain([inbound("a", 0), mine("b", 1, parent: .message("elsewhere"))]))?.reason == .orderUnclear)
        let unknownParent = CR.Conversation(identity: .headers, sentCoverage: .since(day(-30)),
                                            messages: [inbound("a", 0, parent: .root), mine("b", 1, parent: .unknown)])
        #expect(derive(unknownParent)?.reason == .orderUnclear)
        #expect(derive(chain([inbound("a", 2, parent: .root), mine("b", 1, parent: .message("a"))]))?.reason == .orderUnclear)
    }

    @Test func equalDatesOrderByKey() {
        let replyFirst = chain([inbound("a", 0), mine("m1", 1), inbound("m2", 1, reading: .read(.worthKnowing, .none))])
        #expect(derive(replyFirst)?.reason == .acknowledged(day(1)))
        let replyKeySortsLater = chain([inbound("a", 0), mine("m2", 1), inbound("m1", 1, reading: .read(.worthKnowing, .none))])
        #expect(derive(replyKeySortsLater)?.reason == .orderUnclear)
    }

    // MARK: Corrections

    private let resolvedAtB = CR.Correction(state: .resolved, anchorKey: "b", anchorDate: day(1))

    @Test func correctionHoldsWithoutNewMail() {
        let r = derive(chain([inbound("a", 0), mine("b", 1)]), correction: resolvedAtB)
        #expect(r?.state == .resolved)
        #expect(r?.reason == .corrected)
    }

    @Test func newHumanMailClearsACorrection() {
        let thanks = derive(chain([inbound("a", 0), mine("b", 1), inbound("c", 2, reading: .read(.worthKnowing, .none))]),
                            correction: resolvedAtB)
        #expect(thanks?.reason == .acknowledged(day(2)))
        let thirdParty = derive(chain([inbound("a", 0), mine("b", 1), inbound("c", 2, from: dana, reading: .read(.worthKnowing, .none))]),
                                correction: resolvedAtB)
        #expect(thirdParty?.reason == .othersReplied(author: dana, day(2)))
    }

    @Test func automaticMailKeepsACorrection() {
        let r = derive(chain([inbound("a", 0), mine("b", 1), inbound("c", 2, automation: .other, reading: .notRead)]),
                       correction: resolvedAtB)
        #expect(r?.state == .resolved)
        #expect(r?.automaticReplies == [day(2)])
    }

    @Test func bounceMasksACorrection() {
        let messages = [inbound("a", 0), mine("b", 1), inbound("c", 2, automation: .deliveryFailure, reading: .notRead)]
        #expect(derive(chain(messages), correction: resolvedAtB)?.reason == .replyMayNotHaveArrived(day(2)))
    }

    @Test func orderConflictMasksThenRestoresACorrection() {
        let conflict = chain([inbound("a", 0), mine("b", 1), inbound("x", 0.5, parent: .message("b"),
                                                                     reading: .read(.worthKnowing, .none))])
        #expect(derive(conflict, correction: resolvedAtB)?.reason == .orderUnclear)
        let fixedBeforeAnchor = chain([inbound("a", 0), inbound("x", 0.5, parent: .message("a"),
                                                                reading: .read(.worthKnowing, .none)),
                                       mine("b", 1, parent: .message("a"))])
        #expect(derive(fixedBeforeAnchor, correction: resolvedAtB)?.state == .resolved)
        let fixedAfterAnchor = chain([inbound("a", 0), mine("b", 1), inbound("x", 3, reading: .read(.worthKnowing, .none))])
        #expect(derive(fixedAfterAnchor, correction: resolvedAtB)?.reason == .acknowledged(day(3)))
    }

    @Test func missingAnchorFallsBackToItsDate() {
        let gone = CR.Correction(state: .resolved, anchorKey: "gone", anchorDate: day(1))
        let sameDay = chain([inbound("a", 0), mine("b", 1)])
        #expect(derive(sameDay, correction: gone)?.state == .resolved)
        let later = chain([inbound("a", 0), mine("b", 2)])
        #expect(derive(later, correction: gone)?.state == .waiting)
    }

    @Test func uncertainIsNotAValidCorrection() {
        let bogus = CR.Correction(state: .uncertain, anchorKey: "b", anchorDate: day(1))
        #expect(derive(chain([inbound("a", 0), mine("b", 1)]), correction: bogus)?.state == .waiting)
    }
}
