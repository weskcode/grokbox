import SwiftUI
import SwiftData
import GrokboxCore

/// Review what Grokbox proposes to archive, then apply it in one go.
struct SweepView: View {
    let account: MailAccount
    let state: AppState

    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [SenderProfile]
    @Query private var rules: [SenderRule]

    @State private var plan: CleanupPlan?
    @State private var markRead = true
    @State private var drillDown: SenderProfile?

    init(account: MailAccount, state: AppState) {
        self.account = account
        self.state = state
        let id = account.id
        _profiles = Query(filter: #Predicate<SenderProfile> { $0.accountID == id })
    }

    private func buildPlan() -> CleanupPlan {
        let ruleMap = Dictionary(rules.map { ($0.address, $0.decision) }, uniquingKeysWith: { a, _ in a })
        let assessed = profiles.map(\.assessment).sorted { $0.score > $1.score }
        return CleanupPlan.suggested(from: assessed, rules: ruleMap)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let plan, !plan.items.isEmpty {
                list(plan)
            } else {
                ContentUnavailableView("Nothing to sweep", systemImage: "checkmark.circle",
                                       description: Text(profiles.isEmpty ? "Index the mailbox first." : "No bulk senders with unswept mail. The inbox is clean."))
            }
        }
        .navigationTitle("Sweep · \(account.displayName)")
        .onAppear { if plan == nil { plan = buildPlan() } }
        .onChange(of: profiles.map(\.updatedAt)) { plan = buildPlan() }
        .onChange(of: rules.count) { plan = buildPlan() }
        .sheet(item: $drillDown) { profile in
            SenderMessagesSheet(profile: profile, account: account, state: state)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if state.executor.phase.isRunning {
                    EngineStatusBar(label: state.executor.phase.label, fraction: nil, isRunning: true, isFailed: false)
                } else if let plan {
                    Button {
                        var toApply = plan
                        toApply.items = toApply.items.map { var i = $0; i.markRead = markRead; return i }
                        Task {
                            await state.executor.apply(toApply, to: account)
                            self.plan = buildPlan()
                        }
                    } label: {
                        Label("Archive \(plan.enabledMessageCount.formatted()) messages from \(plan.enabledItems.count) senders", systemImage: "wind")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(plan.isEmpty || state.isBusy)
                    .accessibilityIdentifier("applySweep")

                    Toggle("Also mark read", isOn: $markRead)

                    Button("All") { setAll(true) }.controlSize(.small)
                    Button("None") { setAll(false) }.controlSize(.small)
                    Button("Refresh") { self.plan = buildPlan() }.disabled(state.isBusy)

                    EngineStatusBar(label: state.executor.phase.label, fraction: nil, isRunning: false,
                                    isFailed: { if case .failed = state.executor.phase { true } else { false } }())
                }
            }
            Text("Each sender is filed into the folder for its kind — Promotions, Newsletters, Notifications — never a generic bin. Flagged mail, mail the model says needs you, and receipts are held back automatically. Nothing is deleted; every action can be undone from Activity. Approving a sender writes a rule so future mail is filed the same way.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func list(_ plan: CleanupPlan) -> some View {
        List {
            ForEach(plan.byFolder, id: \.folder) { group in
                Section {
                    ForEach(group.items) { item in
                        itemRow(item)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: group.category.icon).accessibilityHidden(true)
                        Text(group.category.label)
                        Text("→ \(group.folder)").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(group.items.count) senders · \(group.items.reduce(0) { $0 + $1.messageCount }.formatted()) messages")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func itemRow(_ item: CleanupPlan.Item) -> some View {
        Group {
                HStack(spacing: 12) {
                    Toggle("", isOn: binding(for: item.id)).labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Button(item.cluster.displayName) { drillDown = profiles.first { $0.address == item.cluster.address } }
                                .buttonStyle(.plain).font(.headline)
                                .help("Show this sender's messages")
                            if item.isFromRule {
                                Text("rule").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                                    .help("You approved this sender before.")
                            }
                        }
                        Text(item.cluster.address).font(.caption).foregroundStyle(.secondary)
                        if let subject = item.cluster.sampleSubjects.first {
                            Text("Latest: \(subject)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(item.messageCount.formatted())").font(.title3.monospacedDigit())
                        Text("\(Int(item.cluster.unreadRatio * 100))% unread").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Keep") {
                        RuleStore.set(.keep, for: item.cluster.address, in: modelContext)
                    }
                    .controlSize(.small)
                    .help("Never suggest sweeping this sender.")
                }
                .padding(.vertical, 4)
                .opacity(item.isEnabled ? 1 : 0.45)
        }
    }

    private func setAll(_ enabled: Bool) {
        guard var current = plan else { return }
        current.items = current.items.map { var i = $0; i.isEnabled = enabled; return i }
        plan = current
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { plan?.items.first { $0.id == id }?.isEnabled ?? false },
            set: { newValue in
                guard var current = plan, let index = current.items.firstIndex(where: { $0.id == id }) else { return }
                current.items[index].isEnabled = newValue
                plan = current
            }
        )
    }
}
