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

    @State private var outcome: UnsubscribeService.Outcome?

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
    }

    private var rule: RuleDecision? { rules.first?.decision }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            recommendationCard
            Divider()
            List(messages) { message in messageRow(message) }
        }
        .frame(width: 680, height: 560)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName).font(.title3.weight(.semibold))
                Text(profile.address).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: profile.category.icon)
                    Text(profile.category.label)
                }
                .font(.callout)
                Text("\(profile.messageCount) messages · \(Int(profile.unreadRatio * 100))% unopened · \(profile.pendingCount) in inbox")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(16)
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

            HStack(spacing: 8) {
                if profile.hasUnsubscribeLink {
                    Button(profile.supportsOneClickUnsubscribe ? "Unsubscribe" : "Unsubscribe link") {
                        Task { outcome = await UnsubscribeService.unsubscribe(from: profile.cluster) }
                    }
                    .help(profile.supportsOneClickUnsubscribe ? "One-click (RFC 8058). Tells this sender to stop." : "Opens their unsubscribe page.")
                }
                Button(rule == .sweep ? "Filing automatically ✓" : "File automatically") {
                    RuleStore.set(.sweep, for: profile.address, in: modelContext)
                }
                .disabled(rule == .sweep)
                .help("Future mail from this sender goes straight to \(profile.category.folderName).")
                Button(rule == .keep ? "Keeping ✓" : "Keep in inbox") {
                    RuleStore.set(.keep, for: profile.address, in: modelContext)
                }
                .disabled(rule == .keep)
                if rule != nil {
                    Button("Clear rule") { RuleStore.clear(for: profile.address, in: modelContext) }
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
            if let account, let url = account.webLink(for: message) {
                Button("Open") { openURL(url) }.controlSize(.small)
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
