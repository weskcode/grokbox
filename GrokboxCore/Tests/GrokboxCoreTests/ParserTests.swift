import Foundation
import Testing
@testable import GrokboxCore

struct ParserTests {
    @Test func parsesListLines() throws {
        let mailbox = try #require(IMAPResponseParser.parseListLine("* LIST (\\HasNoChildren \\All) \"/\" \"[Gmail]/All Mail\""))
        #expect(mailbox.name == "[Gmail]/All Mail")
        #expect(mailbox.isAllMail)

        let inbox = try #require(IMAPResponseParser.parseListLine("* LIST (\\HasNoChildren) \"/\" INBOX"))
        #expect(inbox.name == "INBOX")

        #expect(IMAPResponseParser.parseListLine("* LSUB () \"/\" x") == nil)
    }

    @Test func parsesUIDValidityAndLabels() {
        #expect(IMAPResponseParser.parseUIDValidity("* OK [UIDVALIDITY 1725000000] UIDs valid") == 1_725_000_000)
        #expect(IMAPResponseParser.parseUIDValidity("* OK [UIDNEXT 5] x") == nil)

        let labels = IMAPResponseParser.parseGmailLabels(in: "* 1 FETCH (UID 9 X-GM-LABELS (\\Inbox \"Grokbox/Swept\" \"With Space\" \\Important) FLAGS ())")
        #expect(labels == ["\\Inbox", "Grokbox/Swept", "With Space", "\\Important"])
        #expect(IMAPResponseParser.parseGmailLabels(in: "* 1 FETCH (UID 9 FLAGS ())") == nil, "absent when not requested")

        let update = IMAPResponseParser.parseFlagsLine("* 4 FETCH (UID 77 FLAGS (\\Seen \\Flagged) X-GM-LABELS (\"Grokbox/Swept\"))")
        #expect(update?.uid == 77)
        #expect(update?.isUnread == false)
        #expect(update?.isFlagged == true)
        #expect(update?.isInInbox == false, "no \\Inbox label means archived")
    }

    @Test func parsesExistsAndCapability() {
        #expect(IMAPResponseParser.parseExists("* 40213 EXISTS") == 40213)
        #expect(IMAPResponseParser.parseExists("* 0 RECENT") == nil)
        let caps = IMAPResponseParser.parseCapability("* CAPABILITY IMAP4rev1 X-GM-EXT-1 move")
        #expect(caps?.contains("MOVE") == true, "normalised to uppercase")
    }

    @Test func parsesInternalDate() throws {
        let date = try #require(IMAPResponseParser.parseInternalDate("05-Sep-2026 10:00:00 +0000"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        #expect(parts.year == 2026 && parts.month == 9 && parts.day == 5 && parts.hour == 10)
    }

    @Test func decodesRFC2047() {
        #expect(RFC2047.decode("=?UTF-8?B?U2Now7Zu?=") == "Schön")
        #expect(RFC2047.decode("=?UTF-8?Q?50=25_off?=") == "50% off")
        #expect(RFC2047.decode("=?ISO-8859-1?Q?caf=E9?=") == "café")
        #expect(RFC2047.decode("=?UTF-8?B?SGVsbG8=?= =?UTF-8?B?V29ybGQ=?=") == "HelloWorld", "whitespace between encoded-words is dropped")
        #expect(RFC2047.decode("plain subject") == "plain subject")
        #expect(RFC2047.decode("=?broken") == "=?broken", "malformed input passes through")
    }

    @Test func parsesAddresses() {
        let one = AddressParser.first(in: "\"Adams, Alice\" <Alice@Friend.Example>")
        #expect(one.name == "Adams, Alice")
        #expect(one.address == "alice@friend.example", "lowercased")

        let bare = AddressParser.first(in: "billing@utility.example")
        #expect(bare.address == "billing@utility.example")
        #expect(bare.name.isEmpty)

        let many = Set(AddressParser.all(in: "A <a@x.example>, b@y.example; \"C\" <c@z.example>"))
        #expect(many == ["a@x.example", "b@y.example", "c@z.example"])
    }

    @Test func foldsHeaders() {
        let raw = Data("Subject: a very\r\n  long subject\r\nFrom: x@y.example\r\n\r\n".utf8)
        let headers = MIMEHeaders(raw: raw)
        #expect(headers["subject"] == "a very long subject")
        #expect(headers["FROM"] == "x@y.example", "case-insensitive lookup")
        #expect(headers["missing"] == nil)
    }
}

struct BodyExtractorTests {
    @Test func prefersPlainPartOfMultipart() {
        let raw = """
        --boundary42\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><body><p>HTML <b>version</b></p></body></html>\r
        --boundary42\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Plain version with caf=C3=A9 and a soft=\r
         break.\r
        --boundary42--\r
        """
        let text = BodyExtractor.plainText(from: Data(raw.utf8))
        #expect(text.contains("Plain version with café"))
        #expect(text.contains("soft break"))
        #expect(!text.contains("<b>"))
    }

    @Test func stripsHTMLWhenThatIsAllThereIs() {
        let raw = "<html><head><style>p{color:red}</style></head><body><div>Hello&nbsp;there</div><p>Second&amp;last</p></body></html>"
        let text = BodyExtractor.plainText(from: Data(raw.utf8))
        #expect(text == "Hello there\nSecond&last")
    }

