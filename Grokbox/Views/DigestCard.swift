import SwiftUI
import SwiftData
import GrokboxCore

/// "Where do I stand?" — one button, instant answer, kept as a dated snapshot.
struct DigestCard: View {
    let accounts: [MailAccount]
    let state: AppState

    @Environment(\.modelContext) private var modelContext
    @Query private var digests: [InboxDigest]
    @State private var showHistory = false
    @State private var copied = false

    private var scopeKey: String { accounts.count == 1 ? accounts[0].id.uuidString : "all" }

    init(accounts: [MailAccount], state: AppState) {
        self.accounts = accounts
        self.state = state
        let key = accounts.count == 1 ? accounts[0].id.uuidString : "all"
        _digests = Query(filter: #Predicate<InboxDigest> { $0.scopeKey == key }, sort: \InboxDigest.generatedAt, order: .reverse)
    }

    private var latest: InboxDigest? { digests.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where things stand").font(.title3.weight(.semibold))
                if let latest {
                    Text(latest.generatedAt, format: .relative(presentation: .named)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    refresh()
                } label: {
                    Label(latest == nil ? "Summarize my inbox" : "Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .accessibilityIdentifier("refreshDigest")
                if latest != nil {
                    Button(copied ? "Copied" : "Copy") { copy() }.controlSize(.small)
                    Button(showHistory ? "Hide past" : "Past summaries") { showHistory.toggle() }.controlSize(.small)
                }
            }

            if let latest {
                Text(latest.headline).font(.headline)
                Text(latest.narrative).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !latest.topItems.isEmpty {
                    Text("Start with").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
                    ForEach(Array(latest.topItems.prefix(3).enumerated()), id: \.element.id) { index, item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(item.sender).font(.callout.weight(.medium))
                                    if let due = item.dueLabel {
                                        Text(due).font(.caption2.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1)
                                            .background((item.isOverdue ? Color.red : Color.orange).opacity(0.15), in: Capsule())
                                            .foregroundStyle(item.isOverdue ? .red : .orange)
                                    }
                                    if item.isQuick { Text("2 min").font(.caption2).foregroundStyle(.green) }
                                }
                                Text(item.summary ?? item.subject).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            } else {
                Text("A plain-language summary of this inbox right now — what needs you, what was filed, what is waiting for a decision — kept with a timestamp so you can come back to it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if showHistory, digests.count > 1 {
                Divider()
                ForEach(digests.dropFirst().prefix(10)) { past in
                    HStack(alignment: .top, spacing: 8) {
                        Text(past.generatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        Text(past.headline).font(.caption)
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: state.maintainer.phase) { _, phase in
            // A tidy-up or a read changes the answer; refresh quietly so the card is never stale.
            if case .finished = phase { refresh() }
        }
        .onChange(of: state.engine.phase) { _, phase in
            if case .finished = phase { refresh() }
        }
        .onChange(of: state.executor.phase) { _, phase in
            if case .finished = phase { refresh() }
        }
    }

    private func refresh() {
        _ = try? DigestBuilder.build(for: accounts, in: modelContext)
        copied = false
    }

    private func copy() {
        guard let latest else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latest.asText, forType: .string)
        copied = true
    }
}
