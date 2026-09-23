import SwiftUI
import SwiftData
import GrokboxCore

/// The menu-bar popover: the latest cross-account summary and the two buttons
/// that matter. Enough to answer "how bad is it?" without opening a window.
struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MailAccount.createdAt) private var accounts: [MailAccount]
    @Query(sort: \InboxDigest.generatedAt, order: .reverse)
    private var digests: [InboxDigest]

    /// The builder keys a one-account summary by that account, not "all".
    private var scopeKey: String { accounts.count == 1 ? accounts[0].id.uuidString : "all" }

    private var latest: InboxDigest? { digests.first { $0.scopeKey == scopeKey } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Grokbox").font(.headline)
                Spacer()
                if let latest {
                    Text(latest.generatedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                }
            }

            if state.isBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(state.maintainer.phase.isRunning ? state.maintainer.phase.label : state.engine.phase.label)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if let latest {
                Text(latest.headline).font(.callout.weight(.medium))
                ForEach(latest.topItems.prefix(3)) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(item.sender).font(.callout)
                            if let due = item.dueLabel {
                                Text(due).font(.caption2).foregroundStyle(item.isOverdue ? .red : .orange)
                            }
                        }
                        Text(item.summary ?? item.subject).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } else if accounts.isEmpty {
                Text("No accounts yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("No summary yet — press Refresh.").font(.callout).foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Tidy up now") { Task { await state.tidyUp(accounts) } }
                    .disabled(state.isBusy || accounts.isEmpty)
                Button("Refresh") { state.refreshDigest(accounts) }
                    .disabled(accounts.isEmpty)
                Spacer()
                Button("Open Grokbox") { MainWindow.show() }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            // Same rule as the Brief's card: a summary from another day is rebuilt.
            guard let latest, !Calendar.current.isDateInToday(latest.generatedAt), !state.isBusy else { return }
            state.refreshDigest(accounts)
        }
    }
}
