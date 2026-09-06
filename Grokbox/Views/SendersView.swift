import SwiftUI
import SwiftData
import GrokboxCore

struct SendersView: View {
    let account: MailAccount
    let state: AppState

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query private var profiles: [SenderProfile]
    @Query private var rules: [SenderRule]

    @State private var verdictFilter: Verdict?
    @State private var searchText = ""
    @State private var messageLimit = 5_000
    @State private var sortOrder = [KeyPathComparator(\SenderAssessment.score, order: .reverse)]
    @State private var drillDown: SenderProfile?
    @State private var categoryFilter: SenderCategory?
    @State private var unsubscribeOutcome: (sender: String, outcome: UnsubscribeService.Outcome)?
    @State private var showingOutcome = false

    init(account: MailAccount, state: AppState) {
        self.account = account
        self.state = state
        let id = account.id
        _profiles = Query(filter: #Predicate<SenderProfile> { $0.accountID == id })
    }

    private var ruleMap: [String: RuleDecision] {
        Dictionary(rules.map { ($0.address, $0.decision) }, uniquingKeysWith: { a, _ in a })
    }

    /// Precomputed by the engine at index time; a few hundred rows, not 40,000 messages.
    private var assessments: [SenderAssessment] { profiles.map(\.assessment) }

    private var profileByAddress: [String: SenderProfile] {
        Dictionary(profiles.map { ($0.address, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var visible: [SenderAssessment] {
        assessments.filter { assessment in
            if let verdictFilter, assessment.verdict != verdictFilter { return false }
            if let categoryFilter, assessment.cluster.category != categoryFilter { return false }
            guard !searchText.isEmpty else { return true }
            return assessment.cluster.address.localizedCaseInsensitiveContains(searchText)
                || assessment.cluster.displayName.localizedCaseInsensitiveContains(searchText)
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            indexBar
            Divider()
            if assessments.isEmpty {
                ContentUnavailableView("Nothing indexed yet", systemImage: "envelope.badge.person.crop",
                                       description: Text("Press Index to see who is actually filling this mailbox."))
            } else {
                summaryStrip
                Divider()
                categoryStrip
                Divider()
                table
            }
        }
        .navigationTitle(account.displayName)
        .searchable(text: $searchText, prompt: "Filter senders")
        .sheet(item: $drillDown) { profile in
            SenderMessagesSheet(profile: profile, account: account, state: state)
        }
        .alert("Unsubscribe", isPresented: $showingOutcome, presenting: unsubscribeOutcome) { item in
            if case .openInBrowser(let url) = item.outcome {
                Button("Open link") { openURL(url) }
            }
            Button("OK", role: .cancel) { }
        } message: { item in
            Text(describe(item.outcome, sender: item.sender))
        }
    }

    private var indexBar: some View {
        HStack(spacing: 12) {
            if state.engine.phase.isRunning {
                EngineStatusBar(label: state.engine.phase.label, fraction: state.engine.phase.fraction,
                                isRunning: true, isFailed: false, onStop: { state.engine.cancel() })
            } else {
                Button {
                    state.engine.index(account: account, messageLimit: messageLimit)
                } label: {
                    Label("Index", systemImage: "arrow.clockwise")
                }
                .disabled(state.isBusy)
                .accessibilityIdentifier("indexButton")

                Picker("Depth", selection: $messageLimit) {
                    Text("Last 1,000").tag(1_000)
                    Text("Last 5,000").tag(5_000)
                    Text("Last 25,000").tag(25_000)
                    Text("Everything").tag(1_000_000)
                }
                .labelsHidden().frame(width: 130)

                EngineStatusBar(label: state.engine.phase.label, fraction: nil, isRunning: false,
                                isFailed: { if case .failed = state.engine.phase { true } else { false } }())
            }
            Label("Index is read-only", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
                .help("Indexing opens mailboxes with IMAP EXAMINE, which the server enforces as read-only.")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var summaryStrip: some View {
        HStack(spacing: 0) {
            ForEach(Verdict.allCases, id: \.self) { verdict in
                let matching = assessments.filter { $0.verdict == verdict }
                let count = matching.reduce(0) { $0 + $1.cluster.messageCount }
                Button {
                    verdictFilter = (verdictFilter == verdict) ? nil : verdict
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verdict.label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(count.formatted()).font(.title2.monospacedDigit())
                        Text("\(matching.count) senders").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(verdictFilter == verdict ? Color.accentColor.opacity(0.12) : .clear)
                }
                .buttonStyle(.plain)
                .help(verdict.explanation)
            }
        }
    }

    /// What kinds of mail fill this mailbox — and the folder each kind goes to.
    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SenderCategory.allCases, id: \.self) { category in
                    let matching = profiles.filter { $0.category == category }
                    if !matching.isEmpty {
                        let messages = matching.reduce(0) { $0 + $1.messageCount }
                        Button {
                            categoryFilter = (categoryFilter == category) ? nil : category
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: category.icon).font(.caption)
                                Text(category.label).font(.caption.weight(.medium))
                                Text("\(matching.count) · \(messages.formatted())").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(categoryFilter == category ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("\(matching.count) senders, \(messages) messages → \(category.folderName)")
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private var table: some View {
        Table(visible, sortOrder: $sortOrder) {
            TableColumn("Sender", value: \.cluster.displayName) { a in
                Button {
                    drillDown = profileByAddress[a.cluster.address]
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.cluster.displayName).lineLimit(1)
                        Text(a.cluster.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show this sender's messages")
            }
            .width(min: 200, ideal: 260)

            TableColumn("Msgs", value: \.cluster.messageCount) { a in
                Text(a.cluster.messageCount.formatted()).monospacedDigit()
            }
            .width(60)

            TableColumn("Inbox", value: \.cluster.uids.count) { a in
                Text(a.cluster.pendingUIDs.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(55)

            TableColumn("Unread", value: \.cluster.unreadRatio) { a in
                Text("\(Int(a.cluster.unreadRatio * 100))%").monospacedDigit()
            }
            .width(60)

            TableColumn("Type", value: \.cluster.category.rawValue) { a in
                let profile = profileByAddress[a.cluster.address]
                HStack(spacing: 4) {
                    Image(systemName: a.cluster.category.icon).font(.caption).foregroundStyle(.secondary)
                    Text(a.cluster.category.label).font(.caption)
                    if profile?.categoryFromModel == true {
                        Image(systemName: "sparkle").font(.caption2).foregroundStyle(.secondary).help("Placed by the local model")
                    }
                }
                .help(profile?.categoryEvidence ?? "")
            }
            .width(120)

            TableColumn("What to do", value: \.cluster.address) { a in
                if let profile = profileByAddress[a.cluster.address] {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.recommendation.label).font(.caption.weight(.semibold))
                            .foregroundStyle(color(for: profile.recommendation))
                        Text(profile.recommendationReason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(profile.recommendationReason)
                }
            }
            .width(min: 150, ideal: 190)

            TableColumn("Verdict", value: \.score) { a in
                HStack(spacing: 4) {
                    Text(a.verdict.label)
                    if let rule = ruleMap[a.cluster.address] {
                        Image(systemName: rule == .sweep ? "wind" : "pin.fill")
                            .font(.caption2)
                            .help(rule.label)
                    }
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            }
            .width(90)

            TableColumn("Why") { a in
                Text(a.reasons.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(a.reasons.joined(separator: "\n"))
            }
            .width(min: 160, ideal: 240)

            TableColumn("") { a in
                HStack(spacing: 6) {
                    Menu {
                        Button("Always sweep") { RuleStore.set(.sweep, for: a.cluster.address, in: modelContext) }
                        Button("Always keep") { RuleStore.set(.keep, for: a.cluster.address, in: modelContext) }
                        if ruleMap[a.cluster.address] != nil {
                            Divider()
                            Button("Clear rule") { RuleStore.clear(for: a.cluster.address, in: modelContext) }
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .menuStyle(.borderlessButton).frame(width: 28)

                    if a.cluster.hasUnsubscribeLink {
                        Button(a.cluster.supportsOneClickUnsubscribe ? "Unsubscribe" : "Unsub link") {
                            Task {
                                let outcome = await UnsubscribeService.unsubscribe(from: a.cluster)
                                unsubscribeOutcome = (a.cluster.displayName, outcome)
                                showingOutcome = true
                            }
                        }
                        .controlSize(.small)
                        .help(a.cluster.supportsOneClickUnsubscribe
                              ? "Sends a one-click unsubscribe (RFC 8058) to this sender's server."
                              : "Opens the sender's unsubscribe page in your browser.")
                    }
                }
            }
            .width(170)
        }
        .tableStyle(.inset)
        .accessibilityIdentifier("sendersTable")
    }

    private func color(for recommendation: Recommendation) -> Color {
        switch recommendation {
        case .unsubscribeAndSweep: .red
        case .muteNotifications: .orange
        case .fileAutomatically: .blue
        case .keep: .green
        case .review: .secondary
        }
    }

    private func describe(_ outcome: UnsubscribeService.Outcome, sender: String) -> String {
        switch outcome {
        case .unsubscribed: "\(sender) acknowledged the unsubscribe. Their mail may take a few days to stop."
        case .openInBrowser: "\(sender) does not support one-click unsubscribe. Open their page to finish."
        case .requiresEmail(let mailto): "\(sender) only offers unsubscribe by email (\(mailto)). Grokbox does not send mail — do it from your mail app."
        case .failed(let message): "Could not unsubscribe from \(sender): \(message)"
        }
    }
}
