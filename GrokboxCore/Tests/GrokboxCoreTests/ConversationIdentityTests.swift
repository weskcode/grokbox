import Foundation
import Testing
@testable import GrokboxCore

struct MessageIDListTests {
    @Test func keepsOnlyBracketedIDs() {
        #expect(MessageIDList.parse("<a1@mail.example>") == ["a1@mail.example"])
        #expect(MessageIDList.parse("Your message of 3 May <a1@mail.example> (from Alice)") == ["a1@mail.example"])
        #expect(MessageIDList.parse("<not-an-id> <@nohost> <nolocal@> <a1@mail.example>") == ["a1@mail.example"])
        #expect(MessageIDList.parse(nil) == [])
        #expect(MessageIDList.parse("") == [])
        #expect(MessageIDList.parse("<unterminated@mail.example") == [])
    }

    @Test func foldedAndRepeatedReferencesCompareEqual() {
        let folded = "<root@mail.example> <mid@mail.example>\r\n\t<root@mail.example> <long-\r\n id@mail.example>"
        #expect(MessageIDList.parse(folded) == ["root@mail.example", "mid@mail.example", "long-id@mail.example"])
    }

    @Test func messageIDAcceptsABareTokenOnly() {
        #expect(MessageIDList.messageID("<x@y.example>") == "x@y.example")
        #expect(MessageIDList.messageID("  x@y.example ") == "x@y.example")
        #expect(MessageIDList.messageID("x@y.example extra") == nil)
        #expect(MessageIDList.messageID("@y.example") == nil)
        #expect(MessageIDList.messageID(nil) == nil)
    }

    @Test func overlongReferencesKeepTheRootAndTheNewest() {
        let raw = (0..<80).map { "<r\($0)@mail.example>" }.joined(separator: " ")
        let kept = MessageIDList.references(raw)
        #expect(kept.count == MessageIDList.maxReferences)
        #expect(kept.first == "r0@mail.example")
        #expect(kept.last == "r79@mail.example")
        #expect(!kept.contains("r1@mail.example"))
    }

    @Test func fetchLineCarriesReplyHeaders() throws {
        let block = "From: Bob <bob@else.example>\r\nSubject: Re: Lunch\r\nMessage-ID: <b1@else.example>\r\n"
            + "In-Reply-To: <a1@friend.example>\r\nReferences: <a0@friend.example>\r\n <a1@friend.example>\r\n\r\n"
        let line = IMAPLine(text: "* 1 FETCH (UID 7 FLAGS () BODY[HEADER.FIELDS (FROM SUBJECT MESSAGE-ID IN-REPLY-TO REFERENCES)] {\(block.utf8.count)})",
                            literals: [Data(block.utf8)])
        let header = try #require(IMAPResponseParser.parseFetchLine(line))
        #expect(header.inReplyTo == ["a1@friend.example"])
        #expect(header.references == ["a0@friend.example", "a1@friend.example"])
        #expect(header.messageID == "<b1@else.example>", "the stored Message-ID stays as the server wrote it")
    }

    @Test func fetchLineWithoutReplyHeadersHasNone() throws {
        let block = "From: billing@utility.example\r\nSubject: Your bill is ready\r\n\r\n"
        let line = IMAPLine(text: "* 1 FETCH (UID 8 FLAGS () BODY[HEADER.FIELDS (FROM SUBJECT)] {\(block.utf8.count)})",
                            literals: [Data(block.utf8)])
        let header = try #require(IMAPResponseParser.parseFetchLine(line))
        #expect(header.inReplyTo.isEmpty)
        #expect(header.references.isEmpty)
        #expect(header.messageID == nil)
    }
}

struct ConversationIdentityTests {
    private let account = UUID()

    private func message(_ id: String?, from sender: String, _ subject: String,
                         inReplyTo: [String] = [], references: [String] = [], account: UUID? = nil) -> ConversationIdentity.Input {
        .init(accountID: account ?? self.account, messageID: id, inReplyTo: inReplyTo, references: references,
              senderAddress: sender, subject: subject)
    }

    private func partition(_ assignments: [ConversationIdentity.Assignment]) -> Set<Set<Int>> {
        Set(Dictionary(grouping: assignments.indices, by: { assignments[$0].key }).values.map(Set.init))
    }

