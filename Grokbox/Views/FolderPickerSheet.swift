import SwiftUI
import GrokboxCore

/// Lets the user send one sender's mail to a specific mailbox instead of the
/// category default. Connects read-only (`discoverMailboxes()`, the same
/// call `AddAccountSheet`/`AccountOnboarding` already use) to list what
/// exists on the server; picking one stores its logical name via
/// `logicalName(forServer:)` so it round-trips correctly through
/// `serverName(forLogical:)` on the next sweep. A free-text field covers a
/// folder that doesn't exist yet — `PlanExecutor` creates it with
/// `ensureMailbox`, the same way it already creates category folders.
struct FolderPickerSheet: View {
    let address: String
    let account: MailAccount

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var mailboxes: [IMAPMailbox] = []
    @State private var newFolderName = ""
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isLoading {
                VStack { ProgressView("Loading mailboxes…") }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        Button("Follow the category default") { choose(nil) }
                    }
                    if !mailboxes.isEmpty {
                        Section("Existing mailboxes") {
                            ForEach(mailboxes, id: \.name) { box in
                                Button(box.displayName) { choose(mailboxes.logicalName(forServer: box.name)) }
                            }
                        }
                    }
                    Section("New folder") {
                        HStack {
                            TextField("e.g. Clients/VIP", text: $newFolderName)
                            Button("Use") { choose(newFolderName) }.disabled(newFolderName.isEmpty)
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                        .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
        }
        .frame(width: 420, height: 420)
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Where this sender's mail goes").font(.headline)
                Text(address).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func choose(_ folder: String?) {
        let trimmed = folder?.trimmingCharacters(in: .whitespaces)
        RuleStore.setCustomFolder(trimmed?.isEmpty == false ? trimmed : nil, for: address, in: modelContext)
        dismiss()
    }

    private func load() async {
        do {
            let provider = try await MailProviderFactory.connect(to: account)
            defer { Task { await provider.finish() } }
            mailboxes = try await provider.discoverMailboxes()
        } catch {
            errorMessage = "Could not load this account's mailboxes: \(error.localizedDescription)"
        }
        isLoading = false
    }
}
