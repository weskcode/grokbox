import SwiftUI
import SwiftData
import GrokboxCore

struct PhoneSweepView: View {
    let account: MailAccount
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var modelContext
    @Query private var rules: [SenderRule]
    @State private var plan: CleanupPlan?

    var body: some View {
        List {
            Section {
                Text("Each sender is filed into the folder for its kind — never a generic bin. Flagged mail, mail the model says needs you, and receipts are held back. Nothing is deleted; every action can be undone from Activity.")
                    .font(.footnote).foregroundStyle(.secondary)
                if state.executor.phase.isRunning {
                    PhoneStatusRow(label: state.executor.phase.label, fraction: nil, isRunning: true, isFailed: false, onStop: { state.executor.cancel() })
                } else if let plan, !plan.isEmpty {
                    Button {
                        let toApply = plan
                        Task { await state.executor.apply(toApply, to: account); self.plan = buildPlan() }
                    } label: {
                        Label("Archive \(plan.enabledMessageCount.formatted()) messages from \(plan.enabledItems.count) senders", systemImage: "wind")
                    }
                    .buttonStyle(.borderedProminent).disabled(state.isBusy)
                } else {
                    Text(plan == nil ? "Building the plan…" : "Nothing to sweep. Index in Senders first, or everything is already tidy.").foregroundStyle(.secondary)
                }
                if case .finished(let note) = state.executor.phase { Text(note).font(.caption).foregroundStyle(.secondary) }
                if case .failed(let why) = state.executor.phase { Text(why).font(.caption).foregroundStyle(.red) }
            }
            if let plan {
                ForEach(plan.byFolder, id: \.folder) { group in
                    Section("\(group.category.label) → \(group.folder)") {
                        ForEach(group.items) { item in
                            Toggle(isOn: binding(for: item.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack { Text(item.cluster.displayName).font(.headline); if item.isFromRule { Text("rule").font(.caption2).padding(.horizontal, 5).background(.quaternary, in: Capsule()) } }
                                    Text("\(item.messageCount) messages · \(item.cluster.address)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sweep")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: account.id) { plan = buildPlan() }
        .refreshable { plan = buildPlan() }
    }

    private func buildPlan() -> CleanupPlan {
        let assessed = SenderProfileBuilder.assessments(for: account, in: modelContext)
        let ruleMap = Dictionary(rules.map { ($0.address, $0.decision) }, uniquingKeysWith: { a, _ in a })
        return CleanupPlan.suggested(from: assessed, rules: ruleMap)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { plan?.items.first { $0.id == id }?.isEnabled ?? false },
                set: { on in guard var current = plan, let i = current.items.firstIndex(where: { $0.id == id }) else { return }
                       current.items[i].isEnabled = on; plan = current })
    }
}