    @Test func multiPartyRepliesAndAliasesJoinOneConversation() {
        let mail = [
            message("a0@friend.example", from: "alice@friend.example", "Lunch Friday?"),
            message("b1@else.example", from: "bob@else.example", "Re: Lunch Friday?",
                    inReplyTo: ["a0@friend.example"], references: ["a0@friend.example"]),
            message("me2@work.example", from: "me@work.example", "Re: Lunch Friday?",
                    inReplyTo: ["b1@else.example"], references: ["a0@friend.example", "b1@else.example"]),
            message("me3@home.example", from: "me@home.example", "RE: Lunch Friday?",
                    inReplyTo: ["a0@friend.example"], references: ["a0@friend.example"]),
        ]
        let result = ConversationIdentity.assign(mail)
        #expect(Set(result.map(\.key)).count == 1, "four senders, two of them the user's aliases, one conversation")
        #expect(result.allSatisfy { $0.evidence == .headers })
    }

    @Test func sameSubjectButDifferentReferencesStayApart() {
        let mail = [
            message("i1@billing.example", from: "billing@utility.example", "Re: Invoice",
                    inReplyTo: ["q1@me.example"], references: ["q1@me.example"]),
            message("i2@billing.example", from: "billing@utility.example", "Re: Invoice",
                    inReplyTo: ["q2@me.example"], references: ["q2@me.example"]),
        ]
        let result = ConversationIdentity.assign(mail)
        #expect(result[0].key != result[1].key, "same sender and subject, provably different conversations")
        #expect(result.allSatisfy { $0.evidence == .single })
    }

    @Test func headerlessMailKeepsTheSubjectFallbackAndSaysSo() {
        let mail = [
            message("bill-mar@utility.example", from: "billing@utility.example", "Your bill is ready"),
            message("bill-apr@utility.example", from: "Billing@Utility.example", "Your bill is ready"),
            message("other@shop.example", from: "orders@shop.example", "Your bill is ready"),
            message(nil, from: "billing@utility.example", "Fwd: Your bill is ready"),
        ]
        let result = ConversationIdentity.assign(mail)
        #expect(partition(result) == [[0, 1, 3], [2]], "the existing ThreadKey grouping, unchanged")
        #expect(result[0].evidence == .subjectFallback)
        #expect(result[2].evidence == .single, "a different sender with the same subject is not merged")
        #expect(result[0].key == "subject|" + ThreadKey.key(accountID: account, senderAddress: "billing@utility.example", subject: "Your bill is ready"))
    }

    @Test func forwardsFollowTheirHeadersNotTheirSubject() {
        let mail = [
            message("a0@friend.example", from: "alice@friend.example", "Lunch Friday?"),
            message("f1@carol.example", from: "carol@carol.example", "Fwd: Lunch Friday?"),
            message("f2@dave.example", from: "dave@dave.example", "Fwd: Lunch Friday?", references: ["a0@friend.example"]),
        ]
        let result = ConversationIdentity.assign(mail)
        #expect(partition(result) == [[0, 2], [1]])
        #expect(result[1].evidence == .single)
    }

    @Test func inReplyToAloneChainsThroughMissingReferences() {
        let mail = [
            message("a0@friend.example", from: "alice@friend.example", "Plan"),
            message("b1@else.example", from: "bob@else.example", "Re: Plan", inReplyTo: ["a0@friend.example"]),
            message("c2@else.example", from: "carol@else.example", "Re: Plan", inReplyTo: ["b1@else.example"]),
        ]
        #expect(partition(ConversationIdentity.assign(mail)) == [[0, 1, 2]])
    }

    @Test func siblingsLinkThroughAnAncestorThatIsNotIndexed() {
        let mail = [
            message("b1@else.example", from: "bob@else.example", "Re: Plan", references: ["gone@friend.example"]),
            message("c1@else.example", from: "carol@else.example", "Re: Plan", references: ["gone@friend.example"]),
        ]
        let result = ConversationIdentity.assign(mail)
        #expect(partition(result) == [[0, 1]])
        #expect(result.allSatisfy { $0.evidence == .headers })
    }

    @Test func aReplyNeverJoinsAHeaderlessGuessOrTheReverse() {
        let mail = [
            message("a0@friend.example", from: "alice@friend.example", "Plan"),
            message("a1@friend.example", from: "alice@friend.example", "Re: Plan", references: ["a0@friend.example"]),
            message("x9@friend.example", from: "alice@friend.example", "Plan"),
        ]
        let result = ConversationIdentity.assign(mail)
        #expect(partition(result) == [[0, 1], [2]])
        #expect(result[2].evidence == .single)
    }

