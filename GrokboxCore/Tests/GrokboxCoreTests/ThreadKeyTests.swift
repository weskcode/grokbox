import Foundation
import Testing
@testable import GrokboxCore

struct ThreadKeyTests {
    @Test func stripsReplyAndForwardPrefixes() {
        for s in ["Invoice for March", "Re: Invoice for March", "RE: re: Invoice for March", "Fwd: Invoice for March",
                  "[Fwd] Invoice for March", "AW: Invoice for March", "Re[2]: Invoice for March", "  Invoice   for March "] {
            #expect(ThreadKey.normalizedSubject(s) == "invoice for march", Comment(rawValue: s))
        }
    }

    @Test func doesNotOverStrip() {
        #expect(ThreadKey.normalizedSubject("Research update") == "research update")
        #expect(ThreadKey.normalizedSubject("Resume attached") == "resume attached")
        #expect(ThreadKey.normalizedSubject("Fwd") == "fwd")
    }

    @Test func keyIncludesAccountAndSender() {
        let a = UUID(), b = UUID()
        #expect(ThreadKey.key(accountID: a, senderAddress: "X@Example.com", subject: "Re: Hi")
                == ThreadKey.key(accountID: a, senderAddress: "x@example.com", subject: "hi"))
        #expect(ThreadKey.key(accountID: a, senderAddress: "x@example.com", subject: "hi")
                != ThreadKey.key(accountID: b, senderAddress: "x@example.com", subject: "hi"))
    }
}
