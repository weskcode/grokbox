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
    /// `errorMessage`, which `ruleSaveAlert` shows; a save calls `onSaved`.
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
            RulePreviewSheet(pending: item, policy: policy, outcome: $outcome)
        }
    }
}

/// Shows what a rule choice would do to the sender's mail, from the same plan
/// and guard a sweep uses, and saves it only on request. See `RulePreview`.
struct RulePreviewSheet: View {
    let pending: PendingRuleEdit
    let policy: CleanupPolicy
    @Binding var outcome: RuleSheetOutcome?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var preview: RulePreview?
    @State private var loadError: String?
    @State private var changedSincePreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(16) }
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .task { refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pending.edit.title).font(.headline)
            Text(pending.senderName == pending.address ? pending.address : "\(pending.senderName) · \(pending.address)")
                .font(.caption).foregroundStyle(.secondary)
            if let preview, let indexed = preview.indexedAt {
                Text("Based on mail indexed \(indexed.formatted(date: .abbreviated, time: .shortened)). Flags are checked again when a sweep runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        if let loadError {
            Text(loadError).font(.callout).foregroundStyle(.red)
        } else if let preview {
            VStack(alignment: .leading, spacing: 12) {
                if changedSincePreview {
                    Label("Mail changed since you opened this. Review it again before saving.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                GroupBox("Scope") {
                    Text(scopeText(preview)).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(preview.accounts) { effect in accountSection(effect, showName: preview.accounts.count > 1) }
                ForEach(Array(preview.irreversibleEffects.enumerated()), id: \.offset) { _, effect in
                    Label(effect.warning, systemImage: "exclamationmark.octagon")
                        .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func scopeText(_ preview: RulePreview) -> String {
        if preview.accounts.isEmpty { return "Rules cover an address in every account. No account here receives mail from this sender." }
        return "Rules cover this address in every account: " + preview.accounts.map(\.accountName).joined(separator: ", ") + "."
    }

    @ViewBuilder private func accountSection(_ effect: RulePreview.AccountEffect, showName: Bool) -> some View {
        switch effect.outcome {
        case .sweeps(let sweep):
            GroupBox(showName ? "\(effect.accountName): would move to \(sweep.destination) (\(sweep.affectedCount))"
                               : "Would move to \(sweep.destination) (\(sweep.affectedCount))") {
                VStack(alignment: .leading, spacing: 4) {
                    if sweep.affected.isEmpty { Text("Nothing would move.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(sweep.affected) { Text($0.subject).font(.callout).lineLimit(1) }
                    if sweep.affectedCount > sweep.affected.count {
                        Text("and \(sweep.affectedCount - sweep.affected.count) more").font(.caption).foregroundStyle(.secondary)
                    }
                    if sweep.markRead { Text("Marked read as it moves.").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if sweep.heldCount > 0 {
                GroupBox("Staying in the inbox (\(sweep.heldCount))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sweep.held) { message in
                            HStack {
                                Text(message.subject).lineLimit(1)
                                Spacer()
                                Text(message.heldReason ?? "").foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                        if sweep.heldCount > sweep.held.count {
                            Text("and \(sweep.heldCount - sweep.held.count) more").font(.caption).foregroundStyle(.secondary)
                        }
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
        GroupBox(showName ? effect.accountName : "Effect") {
            Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save rule") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(preview == nil)
                .accessibilityIdentifier("saveRule")
        }
        .padding(16)
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
