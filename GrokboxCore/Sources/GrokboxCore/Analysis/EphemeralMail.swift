import Foundation

/// Mail whose whole value expires: a verification code, a password reset link,
/// a "your delivery is today" notice.
///
/// The Brief exists to answer "what needs me first", and without this a
/// three-month-old one-time code outranks a real message — it looks urgent
/// (someone is waiting, it is quick, it has gone unanswered for weeks) while
/// being worth precisely nothing. Age makes ordinary mail *more* pressing and
/// this kind *less*, so it has to be told apart.
public enum EphemeralMail {
    /// How long this kind of message is worth anything, from when it arrived.
    public enum Kind: Sendable, Equatable {
        /// One-time codes: minutes in reality, a day here to be generous.
        case oneTimeCode
        /// Password resets and sign-in links: usually an hour, a day here.
        case resetLink
        /// "Unusual sign-in", "new device" — worth acting on quickly, but
        /// still worth seeing for a while afterwards.
        case securityAlert
        /// "Out for delivery", "arriving today", "your table is at 7".
        case timedEvent

        public var livesForDays: Int {
            switch self {
            case .oneTimeCode: 1
            case .resetLink: 1
            case .securityAlert: 7
            case .timedEvent: 2
            }
        }

        /// What the Brief says instead of pretending it still matters.
        public var expiredReason: String {
            switch self {
            case .oneTimeCode: "a code that has long since expired"
            case .resetLink: "a reset link that has expired"
            case .securityAlert: "an old security alert"
            case .timedEvent: "about a time that has passed"
            }
        }
    }

    private static let oneTimeCode = [
        "verification code", "verify code", "security code", "one-time code", "one time code",
        "one-time passcode", "otp", "your code is", "is your code", "confirmation code",
        "access code", "login code", "sign-in code", "sign in code", "authentication code",
        "2fa code", "two-factor code", "pin code",
    ]
    private static let resetLink = [
        "reset your password", "password reset", "reset password", "forgot your password",
        "confirm your email", "verify your email", "verify your account", "confirm your account",
        "activate your account", "sign-in link", "sign in link", "magic link", "login link",
    ]
    private static let securityAlert = [
        "security alert", "unusual sign-in", "unusual signin", "new sign-in", "new device",
        "unauthorized", "unauthorised", "suspicious activity", "someone has your password",
        "was signed in", "new login",
    ]
    private static let timedEvent = [
        "out for delivery", "arriving today", "arrives today", "delivered today",
        "starts in", "starting soon", "your ride", "is on the way", "reminder:",
    ]

    /// Word pairs that must both appear, for subjects that put a brand in the
    /// middle: "Reset your **Coddy** password", "Your **X** verification code".
    private static let pairs: [(Kind, [String])] = [
        (.resetLink, ["reset", "password"]),
        (.resetLink, ["confirm", "email"]),
        (.resetLink, ["verify", "email"]),
        (.resetLink, ["verify", "account"]),
        (.oneTimeCode, ["verification", "code"]),
        (.oneTimeCode, ["security", "code"]),
        (.oneTimeCode, ["login", "code"]),
        (.oneTimeCode, ["access", "code"]),
        (.securityAlert, ["security", "alert"]),
        (.securityAlert, ["unusual", "sign"]),
        (.securityAlert, ["new", "device"]),
    ]

    /// Classifies from the subject and, if available, the model's summary.
    public static func kind(subject: String, summary: String? = nil) -> Kind? {
        let text = (subject + " " + (summary ?? "")).lowercased()
        // Order matters: a reset mail often quotes a code as well, and the
        // reset is the more accurate description.
        if resetLink.contains(where: text.contains) { return .resetLink }
        if oneTimeCode.contains(where: text.contains) { return .oneTimeCode }
        if securityAlert.contains(where: text.contains) { return .securityAlert }
        if timedEvent.contains(where: text.contains) { return .timedEvent }
        for (kind, words) in pairs where words.allSatisfy(text.contains) { return kind }
        return nil
    }

    /// True when this message has outlived whatever use it had.
    public static func hasExpired(subject: String, summary: String? = nil,
                                  receivedAt: Date, now: Date, calendar: Calendar = .current) -> Kind? {
        guard let kind = kind(subject: subject, summary: summary) else { return nil }
        let age = calendar.dateComponents([.day], from: receivedAt, to: now).day ?? 0
        return age > kind.livesForDays ? kind : nil
    }
}
