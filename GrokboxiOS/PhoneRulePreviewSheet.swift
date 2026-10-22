import SwiftUI
import SwiftData
import GrokboxCore

/// How a rule sheet ended, when it ended by saving.
enum RuleSheetOutcome {
    case saved
    case failed(String)
}

/// A rule choice waiting for the person to see what it would do.
struct PendingRuleEdit: Identifiable {
    let id = UUID()
    let address: String
    let senderName: String
    let edit: RuleEdit
}

extension View {
    /// Every rule choice opens this sheet first; nothing is written until
    /// Save. A save the store refuses closes the sheet and is reported through
    /// `errorMessage`; a save calls `onSaved`.
    func ruleEditSheet(_ pending: Binding<PendingRuleEdit?>, policy: CleanupPolicy,
                       errorMessage: Binding<String?>, onSaved: @escaping () -> Void = {}) -> some View {
        modifier(RuleEditSheetModifier(pending: pending, policy: policy, errorMessage: errorMessage, onSaved: onSaved))
    }
}

private struct RuleEditSheetModifier: ViewModifier {
    @Binding var pending: PendingRuleEdit?
    let policy: CleanupPolicy
    @Binding var errorMessage: String?
    let onSaved: () -> Void
    @State private var outcome: RuleSheetOutcome?

    func body(content: Content) -> some View {
        content.sheet(item: $pending, onDismiss: {
            // Reported after the sheet has gone: an alert raised while a sheet
            // is closing is dropped.
            switch outcome {
            case .saved: onSaved()
            case .failed(let message): errorMessage = message
            case nil: break
            }
            outcome = nil
        }) { item in
            PhoneRulePreviewSheet(pending: item, policy: policy, outcome: $outcome)
        }
    }
}

/// Shows what a rule choice would do to the sender's mail, from the same plan
/// and guard a sweep uses, and saves it only on request. See `RulePreview`.
struct PhoneRulePreviewSheet: View {
    let pending: PendingRuleEdit
    let policy: CleanupPolicy
    @Binding var outcome: RuleSheetOutcome?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var preview: RulePreview?
    @State private var loadError: String?
    @State private var changedSincePreview = false

    var body: some View {
        NavigationStack {
            List {
                if let loadError {
                    Section { Text(loadError).foregroundStyle(.red) }
                } else if let preview {
                    if changedSincePreview {
                        Section {
                            Label("Mail changed since you opened this. Review it again before saving.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    Section("Scope") { Text(scopeText(preview)) }
                    ForEach(preview.accounts) { effect in accountSections(effect, showName: preview.accounts.count > 1) }
                    if !preview.irreversibleEffects.isEmpty {
                        Section {
                            ForEach(Array(preview.irreversibleEffects.enumerated()), id: \.offset) { _, effect in
                                Label(effect.warning, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                            }
                        }
                    }
                } else {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(pending.edit.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(preview == nil).accessibilityIdentifier("saveRule")
                }
            }
        }
        .task { refresh() }
    }

    private func scopeText(_ preview: RulePreview) -> String {
        let sender = pending.senderName == pending.address ? pending.address : "\(pending.senderName) · \(pending.address)"
        if preview.accounts.isEmpty { return "\(sender). Rules cover an address in every account. No account here receives mail from this sender." }
        var text = "\(sender). Rules cover this address in every account: " + preview.accounts.map(\.accountName).joined(separator: ", ") + "."
        if let indexed = preview.indexedAt {
            text += " Based on mail indexed \(indexed.formatted(date: .abbreviated, time: .shortened)). Flags are checked again when a sweep runs."
        }
        return text
    }

    @ViewBuilder private func accountSections(_ effect: RulePreview.AccountEffect, showName: Bool) -> some View {
        switch effect.outcome {
        case .sweeps(let sweep):
            Section(showName ? "\(effect.accountName): would move to \(sweep.destination) (\(sweep.affectedCount))"
                             : "Would move to \(sweep.destination) (\(sweep.affectedCount))") {
                if sweep.affected.isEmpty { Text("Nothing would move.").foregroundStyle(.secondary) }
                ForEach(sweep.affected) { Text($0.subject).lineLimit(1) }
                if sweep.affectedCount > sweep.affected.count {
                    Text("and \(sweep.affectedCount - sweep.affected.count) more").font(.caption).foregroundStyle(.secondary)
                }
                if sweep.markRead { Text("Marked read as it moves.").font(.caption).foregroundStyle(.secondary) }
            }
            if sweep.heldCount > 0 {
                Section("Staying in the inbox (\(sweep.heldCount))") {
                    ForEach(sweep.held) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.subject).lineLimit(1)
                            Text(message.heldReason ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if sweep.heldCount > sweep.held.count {
                        Text("and \(sweep.heldCount - sweep.held.count) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .keptInInbox:
            note(effect, showName, "Stays in the inbox. Grokbox will not suggest sweeping this sender.")
        case .nothingPending:
            note(effect, showName, "Nothing from this sender is waiting in the inbox.")
        case .notProposed:
            note(effect, showName, "Grokbox would not propose sweeping this sender.")
        }
    }

    private func note(_ effect: RulePreview.AccountEffect, _ showName: Bool, _ text: String) -> some View {
        Section(showName ? effect.accountName : "Effect") { Text(text) }
    }

    private func refresh() {
        do {
            preview = try RulePreview.make(address: pending.address, edit: pending.edit, policy: policy, in: modelContext)
            loadError = nil
        } catch {
            preview = nil
            loadError = "Couldn't read this sender's mail, so the effect can't be shown and nothing was saved. \(error.localizedDescription)"
        }
    }

    /// Saves only what was shown: if the index moved since, show the new
    /// result and ask again.
    private func save() {
        guard let shown = preview else { return }
        do {
            let fresh = try RulePreview.make(address: pending.address, edit: pending.edit, policy: policy, in: modelContext)
            guard fresh.sameEffect(as: shown) else {
                preview = fresh
                changedSincePreview = true
                return
            }
            try RuleStore.apply(pending.edit, for: pending.address, in: modelContext)
            outcome = .saved
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        dismiss()
    }
}
