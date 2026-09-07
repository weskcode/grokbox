import SwiftUI
import SwiftData
import GrokboxCore

/// Every change Grokbox made, newest first, with Undo. Shows all accounts in
/// scope, so "All accounts" really means all.
struct PhoneActivityView: View {
    let accounts: [MailAccount]
    @Environment(AppState.self) private var state
    @Query private var actions: [CleanupAction]

    init(accounts: [MailAccount]) {
        self.accounts = accounts
        let ids = accounts.map(\.id)
        _actions = Query(filter: #Predicate<CleanupAction> { ids.contains($0.accountID) }, sort: \CleanupAction.performedAt, order: .reverse)
    }

    var body: some View {
        List {
            if state.executor.phase.isRunning {
                PhoneStatusRow(label: state.executor.phase.label, fraction: nil, isRunning: true, isFailed: false)
            }
            if case .failed(let why) = state.executor.phase { Text(why).font(.caption).foregroundStyle(.red) }
            if actions.isEmpty { Text("Nothing yet. Every change Grokbox makes will be listed here, newest first, with Undo.").foregroundStyle(.secondary) }
            ForEach(actions) { action in row(action) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ action: CleanupAction) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title(action)).font(.headline).strikethrough(action.isUndone)
                if action.isUndone { Text("undone").font(.caption2).padding(.horizontal, 5).background(.quaternary, in: Capsule()) }
                Spacer()
                Text(action.performedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(action.senderName) · \(action.senderAddress)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if accounts.count > 1, let account = accounts.first(where: { $0.id == action.accountID }) {
                Text(account.displayName).font(.caption2).foregroundStyle(.secondary)
            }
            if let e = action.errorMessage { Text(e).font(.caption).foregroundStyle(.red) }
            if let held = action.heldSummary { Label(held, systemImage: "hand.raised").font(.caption).foregroundStyle(.orange) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(action.isUndone ? "activityRowUndone" : "activityRow")
        .swipeActions {
            if action.isUndoable && !action.isUndone && action.errorMessage == nil,
               let account = accounts.first(where: { $0.id == action.accountID }) {
                Button { Task { await state.executor.undo(action, on: account) } } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.tint(.blue)
            }
        }
    }

    private func title(_ a: CleanupAction) -> String {
        switch a.kind {
        case .archive: "Archived \(a.messageCount)"
        case .markRead: "Marked \(a.messageCount) read"
        case .label: "Filed \(a.messageCount) → \(a.labelName ?? "folder")"
        case .trash: "Moved \(a.messageCount) to Trash"
        case .unsubscribe: "Unsubscribed from \(a.senderName)"
        }
    }
}
