import Foundation

/// Account settings discovery, in the order Thunderbird uses: the provider's
/// own autoconfig endpoint, Mozilla's ISPDB, then a guess verified by
/// connecting. The Thunderbird config-v1.1 XML format is the lingua franca
/// of open-source mail clients, so Grokbox speaks it too.
///
/// Privacy: only the *domain* of the address is ever sent anywhere — never
/// the address itself — and only when the user presses "Look up settings".
/// This is the fourth and last kind of outbound connection in the app; see
/// docs/PRIVACY.md.
public enum AutoconfigService {
    public struct Discovered: Sendable, Equatable {
        public var providerName: String
        public var host: String
        public var port: Int
        public var security: IMAPSecurity
        /// The username the provider expects, with placeholders resolved.
        public var username: String
        public var offersOAuth2: Bool
        public var offersPassword: Bool
        /// Where the answer came from — shown to the user.
        public var source: String

        public init(providerName: String, host: String, port: Int, security: IMAPSecurity, username: String,
                    offersOAuth2: Bool, offersPassword: Bool, source: String) {
            self.providerName = providerName
            self.host = host
            self.port = port
            self.security = security
            self.username = username
            self.offersOAuth2 = offersOAuth2
            self.offersPassword = offersPassword
            self.source = source
        }
    }

    public enum Failure: Error, Equatable {
        case invalidAddress
        case onlySTARTTLS(host: String)
        case nothingFound
    }

    /// Where to look. Tests point these at a loopback server.
    public struct Endpoints: Sendable {
        /// Base URL of the ISPDB; the domain is appended.
        public var ispdbBase: URL
        /// Template for the provider-hosted endpoint; `%DOMAIN%` is substituted.
        public var providerTemplate: String

        public static let standard = Endpoints(
            ispdbBase: URL(string: "https://autoconfig.thunderbird.net/v1.1/")!,
            providerTemplate: "https://autoconfig.%DOMAIN%/mail/config-v1.1.xml"
        )

        public init(ispdbBase: URL, providerTemplate: String) {
            self.ispdbBase = ispdbBase
            self.providerTemplate = providerTemplate
        }
    }

    public static func discover(email: String, endpoints: Endpoints = .standard, session: URLSession = .shared, verifyGuess: Bool = true) async throws -> Discovered {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = trimmed.lastIndex(of: "@"), at > trimmed.startIndex, at < trimmed.index(before: trimmed.endIndex) else {
            throw Failure.invalidAddress
        }
        let domain = String(trimmed[trimmed.index(after: at)...])
        var sawSTARTTLSOnly: String?

        // 1. The provider's own endpoint. Domain only, no address parameter.
        if let url = URL(string: endpoints.providerTemplate.replacingOccurrences(of: "%DOMAIN%", with: domain)),
           let data = try? await fetch(url, session: session) {
            switch parse(xml: data, email: trimmed, source: "\(domain)'s autoconfig") {
            case .success(let found): return found
            case .failure(let failure): if case .onlySTARTTLS(let host) = failure { sawSTARTTLSOnly = host }
            }
        }

        // 2. Mozilla's ISPDB, by domain.
        if let data = try? await fetch(endpoints.ispdbBase.appending(path: domain), session: session) {
            switch parse(xml: data, email: trimmed, source: "Mozilla ISPDB") {
            case .success(let found): return found
            case .failure(let failure): if case .onlySTARTTLS(let host) = failure { sawSTARTTLSOnly = host }
            }
        }

        // 3. Guess, then prove it by reading an IMAP greeting over TLS.
        let guess = "imap.\(domain)"
        if verifyGuess, await greets(host: guess) {
            return Discovered(providerName: domain, host: guess, port: 993, security: .tls, username: trimmed,
                              offersOAuth2: false, offersPassword: true, source: "Guessed and verified")
        }

        if let host = sawSTARTTLSOnly { throw Failure.onlySTARTTLS(host: host) }
        throw Failure.nothingFound
    }

