import SwiftUI

extension View {
    /// Shows the reason a rule edit was not saved. The edit itself has already
    /// been undone by `RuleStore.apply`, so the screen matches the store.
    /// The alert sits on its own background view: two alerts on one view
    /// compete for the single presenter, and the loser never appears.
    func ruleSaveAlert(_ message: Binding<String?>) -> some View {
        background {
            Color.clear.alert("Couldn't save the rule", isPresented: Binding(get: { message.wrappedValue != nil },
                                                                           set: { if !$0 { message.wrappedValue = nil } }),
                              presenting: message.wrappedValue) { _ in
                Button("OK", role: .cancel) { }
            } message: { Text($0) }
        }
    }
}
