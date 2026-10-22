import SwiftUI
import SwiftData
import GrokboxCore

/// Changes one sender's rule from a typed sentence ("trash them", "file them
/// under "Reading""). `RuleProposal` reads it; nothing is saved here. A draft
/// goes on to the review sheet, which previews it and saves it on request.
struct DescribeChangeSheet: View {
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Change the rule for \(senderName.isEmpty ? address : senderName)").font(.headline)
                Text("\(address) · applies in all accounts").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Describe a change", text: $request, prompt: Text("Trash them"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(read)
            Text("Folder names go in quotes: file them under \"Reading\".")
                .font(.caption).foregroundStyle(.secondary)
            outcome
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if case .draft(let draft) = result {
                    Button("Preview…") { onPreview(draft); dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Draft", action: read).keyboardShortcut(.defaultAction)
                        .disabled(request.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 440)
        .onChange(of: request) { result = nil }
    }

    @ViewBuilder private var outcome: some View {
        if let readError {
            Text(readError).font(.callout).foregroundStyle(.red)
        }
        switch result {
        case .draft(let draft)?:
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.title).font(.callout.weight(.semibold))
                ForEach(draft.irreversibleEffects, id: \.self) { effect in
                    Label(effect, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .unresolved(let reason)?:
            VStack(alignment: .leading, spacing: 2) {
                Text(reason.message).font(.callout)
                Text("Nothing was drafted.").font(.caption).foregroundStyle(.secondary)
            }
        case nil:
            EmptyView()
        }
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
