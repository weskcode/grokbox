import SwiftUI
import GrokboxCore

/// The status-bar icon. Display only: first-launch work is kicked from the
/// main window's root view. Driving it from here — a `.task` hosted in a
/// status-bar item — was observed to stall part-way on macOS 27.
struct MenuBarLabel: View {
    var body: some View {
        Label("Grokbox", systemImage: "tray")
    }
}
