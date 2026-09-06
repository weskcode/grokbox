import Foundation

/// Three sample mailboxes with different personalities, so the app can be
/// exercised across the situations it is meant for.
public enum DemoPersona: String, CaseIterable, Sendable, Codable {
    /// Friends, family, a few bills, the usual newsletters. Mostly under control.
    case personal
    /// Colleagues, task trackers, calendar noise, recruiters. High volume, high stakes.
    case work
    /// An old address that became a spam magnet. Two humans, hundreds of promos.
    case neglected

    public var username: String {
        switch self {
        case .personal: "wes.personal@grokbox.demo"
        case .work: "wes@acme-work.demo"
        case .neglected: "wes.old.2014@grokbox.demo"
        }
    }

    public var displayName: String {
        switch self {
        case .personal: "Demo · Personal"
        case .work: "Demo · Work"
        case .neglected: "Demo · Old Gmail"
        }
    }

    public var blurb: String {
        switch self {
        case .personal: "A normal inbox: friends, family, bills, a few newsletters."
        case .work: "A work inbox: colleagues, task-tracker noise, recruiters, and a boss who needs answers."
        case .neglected: "A neglected address: hundreds of promos, social notifications, and two real people buried in it."
        }
    }

    public static func from(username: String) -> DemoPersona? {
        allCases.first { $0.username.caseInsensitiveCompare(username) == .orderedSame }
    }

    var seed: UInt64 {
        switch self {
        case .personal: 7
        case .work: 11
        case .neglected: 23
        }
    }
}
