import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case brief, senders, sweep, activity, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .brief: "Brief"
        case .senders: "Senders"
        case .sweep: "Sweep"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .brief: "sun.horizon"
        case .senders: "person.2"
        case .sweep: "wind"
        case .activity: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}
