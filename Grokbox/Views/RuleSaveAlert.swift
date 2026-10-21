import SwiftUI
import SwiftData
import GrokboxCore

extension View {
    /// Shows the reason a rule edit was not saved. The edit itself has already
    /// been undone by `RuleStore.apply`, so the screen matches the store.
    func ruleSaveAlert(_ message: Binding<String?>) -> some View {
        alert("Couldn't save the rule", isPresented: Binding(get: { message.wrappedValue != nil },
                                                             set: { if !$0 { message.wrappedValue = nil } }),
              presenting: message.wrappedValue) { _ in
            Button("OK", role: .cancel) { }
        } message: { Text($0) }
    }
}

extension ModelContext {
    /// Saves a rule edit, reporting a failure through `message`.
    @MainActor
    func saveRule(_ edit: RuleEdit, for address: String, reportingTo message: Binding<String?>) {
        do { try RuleStore.apply(edit, for: address, in: self) }
        catch { message.wrappedValue = error.localizedDescription }
    }
}