    @Test func duplicatesAndOrderDoNotChangeTheGrouping() {
        let mail = [
            message("a0@friend.example", from: "alice@friend.example", "Plan"),
            message("b1@else.example", from: "bob@else.example", "Re: Plan", references: ["a0@friend.example"]),
            message("n1@news.example", from: "news@news.example", "Weekly"),
            message("n2@news.example", from: "news@news.example", "Weekly"),
            message("c1@else.example", from: "carol@else.example", "Re: Other", references: ["z0@else.example"]),
        ]
        let expected = ConversationIdentity.assign(mail)

        var orders: [[Int]] = [[]]
        for i in mail.indices { orders = orders.flatMap { o in (0...o.count).map { var n = o; n.insert(i, at: $0); return n } } }
        for order in orders {
            let shuffled = ConversationIdentity.assign(order.map { mail[$0] })
            for (position, original) in order.enumerated() {
                #expect(shuffled[position] == expected[original], "order \(order)")
            }
        }

        let doubled = ConversationIdentity.assign(mail + [mail[1], mail[3]])
        #expect(Array(doubled.prefix(mail.count)) == expected, "a second copy of a message changes nothing for the first")
        #expect(doubled[5] == expected[1])
        #expect(doubled[6] == expected[3])
    }

    @Test func copiesOfOneMessageCountOnce() {
        let n1 = message("n1@news.example", from: "news@news.example", "Weekly")
        let n2 = message("n2@news.example", from: "news@news.example", "Weekly")
        let alone = ConversationIdentity.assign([n1, n1])
        #expect(alone[0] == alone[1])
        #expect(alone[0].evidence == .single, "two copies of one message are not a conversation")

        let withCopy = ConversationIdentity.assign([n1, n2, n1])
        #expect(Set(withCopy.map(\.key)).count == 1)
        #expect(withCopy.allSatisfy { $0.evidence == .subjectFallback }, "a copy must not pull its original out of the fallback group")
    }

    @Test func accountsNeverShareAConversation() {
        let other = UUID()
        let mail = [
            message("a0@friend.example", from: "alice@friend.example", "Plan"),
            message("b1@else.example", from: "bob@else.example", "Re: Plan", references: ["a0@friend.example"], account: other),
            message("n1@news.example", from: "news@news.example", "Weekly"),
            message("n2@news.example", from: "news@news.example", "Weekly", account: other),
        ]
        let result = ConversationIdentity.assign(mail)
        #expect(Set(result.map(\.key)).count == 4)
    }

    @Test func renumberedAndSentCopiesResolveTheSameWay() throws {
        func fetched(uid: UInt32, _ block: String) throws -> FetchedHeader {
            let line = IMAPLine(text: "* 1 FETCH (UID \(uid) FLAGS () BODY[HEADER.FIELDS (FROM SUBJECT MESSAGE-ID IN-REPLY-TO REFERENCES)] {\(block.utf8.count)})",
                                literals: [Data(block.utf8)])
            return try #require(IMAPResponseParser.parseFetchLine(line))
        }
        let inbound = "From: alice@friend.example\r\nSubject: Lunch Friday?\r\nMessage-ID: <a0@friend.example>\r\n\r\n"
        let sentReply = "From: me@work.example\r\nSubject: Re: Lunch Friday?\r\nMessage-ID: <me1@work.example>\r\n"
            + "In-Reply-To: <a0@friend.example>\r\nReferences: <a0@friend.example>\r\n\r\n"

        let before = ConversationIdentity.assign([
            .init(accountID: account, header: try fetched(uid: 40, inbound)),
            .init(accountID: account, header: try fetched(uid: 500, sentReply)),
        ])
        let afterRenumber = ConversationIdentity.assign([
            .init(accountID: account, header: try fetched(uid: 3, inbound)),
            .init(accountID: account, header: try fetched(uid: 1, sentReply)),
        ])
        #expect(before == afterRenumber, "UIDVALIDITY changes UIDs, not Message-IDs")
        #expect(before[0].key == before[1].key, "the user's Sent reply joins the inbound conversation")
        #expect(before[0].evidence == .headers)
    }

    @Test func mailWithNoIDsAtAllFallsBackPerSenderAndSubject() {
        let mail = [
            message(nil, from: "alice@friend.example", "Plan"),
            message(nil, from: "alice@friend.example", "Re: Plan"),
            message(nil, from: "alice@friend.example", "Something else"),
        ]
        let result = ConversationIdentity.assign(mail)
        #expect(partition(result) == [[0, 1], [2]])
        #expect(result[0].evidence == .subjectFallback)
        #expect(result[2].evidence == .single)
    }
}
