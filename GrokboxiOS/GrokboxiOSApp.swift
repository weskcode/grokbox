import SwiftUI
import SwiftData
import GrokboxCore

/// Process-wide singletons, as on the Mac. Same store layout, same engine.
@MainActor
enum AppEnvironment {
    static let opened: GrokboxStore.Opened = GrokboxStore.open()
    static var container: ModelContainer { opened.container }
    static let state = AppState(context: container.mainContext)
}

@main
struct GrokboxiOSApp: App {
    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .modelContainer(AppEnvironment.container)
                .environment(AppEnvironment.state)
        }
    }
}