    @Test func truncates() {
        let long = String(repeating: "word ", count: 2_000)
        #expect(BodyExtractor.plainText(from: Data(long.utf8), maxCharacters: 100).count == 100)
    }

    /// A MIME entity as `IMAPClient.fetchBodyExcerpt` returns it: header lines,
    /// blank line, body — built from bytes so charsets are real.
    private func entity(_ header: String, _ body: [UInt8]) -> Data {
        Data((header + "\r\n\r\n").utf8) + Data(body)
    }

    @Test func decodesASinglePartInItsDeclaredCharset() {
        // "Grüße" in ISO-8859-1: ü = 0xFC, ß = 0xDF. Read as UTF-8 these are garbage.
        let body: [UInt8] = Array("Gr".utf8) + [0xFC, 0xDF] + Array("e aus Wien".utf8)
        let text = BodyExtractor.plainText(from: entity("Content-Type: text/plain; charset=ISO-8859-1", body))
        #expect(text == "Grüße aus Wien")
    }

    @Test func decodesQuotedPrintableInAWindowsCharset() {
        // windows-1252 0x93/0x94 are curly quotes; 0x80 is the euro sign.
        let text = BodyExtractor.plainText(from: entity(
            "Content-Type: text/plain; charset=\"windows-1252\"\r\nContent-Transfer-Encoding: quoted-printable",
            Array("=93Only =8025=94".utf8)))
        #expect(text == "\u{201C}Only €25\u{201D}")
    }

    @Test func usesTheBoundaryFromTheHeaderAndWalksNestedParts() {
        // The outer boundary line is not the first line (a preamble comes
        // first), and the text lives inside a nested multipart/alternative.
        let raw = """
        This is a multi-part message in MIME format.\r
        --outer\r
        Content-Type: multipart/alternative; boundary="inner"\r
        \r
        --inner\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: base64\r
        \r
        \(Data("Nested café plain".utf8).base64EncodedString())\r
        --inner\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>Nested <b>html</b></p>\r
        --inner--\r
        --outer\r
        Content-Type: application/pdf\r
        Content-Disposition: attachment; filename="bill.pdf"\r
        \r
        JVBERi0xLjQK\r
        --outer--\r
        """
        let parts = BodyExtractor.extract(from: entity("Content-Type: multipart/mixed; boundary=outer", Array(raw.utf8)))
        #expect(parts.plain == "Nested café plain")
        #expect(parts.html?.contains("<b>html</b>") == true)
    }

    @Test func skipsATextAttachmentAheadOfTheBody() {
        let raw = "--b\r\nContent-Type: text/plain\r\nContent-Disposition: attachment; filename=log.txt\r\n\r\nattached log\r\n--b\r\nContent-Type: text/plain\r\n\r\nthe real message\r\n--b--\r\n"
        let text = BodyExtractor.plainText(from: entity("Content-Type: multipart/mixed; boundary=\"b\"", Array(raw.utf8)))
        #expect(text == "the real message")
    }

    @Test func toleratesABase64PartCutOffByTheExcerptLimit() {
        let full = Data("A sentence long enough to be cut part way through.".utf8).base64EncodedString()
        let cut = String(full.prefix(full.count - 3))   // not a multiple of four
        let text = BodyExtractor.plainText(from: entity(
            "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64", Array(cut.utf8)))
        #expect(text.hasPrefix("A sentence long enough"))
    }

    @Test func readsTheCharsetFromAnHTMLMetaTagWhenTheHeaderHasNone() {
        let body: [UInt8] = Array("<html><head><meta charset=\"iso-8859-1\"></head><body><p>Caf".utf8) + [0xE9] + Array("</p></body></html>".utf8)
        let text = BodyExtractor.plainText(from: entity("Content-Type: text/html", body))
        #expect(text == "Café")
    }

    @Test func anEmptyHeaderBlockMeansPlainText() {
        let text = BodyExtractor.plainText(from: Data("\r\nKey: value is body text, not a header".utf8))
        #expect(text == "Key: value is body text, not a header")
    }
}

struct LiteralSectionTests {
    @Test func pairsLiteralsWithTheSectionsTheyBelongTo() {
        // Servers may answer in any order; the names decide, not the position.
        let line = IMAPLine(text: "* 2 FETCH (UID 20 BODY[TEXT]<0> {4} BODY[HEADER.FIELDS (CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] {2})",
                            literals: [Data("body".utf8), Data("\r\n".utf8)])
        let sections = IMAPResponseParser.literalSections(line)
        #expect(sections.map(\.name) == ["BODY[TEXT]<0>", "BODY[HEADER.FIELDS (CONTENT-TYPE CONTENT-TRANSFER-ENCODING)]"])
        #expect(sections.first?.data == Data("body".utf8))
    }

    @Test func aSectionSentAsNILIsSkippedRatherThanShiftingTheRest() {
        let line = IMAPLine(text: "* 2 FETCH (UID 20 BODY[HEADER.FIELDS (CONTENT-TYPE)] NIL BODY[TEXT]<0> {4})",
                            literals: [Data("body".utf8)])
        let sections = IMAPResponseParser.literalSections(line)
        #expect(sections.count == 1)
        #expect(sections.first?.name == "BODY[TEXT]<0>")
    }
}
