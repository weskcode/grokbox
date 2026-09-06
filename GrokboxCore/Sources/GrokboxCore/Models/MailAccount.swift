import Foundation
import SwiftData

/// Preset connection profiles. Grokbox speaks plain IMAP to everything;
/// these just fill in the host/port/security so the user does not have to.
public enum AccountKind: String, Codable, CaseIterable, Sendable {
    case gmail
    case protonBridge
    case generic
    /// The built-in sample mailbox. Served from inside the app on loopback.
    case demo

    public var displayName: String {
        switch self {
        case .gmail: "Gmail"
        case .protonBridge: "Proton Mail (via Bridge)"
        case .generic: "Other IMAP"
        case .demo: "Demo mailbox (built in)"
        }
    }

    public var defaultHost: String {
        switch self {
        case .gmail: "imap.gmail.com"
        case .protonBridge, .demo: "127.0.0.1"
        case .generic: ""
        }
    }

    public var defaultPort: Int {
        switch self {
        case .gmail: 993
        case .protonBridge: 1143
        case .generic: 993
        case .demo: 0
        }
    }

    /// Proton Bridge terminates TLS on loopback with its own certificate, so we
    /// accept a self-signed cert there and nowhere else. Everything remote is
    /// proper TLS. The demo server is in-process and speaks cleartext.
    public var defaultSecurity: IMAPSecurity {
        switch self {
        case .gmail, .generic: .tls
        case .protonBridge: .tlsSelfSignedLoopback
        case .demo: .none
        }
    }

    public var isDemo: Bool { self == .demo }

    /// What the user needs to paste in the password field.
    public var credentialHint: String {
        switch self {
        case .gmail:
            "Google App Password (16 characters). Requires 2-Step Verification. "
            + "Your normal Google password will not work."
        case .protonBridge:
            "The password shown in the Proton Mail Bridge app, not your Proton password. "
            + "Bridge must be running."
        case .generic:
            "Your IMAP password, or an app-specific password if your provider issues them."
        case .demo:
            "No password needed. A sample inbox is generated on this Mac so you can watch Grokbox work before trusting it with real mail."
        }
    }
}

@Model
public final class MailAccount {
    #Index<MailAccount>([\.username])

    public var id: UUID = UUID()
    public var displayName: String = ""
    public var username: String = ""
    public var host: String = ""
    public var port: Int = 993
    public var kindRaw: String = AccountKind.generic.rawValue
    public var securityRaw: String = IMAPSecurity.tls.rawValue
    public var createdAt: Date = Date()
    public var lastSyncedAt: Date?
    public var lastReadAt: Date?
    public var lastSyncError: String?

    public var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .generic }
        set { kindRaw = newValue.rawValue }
    }

    public var security: IMAPSecurity {
        get { IMAPSecurity(rawValue: securityRaw) ?? .tls }
        set { securityRaw = newValue.rawValue }
    }

    /// Stable key for the Keychain item holding this account's password.
    public var keychainAccount: String { "\(username)@\(host):\(port)" }

    public init(
        displayName: String,
        username: String,
        host: String,
        port: Int,
        kind: AccountKind,
        security: IMAPSecurity
    ) {
        self.id = UUID()
        self.displayName = displayName
        self.username = username
        self.host = host
        self.port = port
        self.kindRaw = kind.rawValue
        self.securityRaw = security.rawValue
        self.createdAt = Date()
    }
}
