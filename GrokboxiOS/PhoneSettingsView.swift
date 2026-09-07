import SwiftUI
import SwiftData
import GrokboxCore

struct PhoneSettingsView: View {
    let accounts: [MailAccount]
    let addAccount: () -> Void
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var modelContext
    @AppStorage("grokbox.guardTransactional") private var guardTransactional = true
    @State private var confirmingErase = false
    @State private var exportURL: URL?
    @State private var removing: MailAccount?

    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(accounts) { account in
                    VStack(alignment: .leading) {
                        HStack { Text(account.displayName); if account.kind.isDemo { Text("demo").font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule()) } }
                        Text(account.username).font(.caption).foregroundStyle(.secondary)
                        if let e = account.lastSyncError { Text(e).font(.caption2).foregroundStyle(.red).lineLimit(2) }
                    }
                    .swipeActions { Button(role: .destructive) { removing = account } label: { Label("Remove", systemImage: "trash") } }
                }
                Button("Add Account…", action: addAccount)
                if accounts.allSatisfy({ !$0.kind.isDemo }) {
                    Button("Add the demo mailboxes") { Task { _ = await state.addDemoAccounts() } }
                }
            }
            Section("Reading model") {
                ForEach(state.modelStatuses, id: \.name) { s in
                    HStack {
                        Text(s.name)
                        Spacer()
                        Text(s.availability.isAvailable ? "Available" : "Unavailable").font(.caption).foregroundStyle(s.availability.isAvailable ? .green : .secondary)
                    }
                }
                Text("Runs entirely on this device. Nothing about your mail leaves it.").font(.footnote).foregroundStyle(.secondary)
                Button("Check again") { Task { await state.refreshModels() } }
            }
            Section("Sweep guard") {
                Toggle("Hold receipts, orders, appointments and security mail out of sweeps", isOn: $guardTransactional)
            }
            Section("Your data") {
                Text("Accounts (never passwords), rules, the action log and saved digests, as one JSON file.").font(.footnote).foregroundStyle(.secondary)
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Share export", systemImage: "square.and.arrow.up") }
                } else {
                    Button("Prepare export") { prepareExport() }
                }
                Button("Erase everything Grokbox knows…", role: .destructive) { confirmingErase = true }
            }
            Section("About") {
                Link("Privacy: what leaves this device", destination: URL(string: "https://github.com/weskcode/grokbox/blob/main/docs/PRIVACY.md")!)
                Link("Threat model", destination: URL(string: "https://github.com/weskcode/grokbox/blob/main/docs/THREAT-MODEL.md")!)
                Link("Source code (GPL-3.0)", destination: URL(string: "https://github.com/weskcode/grokbox")!)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Erase all local data?", isPresented: $confirmingErase) {
            Button("Erase", role: .destructive) { state.eraseEverything() }
        } message: { Text("Your mail on the server is untouched. Grokbox forgets its index, rules, history and passwords.") }
        .confirmationDialog("Remove \(removing?.displayName ?? "account")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { account in
            Button("Remove", role: .destructive) { state.remove(account) }
        } message: { _ in Text("Removes the local index and history for this account. Mail on the server is untouched.") }
        .safeAreaInset(edge: .top) {
            if let message = state.storeRecovery {
                HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text(message).font(.footnote); Spacer(); Button("Dismiss") { state.storeRecovery = nil } }
                    .padding(10).background(.orange.opacity(0.12))
            }
        }
    }

    private func prepareExport() {
        do {
            let data = try DataExport.encode(DataExport.document(from: modelContext))
            let url = FileManager.default.temporaryDirectory.appending(path: "grokbox-export.json")
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch { Log.note("export failed: \(error.localizedDescription)") }
    }
}
