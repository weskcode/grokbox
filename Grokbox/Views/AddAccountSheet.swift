import SwiftUI
import SwiftData
import GrokboxCore

struct AddAccountSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [MailAccount]

    let state: AppState
    var onCreate: (MailAccount) -> Void

    @State private var kind: AccountKind = .gmail
    @State private var displayName = ""
    @State private var username = ""
    @State private var password = ""
    @State private var host = AccountKind.gmail.defaultHost
    @State private var port = String(AccountKind.gmail.defaultPort)
    @State private var security = AccountKind.gmail.defaultSecurity
    @State private var errorMessage: String?
    @State private var isTesting = false

    private var canSave: Bool {
        !username.isEmpty && !password.isEmpty && !host.isEmpty && Int(port) != nil && !isTesting
    }

    private var hasDemoAccounts: Bool {
        accounts.contains { $0.kind.isDemo }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Mailbox")
                .font(.title2.weight(.semibold))

            demoBox

            Form {
                Picker("Provider", selection: $kind) {
                    ForEach(AccountKind.allCases.filter { !$0.isDemo }, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .onChange(of: kind) { _, newKind in
                    host = newKind.defaultHost
                    port = String(newKind.defaultPort)
                    security = newKind.defaultSecurity
                }

                TextField("Label", text: $displayName, prompt: Text("Personal Gmail"))
                TextField("Email address", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)

                Text(kind.credentialHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Section("Connection") {
                    TextField("Server", text: $host)
                    TextField("Port", text: $port)
                    Picker("Security", selection: $security) {
                        ForEach(IMAPSecurity.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isTesting {
                    ProgressView().controlSize(.small)
                    Text("Checking the connection…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var demoBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Try it first").font(.headline)
                    Text("Three sample mailboxes, generated on this Mac. Nothing real is touched.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(hasDemoAccounts ? "Demo added" : "Add demo mailboxes") {
                    Task {
                        let created = await state.addDemoAccounts()
                        if let first = created.first { onCreate(first) }
                        dismiss()
                    }
                }
                .disabled(hasDemoAccounts)
            }
            ForEach(DemoPersona.allCases, id: \.self) { persona in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.tertiary)
                    Text("\(persona.displayName.replacingOccurrences(of: "Demo · ", with: "")): \(persona.blurb)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func save() async {
        guard let portNumber = Int(port) else { return }
        errorMessage = nil

        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Google shows App Passwords in four groups; people paste the spaces too.
        let cleanPassword = kind == .gmail ? password.replacingOccurrences(of: " ", with: "") : password

        if accounts.contains(where: { $0.username == cleanUsername && $0.host == host }) {
            errorMessage = "That mailbox is already added."
            return
        }

        // Prove the credentials work before anything is stored.
        isTesting = true
        defer { isTesting = false }
        do {
            let provider = try await IMAPMailProvider.connect(
                host: host, port: portNumber, security: security,
                username: cleanUsername, password: cleanPassword
            )
            let mailboxes = try await provider.discoverMailboxes()
            await provider.finish()
            guard mailboxes.primaryArchive != nil else {
                errorMessage = "Connected, but no mailbox could be found to index."
                return
            }
        } catch {
            errorMessage = friendly(error)
            return
        }

        let account = MailAccount(
            displayName: displayName.isEmpty ? cleanUsername : displayName,
            username: cleanUsername,
            host: host,
            port: portNumber,
            kind: kind,
            security: security
        )

        do {
            // Save the credential before the account record, so a Keychain
            // failure never leaves an account that cannot authenticate.
            try KeychainStore.save(password: cleanPassword, for: account.keychainAccount)
            modelContext.insert(account)
            try modelContext.save()
            onCreate(account)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func friendly(_ error: Error) -> String {
        ConnectionErrorText.friendly(error, kind: kind, port: Int(port) ?? 0)
    }
}
