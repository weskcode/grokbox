import Foundation

/// RFC 8058 one-click unsubscribe.
///
/// **This is one of only two places Grokbox makes a network connection to
/// anything other than your mail server** (the other is Ollama on loopback).
/// It POSTs to a URL the *sender* put in their own message headers, and it
/// only does so when the user clicks Unsubscribe on that sender. The sender
/// already has your address; this tells them to stop using it.
public enum UnsubscribeService {
    public enum Outcome: Sendable, Equatable {
        /// The sender's server acknowledged the POST.
        case unsubscribed
        /// No one-click support; the user should open this URL themselves.
        case openInBrowser(URL)
        /// Only a mailto: option exists. Grokbox does not send mail.
        case requiresEmail(String)
        case failed(String)
    }

    public static func unsubscribe(from cluster: SenderCluster) async -> Outcome {
        guard let url = cluster.unsubscribeURL else {
            if let mailto = cluster.unsubscribeValue?
                .split(separator: ",")
                .map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: " <>")) })
                .first(where: { $0.hasPrefix("mailto:") }) {
                return .requiresEmail(mailto)
            }
            return .failed("No unsubscribe link in this sender's headers.")
        }

        // A message-supplied URL is never POSTed to unless it is HTTPS to a
        // public host. Anything else is handed to the browser, where the
        // user can see where it goes before it goes there.
        guard PublicHostPolicy.check(url) == nil, cluster.supportsOneClickUnsubscribe else {
            return .openInBrowser(url)
        }
        return await performOneClick(to: url)
    }

    /// The POST itself. Body is the RFC 8058 constant and nothing else: no
    /// cookies, no identifiers beyond what the sender already put in the URL.
    /// Redirects are followed at most once, and only to a public HTTPS host.
    ///
    /// - Parameter allowingLoopbackForTests: the policy refuses loopback, which
    ///   is where the test server lives. Tests set this; the app never does.
    public static func performOneClick(to url: URL, allowingLoopbackForTests: Bool = false) async -> Outcome {
        if !allowingLoopbackForTests, let refusal = PublicHostPolicy.check(url) {
            return .failed("Refused: unsubscribe link is not a public HTTPS address (\(refusal)).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request, delegate: RedirectGuard())
            guard let http = response as? HTTPURLResponse else { return .failed("No HTTP response.") }
            return (200..<300).contains(http.statusCode)
                ? .unsubscribed
                : .openInBrowser(url)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
