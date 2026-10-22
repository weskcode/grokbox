import SwiftUI
import SwiftData
import GrokboxCore

/// One sender, in full: what they are, what to do about them, and the messages
/// behind the row. The recommendation is the point; the list is the evidence.
struct SenderMessagesSheet: View {
    let profile: SenderProfile
    let account: MailAccount?
    let state: AppState

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @Query private var messages: [MessageHeader]
    @Query private var rules: [SenderRule]
    @Query private var sameAddress: [SenderProfile]
    @Query private var accounts: [MailAccount]

    @State private var coverage: IndexCoverage?
    @State private var sweepNow: SweepNowText?
    @State private var evidenceUnavailable = false
    @State private var outcome: UnsubscribeService.Outcome?
    @State private var ruleError: String?
    @State private var pendingRule: PendingRuleEdit?
    @State private var searchText = ""
    @State private var reading: MessageHeader?

    init(profile: SenderProfile, account: MailAccount?, state: AppState) {
        self.profile = profile
        self.account = account
        self.state = state
        let address = profile.address
        if let id = account?.id {
            _messages = Query(filter: #Predicate<MessageHeader> { $0.accountID == id && $0.senderAddress == address },
                              sort: \MessageHeader.receivedAt, order: .reverse)
        } else {
            _messages = Query(filter: #Predicate<MessageHeader> { $0.senderAddress == address },
                              sort: \MessageHeader.receivedAt, order: .reverse)
        }
        _rules = Query(filter: #Predicate<SenderRule> { $0.address == address })
        _sameAddress = Query(filter: #Predicate<SenderProfile> { $0.address == address })
    }

    private var rule: RuleDecision? { rules.first?.decision }

    private var evidence: SenderEvidence { SenderEvidence(profile: profile, rule: rules.first, allProfiles: sameAddress) }

    /// Subject/summary only — the sender is already fixed by this sheet.
    /// A plain `TextField`, not `.searchable`: this view has no
    /// `NavigationStack` when presented as a sheet, and `.searchable` is not
    /// guaranteed to render without one.
    private var shownMessages: [MessageHeader] {
        guard !searchText.isEmpty else { return messages }
        return messages.filter { message in
            message.subject.localizedCaseInsensitiveContains(searchText)
                || (message.summary?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    evidenceBlock
                    Divider()
                    recommendationCard
                }
            }
            .frame(maxHeight: 330)
            Divider()
            TextField("Search this sender's messages", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            List(shownMessages) { message in messageRow(message) }
        }
        .frame(width: 680, height: 560)
        .sheet(item: $reading) { message in
            if let account {
                MessageReaderSheet(message: message, account: account)
            }
        }
        .ruleSaveAlert($ruleError)
        .ruleEditSheet($pendingRule, policy: state.policy, errorMessage: $ruleError)
        .task(id: EvidenceKey(messages: messages.count, inInbox: profile.pendingCount,
                              indexedAt: profile.updatedAt, rule: rules.first.map(SenderOverride.init(rule:)), policy: state.policy)) { loadEvidence() }
    }

    private struct EvidenceKey: Equatable {
        var messages: Int
        var inInbox: Int
        var indexedAt: Date
        var rule: SenderOverride?
        var policy: CleanupPolicy
    }

    private func loadEvidence() {
        guard let account else { return }
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

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName).font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader).accessibilityHeading(.h1)
                Text(profile.address).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: profile.category.icon)
                    Text(profile.category.label)
                }
                .font(.callout)
                Text("\(profile.messageCount) indexed ·\(Int(profile.unreadRatio * 100))% unopened · \(profile.pendingCount) in inbox")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var evidenceBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let coverage {
                Text(coverage.caption()).font(.caption).foregroundStyle(.secondary)
            } else if evidenceUnavailable {
                Text("Couldn't read the index, so coverage and the sweep preview are unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 28) {
                stat(evidence.indexed, "indexed from this sender")
                stat(evidence.inInbox, "in inbox now")
                stat(evidence.outOfInbox, "already out of the inbox")
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func stat(_ count: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(count.formatted()).font(.title3.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count.formatted()) \(label)")
    }

    private var sweepNowBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("If you sweep now").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let sweepNow {
                Text(sweepNow.moves).font(.callout)
                if let held = sweepNow.held {
                    Text(held).font(.callout)
                    ForEach(sweepNow.heldDetails, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            } else if evidenceUnavailable {
                Text("Couldn't work out what a sweep would do.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var lastSweepBlock: some View {
        let text = LastSweepText(report: state.executor.lastReport, address: profile.address,
                                 mailbox: profile.cluster.mailbox, accountID: profile.accountID)
        return VStack(alignment: .leading, spacing: 4) {
            Text(LastSweepText.heading).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if text.counts.isEmpty {
                if let note = text.note { Text(note).font(.callout).foregroundStyle(.secondary) }
            } else {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(text.counts, id: \.label) { count in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(count.value.formatted()).font(.title3.monospacedDigit())
                            Text(count.label).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(count.value.formatted()) \(count.label)")
                    }
                }
                if let note = text.note { Text(note).font(.callout) }
                if text.counts.last?.value ?? 0 > 0 { Text(LastSweepText.unknownMeaning).font(.caption).foregroundStyle(.secondary) }
            }
            Text(LastSweepText.footnote).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var recommendationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(profile.recommendation.verb).font(.headline)
                Text("— \(profile.recommendation.label.lowercased())").font(.callout).foregroundStyle(.secondary)
            }
            Text(profile.recommendationReason).font(.callout)
            Text("Type: \(profile.categoryEvidence.isEmpty ? profile.category.label : profile.categoryEvidence). Swept mail goes to \(profile.category.folderName).")
                .font(.caption).foregroundStyle(.secondary)
            if account != nil { sweepNowBlock }
            lastSweepBlock
            Text(evidence.scope(accountNames: Dictionary(accounts.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })))
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if profile.hasUnsubscribeLink {
                    Button(profile.supportsOneClickUnsubscribe ? "Unsubscribe" : "Unsubscribe link") {
                        Task { outcome = await UnsubscribeService.unsubscribe(from: profile.cluster) }
                    }
                    .help(profile.supportsOneClickUnsubscribe ? "One-click (RFC 8058). Tells this sender to stop." : "Opens their unsubscribe page.")
                }
                Button(rule == .sweep ? "Filing automatically ✓" : "File automatically") {
                    pendingRule = PendingRuleEdit(address: profile.address, senderName: profile.displayName, edit: .decision(.sweep))
                }
                .disabled(rule == .sweep)
                .help("Future mail from this sender goes straight to \(profile.category.folderName).")
                Button(rule == .keep ? "Keeping ✓" : "Keep in inbox") {
                    pendingRule = PendingRuleEdit(address: profile.address, senderName: profile.displayName, edit: .decision(.keep))
                }
                .disabled(rule == .keep)
                if rule != nil {
                    Button("Clear rule") { pendingRule = PendingRuleEdit(address: profile.address, senderName: profile.displayName, edit: .clear) }
                }
                Spacer()
                if let outcome {
                    Text(describe(outcome)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if case .openInBrowser(let url) = outcome { Button("Open") { openURL(url) }.controlSize(.small) }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35))
    }

    private func messageRow(_ message: MessageHeader) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(message.isUnread ? Color.accentColor : .clear).frame(width: 7, height: 7).padding(.top, 6)
                .accessibilityLabel(message.isUnread ? "Unread" : "Read")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(message.subject).font(.body).lineLimit(1)
                    if message.isFlagged { Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange).accessibilityLabel("Flagged") }
                    if message.isSweptLocally || !message.isInInbox {
                        Text("archived").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                    }
                    if SweepGuard.looksTransactional(message.subject) {
                        Text("record").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                            .help("Looks like a receipt or record; the sweep guard would hold it.")
                    }
                }
                if let summary = message.summary { Text(summary).font(.callout).foregroundStyle(.secondary) }
                HStack(spacing: 6) {
                    Text(message.receivedAt, format: .dateTime.month(.abbreviated).day().year())
                    if let importance = message.importance { Text("·"); Text(importance.label) }
                }
                .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            HStack(spacing: 6) {
                if account != nil {
                    Button("Read") { reading = message }.controlSize(.small)
                }
                if let account, let url = account.webLink(for: message) {
                    Button("Open") { openURL(url) }.controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func describe(_ outcome: UnsubscribeService.Outcome) -> String {
        switch outcome {
        case .unsubscribed: "Unsubscribed. Their mail may take a few days to stop."
        case .openInBrowser: "No one-click support — open their page to finish."
        case .requiresEmail(let mailto): "Only by email (\(mailto)). Grokbox does not send mail."
        case .failed(let message): "Could not unsubscribe: \(message)"
        }
    }
}
