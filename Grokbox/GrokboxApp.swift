import SwiftUI
import SwiftData
import GrokboxCore

/// Process-wide singletons, created lazily on first use. Deliberately not
/// properties of the App struct: giving `GrokboxApp` a custom `init` (to build
/// these eagerly) stopped SwiftUI from presenting the main window at launch on
/// macOS 27 — reproduced and reverted in the audit.
@MainActor
enum AppEnvironment {
    /// Opened through `GrokboxStore`, which versions the schema and recovers
    /// from an unreadable store instead of trapping. The old `fatalError` here
    /// turned any bad store into an app that could not launch — and therefore
    /// could not be reset from inside itself.
    static let opened: GrokboxStore.Opened = GrokboxStore.open()
    static var container: ModelContainer { opened.container }

    static let state = AppState(context: container.mainContext)
}

@main
struct GrokboxApp: App {

    var body: some Scene {
        // No scene id on purpose: on macOS 27 an identified main scene
        // (`WindowGroup(id:)` or `Window(id:)`) is not presented at launch. ADR-0016.
        WindowGroup {
            RootView()
        }
        .modelContainer(AppEnvironment.container)
        .environment(AppEnvironment.state)
        .defaultSize(width: 1180, height: 760)

        // Glanceable state without opening the window; tidy-up keeps running
        // while the window is closed. Can be hidden from Settings.
        MenuBarExtra(isInserted: menuBarInsertion) {
            MenuBarView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
        .modelContainer(AppEnvironment.container)
        .environment(AppEnvironment.state)
    }

    /// Reads and writes `AppState.showMenuBar`. The setter drops no-op writes:
    /// MenuBarExtra echoes its insertion state back on every scene update, and
    /// without this guard that echo re-enters the scene body forever (ADR-0017).
    private var menuBarInsertion: Binding<Bool> {
        Binding(
            get: { AppEnvironment.state.showMenuBar },
            set: { wanted in
                guard AppEnvironment.state.showMenuBar != wanted else { return }
                AppEnvironment.state.showMenuBar = wanted
            }
        )
    }
}
