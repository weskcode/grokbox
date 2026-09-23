import AppIntents

/// "Tidy up Grokbox" from Shortcuts or Siri. Runs in-process — the app is
/// brought forward first (`openAppWhenRun`), then this calls the same
/// `AppState.tidyUp(_:)` every in-app "Tidy up now" button already calls.
/// No App Group, no widget extension: nothing here runs while the app is
/// not actually open.
struct TidyUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Tidy Up Now"
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppEnvironment.state.tidyUpEverything()
        return .result()
    }
}

struct GrokboxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TidyUpIntent(), phrases: ["Tidy up \(.applicationName)"],
                   shortTitle: "Tidy Up Now", systemImageName: "wind")
    }
}
