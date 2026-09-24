import SwiftUI
import SwiftData
import GrokboxCore

struct PhoneSettingsView: View {
    let accounts: [MailAccount]
    let addAccount: () -> Void
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var modelContext
    @State private var confirmingErase = false
    @State private var exportURL: URL?
    @State private var removing: MailAccount?
    @State private var jevAPIKeyField = ""
    @State private var hasJevKey = false
    @AppStorage("grokbox.notify") private var notify = false

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
            Section("Keep it clean") {
                Toggle("Notify me when a tidy-up finds something that needs me", isOn: $notify)
                    .onChange(of: notify) { _, on in if on { NotificationService.requestPermission() } }
            }
            CleanupPolicyEditor(policy: Bindable(state).policy)
            Section("Jev cloud fallback (optional)") {
                Toggle("Ask Jev about senders the local model still can't place", isOn: Bindable(state).jevSettings.enabled)
                    .disabled(!hasJevKey)
                SecureField("Jev API key", text: $jevAPIKeyField).onSubmit { saveJevKey() }
                HStack {
                    Button("Save key") { saveJevKey() }.disabled(jevAPIKeyField.isEmpty)
                    if hasJevKey {
                        Button("Remove key", role: .destructive) { removeJevKey() }
                    }
                }
                Text("Off by default. When on, only a sender's address and a few subject lines — never a message body — go to TypeSafe AI's Jev API, only for senders the local model still could not place. Requires your own API key. See docs/PRIVACY.md and ADR-0023.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .task { loadJevKey() }
            Section("App lock") {
                Toggle("Require Face ID or Touch ID to open Grokbox", isOn: Bindable(state).biometricLockSettings.enabled)
                Text("Asked when Grokbox opens and every time you come back to it. Falls back to your device passcode if biometrics are not enrolled.")
                    .font(.footnote).foregroundStyle(.secondary)
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

    private func loadJevKey() {
        let key = (try? JevKeyStore.apiKey()) ?? nil
        hasJevKey = !(key ?? "").isEmpty
    }

    private func saveJevKey() {
        guard !jevAPIKeyField.isEmpty else { return }
        try? JevKeyStore.save(apiKey: jevAPIKeyField)
        jevAPIKeyField = ""
        loadJevKey()
    }

    private func removeJevKey() {
        try? JevKeyStore.delete()
        state.jevSettings.enabled = false
        loadJevKey()
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
