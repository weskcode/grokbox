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
                Text(policyNotice)
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
                    PhoneStatusRow(label: state.executor.phase.label, fraction: nil, isRunning: true, isFailed: false, onStop: { state.stop() })
                } else if let plan, !plan.isEmpty {
                    Button {
                        let toApply = plan
                        Task { await state.executor.apply(toApply, to: account, policy: state.policy); self.plan = buildPlan() }
                    } label: {
                        Label("\(plan.enabledItems.contains { $0.disposition == .trash } ? "Archive or trash" : "Archive") \(plan.enabledMessageCount.formatted()) messages from \(plan.enabledItems.count) senders", systemImage: "wind")
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
                    Section("\(group.category.label) → \(destination(of: group.items, folder: group.folder))") {
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

    /// The policy's sentence, then what this plan does where a per-sender
    /// setting departs from it: Trash, archive-only, or an unsubscribe the
    /// policy alone would not make.
    private var policyNotice: String {
        let items = plan?.enabledItems ?? []
        let trashed = items.filter { $0.disposition == .trash }.count
        let archived = items.filter { $0.disposition == .archiveOnly }.count
        let unsubscribing = items.filter(\.unsubscribe).count
        let own = items.filter {
            $0.disposition != state.policy.disposition(for: $0.cluster.category)
                || $0.unsubscribe != CleanupPlan.qualifiesForAutoUnsubscribe($0.cluster, policy: state.policy)
                || $0.folder != $0.cluster.category.folderName
        }.count
        var text = state.policy.summary
        if own > 0 {
            text += " \(own) \(own == 1 ? "sender in this plan follows its own setting" : "senders in this plan follow their own settings") instead; the group headings below show where each goes."
        }
        if trashed > 0 {
            text += " In this plan, \(trashed) \(trashed == 1 ? "sender goes" : "senders go") to your provider's Trash. The provider deletes mail for good when it empties the Trash; Undo works only while the mail is still in Trash and that folder is unchanged, and only where the server reported where the mail went."
        }
        if archived > 0 {
            text += " \(archived) \(archived == 1 ? "sender is" : "senders are") archived without a folder."
        }
        if unsubscribing > 0, state.policy.unsubscribe == .never {
            text += " Settings on individual senders still unsubscribe from \(unsubscribing) of them."
        }
        return text
    }

    /// Where a group's mail actually ends up: its folder, or Trash or the
    /// archive for senders whose disposition says so.
    private func destination(of items: [CleanupPlan.Item], folder: String) -> String {
        let enabled = items.filter(\.isEnabled)
        let names = (enabled.isEmpty ? items : enabled).map { item -> String in
            switch item.disposition {
            case .fileIntoFolders: folder
            case .archiveOnly: "Archive"
            case .trash: "Trash"
            }
        }
        return names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
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
