import SwiftUI
import SwiftData
import GrokboxCore

struct PhoneAddAccountView: View {
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [MailAccount]

    @State private var kind: AccountKind = .gmail
    @State private var displayName = ""
    @State private var username = ""
    @State private var password = ""
    @State private var host = AccountKind.gmail.defaultHost
    @State private var port = "\(AccountKind.gmail.defaultPort)"
    @State private var security: IMAPSecurity = .tls
    @State private var isTesting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Provider", selection: $kind) {
                    Text("Gmail").tag(AccountKind.gmail)
                    Text("Other IMAP").tag(AccountKind.generic)
                }
                .onChange(of: kind) { host = kind.defaultHost; port = "\(kind.defaultPort)"; security = kind.defaultSecurity }
                Section {
                    TextField("Label (optional)", text: $displayName)
                    TextField("Email address", text: $username).textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Text(kind.credentialHint).font(.footnote).foregroundStyle(.secondary)
                }
                if kind == .generic {
                    Section("Server") {
                        TextField("Server", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Port", text: $port).keyboardType(.numberPad)
                    }
                }
                Section {
                    Text("Proton Mail needs Bridge, which runs on a Mac or PC — add Proton accounts there. Grokbox proves the sign-in works before it stores anything; the password goes to the device Keychain only.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle("Add Mailbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isTesting { ProgressView() } else {
                        Button("Add") { Task { await save() } }.disabled(username.isEmpty || password.isEmpty || host.isEmpty)
                    }
                }
            }
        }
    }

    private func save() async {
        guard let portNumber = Int(port) else { return }
        errorMessage = nil
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanPassword = kind == .gmail ? password.replacingOccurrences(of: " ", with: "") : password
        if accounts.contains(where: { $0.username == cleanUsername && $0.host == host }) { errorMessage = "That mailbox is already added."; return }
        isTesting = true; defer { isTesting = false }
        do {
            let provider = try await IMAPMailProvider.connect(host: host, port: portNumber, security: security, username: cleanUsername, password: cleanPassword)
            let mailboxes = try await provider.discoverMailboxes()
            await provider.finish()
            guard mailboxes.primaryArchive != nil else { errorMessage = "Connected, but no mailbox could be found to index."; return }
        } catch { errorMessage = ConnectionErrorText.friendly(error, kind: kind, port: portNumber); return }
        let account = MailAccount(displayName: displayName.isEmpty ? cleanUsername : displayName, username: cleanUsername,
                                  host: host, port: portNumber, kind: kind, security: security)
        do {
            try KeychainStore.save(password: cleanPassword, for: account.keychainAccount)
            modelContext.insert(account); try modelContext.save()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
