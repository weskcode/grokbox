import Foundation
import Testing
@testable import GrokboxCore

struct AutoconfigParsingTests {
    /// The real ISPDB entry for gmail.com, as fetched during the landscape study.
    static let gmailXML = """
    <clientConfig version="1.1">
      <emailProvider id="googlemail.com">
        <domain>gmail.com</domain><domain>googlemail.com</domain>
        <displayName>Google Mail</displayName>
        <displayShortName>GMail</displayShortName>
        <incomingServer type="imap">
          <hostname>imap.gmail.com</hostname><port>993</port><socketType>SSL</socketType>
          <username>%EMAILADDRESS%</username>
          <authentication>OAuth2</authentication><authentication>password-cleartext</authentication>
        </incomingServer>
        <incomingServer type="pop3">
          <hostname>pop.gmail.com</hostname><port>995</port><socketType>SSL</socketType>
          <username>%EMAILADDRESS%</username><authentication>OAuth2</authentication>
        </incomingServer>
        <outgoingServer type="smtp"><hostname>smtp.gmail.com</hostname><port>465</port><socketType>SSL</socketType></outgoingServer>
      </emailProvider>
    </clientConfig>
    """

    @Test func parsesTheRealGmailEntry() throws {
        let result = AutoconfigService.parse(xml: Data(Self.gmailXML.utf8), email: "someone@gmail.com", source: "test")
        let found = try result.get()
        #expect(found.host == "imap.gmail.com")
        #expect(found.port == 993)
        #expect(found.security == .tls)
        #expect(found.username == "someone@gmail.com", "%EMAILADDRESS% resolved")
        #expect(found.offersOAuth2 && found.offersPassword)
        #expect(found.providerName == "Google Mail")
    }

    @Test func resolvesLocalPartPlaceholderAndSkipsPOP() throws {
        let xml = """
        <clientConfig version="1.1"><emailProvider id="x"><displayName>X</displayName>
          <incomingServer type="pop3"><hostname>pop.x.example</hostname><port>995</port><socketType>SSL</socketType></incomingServer>
          <incomingServer type="imap"><hostname>mail.x.example</hostname><port>993</port><socketType>SSL</socketType>
            <username>%EMAILLOCALPART%</username><authentication>password-cleartext</authentication></incomingServer>
        </emailProvider></clientConfig>
        """
        let found = try AutoconfigService.parse(xml: Data(xml.utf8), email: "wes@x.example", source: "t").get()
        #expect(found.host == "mail.x.example")
        #expect(found.username == "wes")
        #expect(!found.offersOAuth2)
    }

    @Test func starttlsOnlyIsReportedNotSilentlyDowngraded() {
        let xml = """
        <clientConfig version="1.1"><emailProvider id="x">
          <incomingServer type="imap"><hostname>imap.x.example</hostname><port>143</port><socketType>STARTTLS</socketType></incomingServer>
        </emailProvider></clientConfig>
        """
        let result = AutoconfigService.parse(xml: Data(xml.utf8), email: "a@x.example", source: "t")
        guard case .failure(let failure) = result else { Issue.record("should fail"); return }
        #expect(failure == .onlySTARTTLS(host: "imap.x.example"))
    }

    @Test func prefersSSLEntryWhenBothOffered() throws {
        let xml = """
        <clientConfig version="1.1"><emailProvider id="x">
          <incomingServer type="imap"><hostname>imap.x.example</hostname><port>143</port><socketType>STARTTLS</socketType></incomingServer>
          <incomingServer type="imap"><hostname>imap.x.example</hostname><port>993</port><socketType>SSL</socketType></incomingServer>
        </emailProvider></clientConfig>
        """
        let found = try AutoconfigService.parse(xml: Data(xml.utf8), email: "a@x.example", source: "t").get()
        #expect(found.port == 993 && found.security == .tls)
    }

    @Test func plainIsNeverAccepted() {
        let xml = """
        <clientConfig version="1.1"><emailProvider id="x">
          <incomingServer type="imap"><hostname>imap.x.example</hostname><port>143</port><socketType>plain</socketType></incomingServer>
        </emailProvider></clientConfig>
        """
        guard case .failure = AutoconfigService.parse(xml: Data(xml.utf8), email: "a@x.example", source: "t") else { Issue.record("plain must be refused"); return }
    }

    @Test func rejectsMalformedAddresses() async {
        await #expect(throws: AutoconfigService.Failure.invalidAddress) { try await AutoconfigService.discover(email: "not-an-address", verifyGuess: false) }
        await #expect(throws: AutoconfigService.Failure.invalidAddress) { try await AutoconfigService.discover(email: "@x.example", verifyGuess: false) }
    }
}

