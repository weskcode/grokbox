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
        var plan = CleanupPlan.suggested(from: assessed, rules: ruleMap, policy: state.policy,
                                         overrides: RuleStore.overrides(in: modelContext))
        GuardPreview.apply(to: &plan, policy: state.policy, account: account, in: modelContext)
        return plan
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
        .onChange(of: state.policy) { plan = buildPlan() }
        .sheet(item: $drillDown) { profile in
            SenderMessagesSheet(profile: profile, account: account, state: state)
        }
    }

    /// Gmail archives by label, which Grokbox can always put back. Other
    /// servers move mail, and a move can only be undone if the server says
    /// where the messages went.
    private var undoPromise: String {
        switch account.kind {
        case .gmail, .demo: "Every change to your mail is listed in Activity, with Undo while the mailbox is unchanged."
        default: "Every change to your mail is listed in Activity, with Undo wherever this server reports where the mail went."
        }
    }

    /// What this plan will do, in the words of the choices behind it: folders,
    /// archive, Trash and unsubscribe are each named only when an enabled
    /// sender actually gets them.
    private func approvalNotice(for plan: CleanupPlan?) -> String {
        let items = plan?.enabledItems ?? []
        let trashed = items.filter { $0.disposition == .trash }.count
        let unsubscribing = items.filter(\.unsubscribe).count
        var sentences: [String] = []
        if items.isEmpty || items.contains(where: { $0.disposition == .fileIntoFolders }) {
            sentences.append("Senders set to be filed go into the folder for their kind — Promotions, Newsletters, Notifications — or the folder you chose for that sender, never a generic bin.")
        }
        if items.contains(where: { $0.disposition == .archiveOnly }) {
            sentences.append("Senders set to archive leave the inbox without a folder.")
        }
        if trashed > 0 {
            sentences.append("\(trashed) \(trashed == 1 ? "sender goes" : "senders go") to your provider's Trash. The provider deletes mail for good when it empties the Trash; Undo works until then, where the server reported where the mail went.")
        }
        sentences.append(state.policy.guardTransactional
                         ? "Flagged mail, mail the model says needs you, and mail that looks like a receipt or security notice (judged from its subject) are held back automatically."
                         : "Flagged mail and mail the model says needs you are held back automatically.")
        if markRead { sentences.append("Swept mail is also marked read.") }
        if trashed == 0 { sentences.append("Nothing is deleted.") }
        sentences.append(undoPromise)
        if unsubscribing > 0 {
            sentences.append("Once their mail is swept, Grokbox will also unsubscribe from \(unsubscribing) \(unsubscribing == 1 ? "sender" : "senders") through their own one-click link. That cannot be undone.")
        }
        sentences.append("Approving a sender writes a rule, so later tidy-ups handle that sender's new mail without asking, under the policy in force then.")
        return sentences.joined(separator: " ")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // The controls stay mounted and are disabled while a sweep
                // runs, rather than swapped out, so VoiceOver focus survives
                // pressing Archive (GB-037).
                if let plan {
                    Button {
                        var toApply = plan
                        toApply.items = toApply.items.map { var i = $0; i.markRead = markRead; return i }
                        Task {
                            await state.executor.apply(toApply, to: account, policy: state.policy)
                            self.plan = buildPlan()
                        }
                    } label: {
                        Label("Archive \(plan.enabledMessageCount.formatted()) messages from \(plan.enabledItems.count) senders", systemImage: "wind")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(plan.isEmpty || state.isBusy)
                    .accessibilityIdentifier("applySweep")

                    Toggle("Also mark read", isOn: $markRead)

                    Button("All") { setAll(true) }.controlSize(.small).disabled(state.isBusy)
                    Button("None") { setAll(false) }.controlSize(.small).disabled(state.isBusy)
                    Button("Refresh") { self.plan = buildPlan() }.disabled(state.isBusy)

                    EngineStatusBar(label: state.executor.phase.label, fraction: nil, isRunning: state.executor.phase.isRunning,
                                    isFailed: { if case .failed = state.executor.phase { true } else { false } }(),
                                    onStop: { state.stop() })
                } else if state.executor.phase.isRunning {
                    EngineStatusBar(label: state.executor.phase.label, fraction: nil, isRunning: true, isFailed: false,
                                    onStop: { state.stop() })
                }
            }
            Text(approvalNotice(for: plan))
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
                        Text("→ \(destination(of: group.items, folder: group.folder))").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(group.items.count) senders · \(group.items.reduce(0) { $0 + $1.messageCount }.formatted()) messages")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
            }
        }
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

    private func itemRow(_ item: CleanupPlan.Item) -> some View {
        Group {
                HStack(spacing: 12) {
                    // The label is hidden on screen but is what VoiceOver
                    // reads: this checkbox is the consent for a bulk move (GB-006).
                    Toggle("Include \(item.cluster.displayName)", isOn: binding(for: item.id))
                        .labelsHidden()
                        .accessibilityValue(item.isEnabled ? (item.disposition == .trash ? "Will be moved to Trash" : "Will be archived") : "Excluded")
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
                    .accessibilityLabel("Always keep \(item.cluster.displayName)")
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
