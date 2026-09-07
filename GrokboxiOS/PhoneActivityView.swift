import SwiftUI
import SwiftData
import GrokboxCore

struct PhoneActivityView: View {
    let account: MailAccount
    @Environment(AppState.self) private var state
    @Query private var actions: [CleanupAction]

    init(account: MailAccount) {
        self.account = account
        let id = account.id
        _actions = Query(filter: #Predicate<CleanupAction> { $0.accountID == id }, sort: \CleanupAction.performedAt, order: .reverse)
    }

    var body: some View {
        List {
            if state.executor.phase.isRunning {
                PhoneStatusRow(label: state.executor.phase.label, fraction: nil, isRunning: true, isFailed: false)
            }
            if actions.isEmpty { Text("Nothing yet. Every change Grokbox makes will be listed here, newest first, with Undo.").foregroundStyle(.secondary) }
            ForEach(actions) { action in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(title(action)).font(.headline).strikethrough(action.isUndone)
                        if action.isUndone { Text("undone").font(.caption2).padding(.horizontal, 5).background(.quaternary, in: Capsule()) }
                        Spacer()
                        Text(action.performedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(action.senderName) · \(action.senderAddress)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let e = action.errorMessage { Text(e).font(.caption).foregroundStyle(.red) }
                    if let held = action.heldSummary { Label(held, systemImage: "hand.raised").font(.caption).foregroundStyle(.orange) }
                }
                .swipeActions {
                    if action.isUndoable && !action.isUndone && action.errorMessage == nil {
                        Button { Task { await state.executor.undo(action, on: account) } } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.tint(.blue)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func title(_ a: CleanupAction) -> String {
        switch a.kind {
        case .archive: "Archived \(a.messageCount)"
        case .markRead: "Marked \(a.messageCount) read"
        case .label: "Filed \(a.messageCount) → \(a.labelName ?? "folder")"
        }
    }
}