@Suite(.serialized)
struct AutoconfigDiscoveryTests {
    @Test func discoversThroughTheISPDBSendingOnlyTheDomain() async throws {
        let server = try FakeHTTPServer { request in
            if request.hasPrefix("GET /v1.1/example.org") { return (200, AutoconfigParsingTests.gmailXML.replacingOccurrences(of: "imap.gmail.com", with: "imap.example.org")) }
            return (404, "")
        }
        try await server.start()
        defer { server.stop() }

        let endpoints = AutoconfigService.Endpoints(
            ispdbBase: URL(string: "http://127.0.0.1:\(server.port)/v1.1/")!,
            providerTemplate: "http://127.0.0.1:\(server.port)/provider/%DOMAIN%/config-v1.1.xml"
        )

        let found = try await AutoconfigService.discover(email: "Wes.Personal@Example.org", endpoints: endpoints, verifyGuess: false)
        #expect(found.host == "imap.example.org")
        #expect(found.source == "Mozilla ISPDB")
        #expect(found.username == "wes.personal@example.org")

        let requests = server.recorded
        #expect(requests.allSatisfy { !$0.lowercased().contains("wes.personal") }, "the address never leaves the machine — domain only")
        #expect(requests.allSatisfy { !$0.lowercased().contains("cookie:") })
        #expect(requests.contains { $0.hasPrefix("GET /provider/example.org/") }, "provider endpoint tried first")
    }

    @Test func providerEndpointWinsOverISPDB() async throws {
        let server = try FakeHTTPServer { request in
            if request.hasPrefix("GET /provider/") { return (200, AutoconfigParsingTests.gmailXML.replacingOccurrences(of: "imap.gmail.com", with: "imap.provider.example").replacingOccurrences(of: "Google Mail", with: "Provider")) }
            return (200, AutoconfigParsingTests.gmailXML)
        }
        try await server.start()
        defer { server.stop() }
        let endpoints = AutoconfigService.Endpoints(
            ispdbBase: URL(string: "http://127.0.0.1:\(server.port)/v1.1/")!,
            providerTemplate: "http://127.0.0.1:\(server.port)/provider/%DOMAIN%/config-v1.1.xml"
        )

        let found = try await AutoconfigService.discover(email: "a@provider.example", endpoints: endpoints, verifyGuess: false)
        #expect(found.host == "imap.provider.example")
        #expect(found.providerName == "Provider")
    }

    @Test func nothingFoundWithoutAGuess() async throws {
        let server = try FakeHTTPServer { _ in (404, "") }
        try await server.start()
        defer { server.stop() }
        let endpoints = AutoconfigService.Endpoints(
            ispdbBase: URL(string: "http://127.0.0.1:\(server.port)/v1.1/")!,
            providerTemplate: "http://127.0.0.1:\(server.port)/provider/%DOMAIN%/config-v1.1.xml"
        )
        await #expect(throws: AutoconfigService.Failure.nothingFound) { try await AutoconfigService.discover(email: "a@nowhere.example", endpoints: endpoints, verifyGuess: false) }
    }
}

struct LinkHygieneTests {
    private func report(_ body: String, from domain: String = "northbank.example") -> LinkHygiene.Report {
        LinkHygiene.inspect(rawBody: Data(body.utf8), senderDomain: domain)
    }

    @Test func textHrefMismatchIsAPhishingTell() {
        let r = report(#"<p>Please <a href="https://evil.example/login">https://northbank.example/secure</a> to verify your account.</p>"#)
        #expect(r.warnings.contains { $0.contains("shows northbank.example") && $0.contains("goes to evil.example") })
    }

    @Test func punycodeAndBareIPAreFlagged() {
        let r = report(#"<a href="https://xn--pypal-4ve.example/x">Log in</a> or <a href="http://203.0.113.9/login">here</a> to sign in to your account"#)
        #expect(r.warnings.contains { $0.contains("punycode") })
        #expect(r.warnings.contains { $0.contains("bare IP") })
    }

    @Test func accountMailThatNeverLinksHomeIsFlagged() {
        let r = report(#"Unusual sign-in detected. <a href="https://secure-verify.example/nb">Verify your account</a>"#)
        #expect(r.warnings.contains { $0.contains("no link goes to northbank.example") })
    }

    @Test func newslettersLinkingOutAreFine() {
        let r = report(#"This week: <a href="https://nytimes.example/story">a story</a> and <a href="https://morningdigest.example/read">more</a>"#, from: "morningdigest.example")
        #expect(!r.isSuspicious)
        #expect(r.linkHosts == ["morningdigest.example", "nytimes.example"])
    }

    @Test func plainTextBodiesAreScannedToo() {
        let r = report("Reset your password at https://northbank-security.example/reset now", from: "northbank.example")
        #expect(r.linkHosts == ["northbank-security.example"])
        #expect(r.isSuspicious)
    }

    @Test func registrableDomainHandlesCountryCodes() {
        #expect(LinkHygiene.registrable("mail.google.com") == "google.com")
        #expect(LinkHygiene.registrable("news.bbc.co.uk") == "bbc.co.uk")
        #expect(LinkHygiene.registrable("example.org") == "example.org")
    }
}
