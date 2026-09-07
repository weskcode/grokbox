import Foundation
import GrokboxCore

/// One place for turning an IMAP failure into a sentence a person can act on.
enum ConnectionErrorText {
    static func friendly(_ error: Error, kind: AccountKind, port: Int) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("AUTHENTICATIONFAILED") || text.localizedCaseInsensitiveContains("Invalid credentials") {
            switch kind {
            case .gmail: return "Google rejected the sign-in. This is almost always because a normal Google password was used — Google requires a 16-character App Password. Press “Show me how” above for the steps."
            case .protonBridge: return "Bridge rejected the sign-in. Use the password shown inside the Proton Mail Bridge app."
            default: return "The server rejected the username or password."
            }
        }
        if text.localizedCaseInsensitiveContains("Connection refused") && kind == .protonBridge {
            return "Nothing is listening on 127.0.0.1:\(port). Is Proton Mail Bridge running, with Connection mode set to SSL?"
        }
        return text
    }

    /// Whether a sync error means the password needs replacing.
    static func looksLikeAuthFailure(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.localizedCaseInsensitiveContains("AUTHENTICATIONFAILED")
            || text.localizedCaseInsensitiveContains("Invalid credentials")
            || text.localizedCaseInsensitiveContains("rejected the sign-in")
            || text.localizedCaseInsensitiveContains("No password saved")
    }
}