    private static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw Failure.nothingFound }
        return data
    }

    private static func greets(host: String) async -> Bool {
        let client = IMAPClient()
        defer { Task { await client.logout() } }
        return (try? await client.connect(host: host, port: 993, security: .tls)) != nil
    }

    // MARK: - Parsing

    /// Reads the first IMAP `incomingServer` from a Thunderbird config-v1.1 document.
    public static func parse(xml: Data, email: String, source: String) -> Result<Discovered, Failure> {
        let parser = ConfigParser()
        let xmlParser = XMLParser(data: xml)
        xmlParser.delegate = parser
        xmlParser.parse()

        guard let server = parser.imapServers.first else { return .failure(.nothingFound) }
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let domain = email.split(separator: "@").last.map(String.init) ?? ""
        let username = (server.username ?? "%EMAILADDRESS%")
            .replacingOccurrences(of: "%EMAILADDRESS%", with: email)
            .replacingOccurrences(of: "%EMAILLOCALPART%", with: local)
            .replacingOccurrences(of: "%EMAILDOMAIN%", with: domain)

        let security: IMAPSecurity
        switch server.socketType?.uppercased() {
        case "SSL": security = .tls
        case "STARTTLS":
            // Prefer another server entry with SSL if the document has one.
            if let ssl = parser.imapServers.first(where: { $0.socketType?.uppercased() == "SSL" }) {
                return parse(single: ssl, parser: parser, email: email, source: source)
            }
            return .failure(.onlySTARTTLS(host: server.hostname ?? "?"))
        default: return .failure(.nothingFound)
        }
        guard let host = server.hostname, let port = server.port else { return .failure(.nothingFound) }
        return .success(Discovered(
            providerName: parser.displayName ?? domain, host: host, port: port, security: security, username: username,
            offersOAuth2: server.authentication.contains { $0.caseInsensitiveCompare("OAuth2") == .orderedSame },
            offersPassword: server.authentication.contains { $0.lowercased().hasPrefix("password") },
            source: source
        ))
    }

    private static func parse(single server: ConfigParser.Server, parser: ConfigParser, email: String, source: String) -> Result<Discovered, Failure> {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let domain = email.split(separator: "@").last.map(String.init) ?? ""
        guard let host = server.hostname, let port = server.port else { return .failure(.nothingFound) }
        let username = (server.username ?? "%EMAILADDRESS%")
            .replacingOccurrences(of: "%EMAILADDRESS%", with: email)
            .replacingOccurrences(of: "%EMAILLOCALPART%", with: local)
            .replacingOccurrences(of: "%EMAILDOMAIN%", with: domain)
        return .success(Discovered(
            providerName: parser.displayName ?? domain, host: host, port: port, security: .tls, username: username,
            offersOAuth2: server.authentication.contains { $0.caseInsensitiveCompare("OAuth2") == .orderedSame },
            offersPassword: server.authentication.contains { $0.lowercased().hasPrefix("password") },
            source: source
        ))
    }

    private final class ConfigParser: NSObject, XMLParserDelegate {
        struct Server {
            var hostname: String?
            var port: Int?
            var socketType: String?
            var username: String?
            var authentication: [String] = []
        }
        var imapServers: [Server] = []
        var displayName: String?
        private var current: Server?
        private var text = ""
        private var inIncoming = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            text = ""
            if name == "incomingServer" {
                inIncoming = attributes["type"]?.lowercased() == "imap"
                current = inIncoming ? Server() : nil
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "displayName", displayName == nil { displayName = value }
            guard inIncoming, current != nil else { return }
            switch name {
            case "hostname": current?.hostname = value
            case "port": current?.port = Int(value)
            case "socketType": current?.socketType = value
            case "username": current?.username = value
            case "authentication": current?.authentication.append(value)
            case "incomingServer":
                if let server = current { imapServers.append(server) }
                current = nil
                inIncoming = false
            default: break
            }
        }
    }
}
