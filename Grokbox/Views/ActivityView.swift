import SwiftUI
import SwiftData
import GrokboxCore

/// Everything Grokbox has done to this mailbox, newest first, with undo.
struct ActivityView: View {
    let account: MailAccount
    let state: AppState

    @Query private var actions: [CleanupAction]

    init(account: MailAccount, state: AppState) {
        self.account = account
        self.state = state
        let id = account.id
        _actions = Query(filter: #Predicate<CleanupAction> { $0.accountID == id },
                         sort: \CleanupAction.performedAt, order: .reverse)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                EngineStatusBar(label: state.executor.phase.label, fraction: nil,
                                isRunning: state.executor.phase.isRunning,
                                isFailed: { if case .failed = state.executor.phase { true } else { false } }())
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if actions.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Every change Grokbox makes to this mailbox will be listed here."))
            } else {
                List(actions) { action in
                    row(action)
                }
            }
        }
        .navigationTitle("Activity · \(account.displayName)")
    }

    private func row(_ action: CleanupAction) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: action))
                .foregroundStyle(action.errorMessage != nil ? .red : (action.isUndone ? .secondary : .primary))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title(for: action)).font(.headline)
                    if action.isUndone {
                        Text("undone").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text("\(action.senderName) · \(action.senderAddress)").font(.caption).foregroundStyle(.secondary)
                if let error = action.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if let held = action.heldSummary {
                    Label(held, systemImage: "hand.raised").font(.caption).foregroundStyle(.orange)
                        .help("Kept in the inbox by the sweep guard.")
                }
            }
            Spacer()
            Text(action.performedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
            if action.isUndoable && !action.isUndone {
                Button("Undo") {
                    Task { await state.executor.undo(action, on: account) }
                }
                .controlSize(.small)
                .disabled(state.isBusy)
            } else if !action.isUndoable && !action.isUndone && action.errorMessage == nil {
                Text("not undoable").font(.caption2).foregroundStyle(.tertiary)
                    .help(action.kind == .archive ? "Moved on a non-Gmail server; find it in \(action.labelName ?? "Archive")." : "")
            }
        }
        .padding(.vertical, 2)
        .strikethrough(action.isUndone, color: .secondary)
    }

    private func icon(for action: CleanupAction) -> String {
        switch action.kind {
        case .archive: "archivebox"
        case .markRead: "envelope.open"
        case .label: "tag"
        }
    }

    private func title(for action: CleanupAction) -> String {
        switch action.kind {
        case .archive: "Archived \(action.messageCount.formatted())"
        case .markRead: "Marked \(action.messageCount.formatted()) read"
        case .label: "Filed \(action.messageCount.formatted()) → \(action.labelName ?? "")"
        }
    }
}
