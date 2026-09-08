import SwiftUI
import GrokboxCore

/// Why a normal password will not work, and exactly how to get one that will.
///
/// This is the single most common place a first-time setup fails, so the
/// explanation lives next to the field rather than in documentation nobody
/// opens. Every provider here removed plain-password IMAP for the same reason:
/// a password that can read your mail can also take your whole account.
struct CredentialGuide: View {
    let kind: AccountKind
    let host: String
    @State private var expanded = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let guide = Guide.forKind(kind, host: host) {
            VStack(alignment: .leading, spacing: 8) {
                Label(guide.headline, systemImage: "key.fill")
                    .font(.callout.weight(.medium))
                Text(guide.why)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(step).font(.caption).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if let url = guide.url {
                            Button {
                                openURL(url)
                            } label: {
                                Label(guide.linkLabel, systemImage: "arrow.up.forward.square")
                            }
                            .controlSize(.small)
                            .padding(.top, 2)
                        }
                        Text(guide.reassurance)
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    .padding(.top, 6)
                } label: {
                    Text(expanded ? "Hide the steps" : "Show me how")
                        .font(.caption.weight(.medium))
                }
                .accessibilityLabel("How to create an app password")
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The per-provider content, kept apart from the view so it can be tested.
struct Guide: Equatable {
    var headline: String
    var why: String
    var steps: [String]
    var url: URL?
    var linkLabel: String
    var reassurance: String

    static let google = Guide(
        headline: "Gmail needs an App Password, not your Google password",
        why: "Google stopped accepting normal passwords for mail apps in 2022. Your usual password will be rejected however carefully you type it.",
        steps: [
            "Turn on 2-Step Verification for your Google Account. App Passwords do not exist without it.",
            "Open Google Account → Security → 2-Step Verification, then scroll to App passwords.",
            "Type a name — “Grokbox” — and press Create.",
            "Google shows a 16-character code once. Copy it and paste it into the Password field here. Spaces do not matter.",
            "Make sure IMAP is enabled: Gmail → Settings → Forwarding and POP/IMAP → Enable IMAP.",
        ],
        url: URL(string: "https://myaccount.google.com/apppasswords"),
        linkLabel: "Open Google App Passwords",
        reassurance: "An App Password is safer than your real one: it only works for mail, it cannot sign into your Google account, and you can revoke it at any time without changing your password.")

    static let icloud = Guide(
        headline: "iCloud needs an app-specific password",
        why: "Apple requires a separate password for third-party mail apps. Your Apple Account password will be rejected.",
        steps: [
            "Turn on two-factor authentication for your Apple Account.",
            "Open account.apple.com → Sign-In and Security → App-Specific Passwords.",
            "Press the plus, name it “Grokbox”, and copy the password it shows.",
            "Paste it into the Password field here.",
        ],
        url: URL(string: "https://account.apple.com/account/manage"),
        linkLabel: "Open Apple Account",
        reassurance: "It only works for this app, and revoking it does not affect your Apple Account password.")

    static let yahoo = Guide(
        headline: "Yahoo needs an app password",
        why: "Yahoo blocks normal passwords for mail apps.",
        steps: [
            "Open Yahoo Account Security → Generate app password.",
            "Name it “Grokbox” and copy the password.",
            "Paste it into the Password field here.",
        ],
        url: URL(string: "https://login.yahoo.com/account/security"),
        linkLabel: "Open Yahoo Account Security",
        reassurance: "Revoking it later does not affect your Yahoo password.")

    static let fastmail = Guide(
        headline: "Fastmail needs an app password",
        why: "Fastmail issues a separate password per app, scoped to what that app may do.",
        steps: [
            "Open Fastmail Settings → Privacy & Security → Third-party apps.",
            "Press New app password, name it “Grokbox”, and set access to Mail.",
            "Copy the password and paste it into the Password field here.",
        ],
        url: URL(string: "https://app.fastmail.com/settings/security/thirdparty"),
        linkLabel: "Open Fastmail app passwords",
        reassurance: "Scoped to mail only, and revocable on its own.")

    static let outlook = Guide(
        headline: "Outlook.com is moving away from password sign-in",
        why: "Microsoft is retiring password-based IMAP in favour of OAuth, which Grokbox does not support yet. If your account still allows an app password, it will work; otherwise Outlook cannot be added.",
        steps: [
            "Open account.microsoft.com → Security → Advanced security options.",
            "Under App passwords, create one and copy it.",
            "Paste it here. If the option is missing, your account has already moved to OAuth-only.",
        ],
        url: URL(string: "https://account.microsoft.com/security"),
        linkLabel: "Open Microsoft account security",
        reassurance: "Support for signing in with Microsoft directly is on the roadmap.")

    static let protonBridge = Guide(
        headline: "Proton needs the password from Bridge",
        why: "Proton encrypts mail end to end, so no server speaks plain IMAP. Bridge runs on your Mac, decrypts locally, and gives Grokbox its own password — not your Proton password.",
        steps: [
            "Install and sign into Proton Mail Bridge. It needs a paid Proton plan.",
            "In Bridge, open Settings → Advanced and set Connection mode to SSL.",
            "Open your account in Bridge and copy the IMAP password it shows.",
            "Paste it here. Bridge must be running whenever Grokbox syncs.",
        ],
        url: URL(string: "https://proton.me/mail/bridge"),
        linkLabel: "About Proton Mail Bridge",
        reassurance: "Your mail is decrypted on this Mac by Bridge. Nothing is sent anywhere else.")

    /// Matches on the account kind first, then on the server for "Other IMAP",
    /// so someone who picks Other and types imap.gmail.com still gets help.
    static func forKind(_ kind: AccountKind, host: String) -> Guide? {
        switch kind {
        case .gmail: return google
        case .protonBridge: return protonBridge
        case .demo: return nil
        case .generic: break
        }
        let host = host.lowercased()
        if host.contains("gmail") || host.contains("googlemail") { return google }
        if host.contains("mail.me.com") || host.contains("icloud") { return icloud }
        if host.contains("yahoo") { return yahoo }
        if host.contains("fastmail") || host.contains("messagingengine") { return fastmail }
        if host.contains("office365") || host.contains("outlook") || host.contains("hotmail") { return outlook }
        return nil
    }
}
