import SwiftUI
import SwiftData
import GrokboxCore

/// One sender on the phone: what the index holds, what a sweep would do to it
/// now, and how far a rule reaches.
struct PhoneSenderDetailView: View {
    let profile: SenderProfile
    let account: MailAccount

    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var modelContext
    @Query private var rules: [SenderRule]
    @Query private var sameAddress: [SenderProfile]
    @Query private var accounts: [MailAccount]

    @State private var coverage: IndexCoverage?
    @State private var sweepNow: SweepNowText?
    @State private var evidenceUnavailable = false

    init(profile: SenderProfile, account: MailAccount) {
        self.profile = profile
        self.account = account
        let address = profile.address
        _rules = Query(filter: #Predicate<SenderRule> { $0.address == address })
        _sameAddress = Query(filter: #Predicate<SenderProfile> { $0.address == address })
    }

    private var evidence: SenderEvidence { SenderEvidence(profile: profile, rule: rules.first, allProfiles: sameAddress) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.displayName.isEmpty ? profile.address : profile.displayName).font(.headline)
                    Text(profile.address).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: profile.category.icon).accessibilityHidden(true)
                        Text(profile.category.label)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                if let coverage {
                    Text(coverage.caption()).font(.caption).foregroundStyle(.secondary)
                } else if evidenceUnavailable {
                    Text("Couldn't read the index, so coverage and the sweep preview are unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("In the index") {
                row("Indexed from this sender", evidence.indexed)
                row("In inbox now", evidence.inInbox)
                row("Already out of the inbox", evidence.outOfInbox)
                row("Unread", evidence.unread)
            }
            Section("Why Grokbox suggests it") {
                Text(profile.recommendation.label).font(.subheadline.weight(.semibold))
                Text(profile.recommendationReason).font(.callout)
                Text(profile.categoryEvidence.isEmpty ? profile.category.label : profile.categoryEvidence)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("If you sweep now") {
                if let sweepNow {
                    Text(sweepNow.moves)
                    if let held = sweepNow.held {
                        Text(held)
                        ForEach(sweepNow.heldDetails, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                } else if evidenceUnavailable {
                    Text("Couldn't work out what a sweep would do.").foregroundStyle(.secondary)
                }
            }
            lastSweepSection
            Section("Rule scope") {
                Text(evidence.scope(accountNames: Dictionary(accounts.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })))
            }
        }
        .navigationTitle(profile.displayName.isEmpty ? profile.address : profile.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: EvidenceKey(profiles: sameAddress.count, messages: profile.messageCount, inInbox: profile.pendingCount,
                              indexedAt: profile.updatedAt, rule: rules.first.map(SenderOverride.init(rule:)), policy: state.policy)) { load() }
    }

    private func row(_ label: String, _ count: Int) -> some View {
        LabeledContent(label) { Text(count.formatted()).monospacedDigit() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(count.formatted()) \(label.lowercased())")
    }

    @ViewBuilder private var lastSweepSection: some View {
        let text = LastSweepText(report: state.executor.lastReport, address: profile.address,
                                 mailbox: profile.cluster.mailbox, sharedAcrossAccounts: !evidence.otherAccounts.isEmpty,
                                 knownUIDs: Set(profile.cluster.uids))
        Section {
            if text.counts.isEmpty {
                if let note = text.note { Text(note).foregroundStyle(.secondary) }
            } else {
                ForEach(text.counts, id: \.label) { count in row(count.label.prefix(1).uppercased() + count.label.dropFirst(), count.value) }
                if let note = text.note { Text(note) }
                if text.counts.last?.value ?? 0 > 0 { Text(LastSweepText.unknownMeaning).font(.caption).foregroundStyle(.secondary) }
            }
        } header: {
            Text(LastSweepText.heading)
        } footer: {
            Text(LastSweepText.footnote)
        }
    }

    private struct EvidenceKey: Equatable {
        var profiles: Int
        var messages: Int
        var inInbox: Int
        var indexedAt: Date
        var rule: SenderOverride?
        var policy: CleanupPolicy
    }

    private func load() {
        do {
            coverage = try IndexCoverage.current(for: account, in: modelContext)
            let outcome = try SenderEvidence.sweepNow(address: profile.address, accountID: account.id, rule: rules.first,
                                                      policy: state.policy, in: modelContext)
            sweepNow = outcome.map(SweepNowText.init)
            evidenceUnavailable = false
        } catch {
            coverage = nil
            sweepNow = nil
            evidenceUnavailable = true
        }
    }
}
