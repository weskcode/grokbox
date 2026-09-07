import SwiftUI
import SwiftData
import GrokboxCore

struct PhoneSendersView: View {
    let account: MailAccount
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query private var profiles: [SenderProfile]
    @Query private var rules: [SenderRule]
    @State private var filter = ""
    @State private var outcome: (sender: String, text: String, url: URL?)?
    @State private var showingOutcome = false

    init(account: MailAccount) {
        self.account = account
        let id = account.id
        _profiles = Query(filter: #Predicate<SenderProfile> { $0.accountID == id }, sort: \SenderProfile.score, order: .reverse)
    }

    private var ruleMap: [String: RuleDecision] { Dictionary(rules.map { ($0.address, $0.decision) }, uniquingKeysWith: { a, _ in a }) }
    private var shown: [SenderProfile] {
        filter.isEmpty ? profiles : profiles.filter { $0.displayName.localizedCaseInsensitiveContains(filter) || $0.address.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        List {
            Section {
                if state.engine.phase.isRunning {
                    PhoneStatusRow(label: state.engine.phase.label, fraction: state.engine.phase.fraction, isRunning: true, isFailed: false,
                                   onStop: { state.engine.cancel() })
                } else {
                    HStack {
                        Button { state.engine.index(account: account, messageLimit: 1_000) } label: { Label("Index last 1,000", systemImage: "arrow.clockwise") }
                            .disabled(state.isBusy)
                        Spacer()
                        if case .failed(let why) = state.engine.phase { Text(why).font(.caption).foregroundStyle(.red).lineLimit(2) }
                        else if profiles.isEmpty { Text("Nothing indexed yet").font(.caption).foregroundStyle(.secondary) }
                        else { Text("\(profiles.count) senders").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            ForEach(shown) { profile in row(profile) }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $filter, prompt: "Filter senders")
        .navigationTitle("Senders")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Unsubscribe", isPresented: $showingOutcome, presenting: outcome) { item in
            if let url = item.url { Button("Open link") { openURL(url) } }
            Button("OK", role: .cancel) { }
        } message: { item in Text(item.text) }
    }

    private func row(_ p: SenderProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(p.displayName.isEmpty ? p.address : p.displayName).font(.headline).lineLimit(1)
                Spacer()
                Text("\(p.messageCount)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: p.category.icon).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(p.category.label).font(.caption).foregroundStyle(.secondary)
                if let rule = ruleMap[p.address] {
                    Image(systemName: rule == .sweep ? "wind" : "pin.fill").font(.caption2).accessibilityLabel("Rule: \(rule.label)")
                }
                Spacer()
                Text(p.verdict.label).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule())
            }
            Text(p.recommendation.label).font(.caption.weight(.semibold)).foregroundStyle(color(for: p.recommendation))
            Text(p.recommendationReason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(p.displayName), \(p.messageCount) messages, \(p.category.label). \(p.recommendation.label). \(p.recommendationReason)")
        .swipeActions(edge: .trailing) {
            Button { RuleStore.set(.sweep, for: p.address, in: modelContext) } label: { Label("Always sweep", systemImage: "wind") }.tint(.orange)
            Button { RuleStore.set(.keep, for: p.address, in: modelContext) } label: { Label("Keep", systemImage: "pin") }.tint(.blue)
        }
        .contextMenu {
            if p.hasUnsubscribeLink {
                Button { Task { await unsubscribe(p) } } label: { Label("Unsubscribe", systemImage: "hand.raised") }
            }
            if ruleMap[p.address] != nil {
                Button("Clear rule") { RuleStore.clear(for: p.address, in: modelContext) }
            }
        }
    }

    private func unsubscribe(_ p: SenderProfile) async {
        let result = await UnsubscribeService.unsubscribe(from: p.assessment.cluster)
        switch result {
        case .unsubscribed: outcome = (p.displayName, "\(p.displayName) acknowledged the request. Mail may still arrive for a few days.", nil)
        case .openInBrowser(let url): outcome = (p.displayName, "This sender has no one-click option. Open their page to finish.", url)
        case .requiresEmail(let mailto): outcome = (p.displayName, "Only an email option exists: \(mailto). Grokbox does not send mail.", nil)
        case .failed(let why): outcome = (p.displayName, why, nil)
        }
        showingOutcome = true
    }

    private func color(for r: Recommendation) -> Color {
        switch r {
        case .unsubscribeAndSweep: .red
        case .fileAutomatically, .muteNotifications: .orange
        case .keep: .green
        case .review: .secondary
        }
    }
}
