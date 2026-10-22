import SwiftUI
import SwiftData
import GrokboxCore

/// Changes one sender's rule from a typed sentence ("trash them", "file them
/// under "Reading""). `RuleProposal` reads it; nothing is saved here. A draft
/// goes on to the review sheet, which previews it and saves it on request.
struct PhoneDescribeChangeSheet: View {
    let address: String
    let senderName: String
    let policy: CleanupPolicy
    /// The host closes this sheet's turn by opening the review sheet.
    let onPreview: (RuleDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var request = ""
    @State private var result: RuleProposal?
    @State private var readError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Describe a change", text: $request, prompt: Text("Trash them"))
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(read)
                        .accessibilityIdentifier("describeChangeField")
                } header: {
                    Text(senderName.isEmpty ? address : senderName)
                } footer: {
                    Text("Applies to \(address) in every account. Folder names go in quotes: file them under \"Reading\".")
                }
                if let readError {
                    Section { Text(readError).foregroundStyle(.red) }
                }
                switch result {
                case .draft(let draft)?:
                    Section("Draft") {
                        Text(draft.title).font(.body.weight(.semibold)).accessibilityIdentifier("describeChangeDraft")
                        ForEach(draft.irreversibleEffects, id: \.self) { effect in
                            Label(effect, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        }
                        Button("Preview…") { onPreview(draft); dismiss() }.accessibilityIdentifier("describeChangePreview")
                    }
                case .unresolved(let reason)?:
                    Section {
                        Text(reason.message).accessibilityIdentifier("describeChangeRefusal")
                    } footer: {
                        Text("Nothing was drafted.")
                    }
                case nil:
                    EmptyView()
                }
            }
            .navigationTitle("Change the rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Draft", action: read).disabled(request.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onChange(of: request) { result = nil }
    }

    private func read() {
        guard !request.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            result = try RuleProposal.make(request: request, address: address, in: modelContext, policy: policy)
            readError = nil
        } catch {
            result = nil
            readError = "Grokbox couldn't read this sender's rule, so nothing was drafted. \(error.localizedDescription)"
        }
    }
}
