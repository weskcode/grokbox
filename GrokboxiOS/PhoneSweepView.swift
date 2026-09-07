import SwiftUI
import SwiftData
import GrokboxCore

struct PhoneSweepView: View {
    let account: MailAccount
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var modelContext
    @Query private var rules: [SenderRule]
    /// Observed so the plan rebuilds when an index or a sweep changes the
    /// profiles underneath it — a plan built before indexing finished is
    /// empty, and staying empty is worse than being wrong.
    @Query private var profiles: [SenderProfile]
    @State private var plan: CleanupPlan?

    init(account: MailAccount) {
        self.account = account
        let id = account.id
        _profiles = Query(filter: #Predicate<SenderProfile> { $0.accountID == id })
    }

    var body: some View {
        List {
            Section {
                Text(state.policy.summary)
                    .font(.footnote).foregroundStyle(.secondary)
                if let plan, plan.heldMessageCount > 0 {
                    Label("Holding back \(plan.heldMessageCount.formatted()) message\(plan.heldMessageCount == 1 ? "" : "s") under this policy.", systemImage: "hand.raised")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let plan, !plan.autoUnsubscribeItems.isEmpty {
                    Label("Will also unsubscribe from \(plan.autoUnsubscribeItems.count) sender\(plan.autoUnsubscribeItems.count == 1 ? "" : "s"). That cannot be undone.",
                          systemImage: "hand.raised")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if state.executor.phase.isRunning {
                    PhoneStatusRow(label: state.executor.phase.label, fraction: nil, isRunning: true, isFailed: false, onStop: { state.executor.cancel() })
                } else if let plan, !plan.isEmpty {
                    Button {
                        let toApply = plan
                        Task { await state.executor.apply(toApply, to: account, policy: state.policy); self.plan = buildPlan() }
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
        .onChange(of: state.policy) { plan = buildPlan() }
        .onChange(of: profiles.map(\.updatedAt)) { plan = buildPlan() }
        .onChange(of: rules.count) { plan = buildPlan() }
        .refreshable { plan = buildPlan() }
    }

    private func buildPlan() -> CleanupPlan {
        let assessed = SenderProfileBuilder.assessments(for: account, in: modelContext)
        let ruleMap = Dictionary(rules.map { ($0.address, $0.decision) }, uniquingKeysWith: { a, _ in a })
        var plan = CleanupPlan.suggested(from: assessed, rules: ruleMap, policy: state.policy,
                                         overrides: RuleStore.overrides(in: modelContext))
        GuardPreview.apply(to: &plan, policy: state.policy, account: account, in: modelContext)
        return plan
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { plan?.items.first { $0.id == id }?.isEnabled ?? false },
                set: { on in guard var current = plan, let i = current.items.firstIndex(where: { $0.id == id }) else { return }
                       current.items[i].isEnabled = on; plan = current })
    }
}
