import SwiftUI
import GrokboxCore

/// Replace a stored password without removing the account — and with it, the
/// account's history. Verified against the server before anything is saved.
struct UpdatePasswordSheet: View {
    let account: MailAccount
    let state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var isTesting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Update password").font(.title2.weight(.semibold))
            Text("\(account.displayName) · \(account.username)").foregroundStyle(.secondary)
            SecureField("New password", text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("New password for \(account.displayName)")
            Text(account.kind.credentialHint).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isTesting {
                    ProgressView().controlSize(.small)
                    Text("Checking the connection…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || isTesting)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() async {
        errorMessage = nil
        isTesting = true
        defer { isTesting = false }
        do {
            try await state.updatePassword(for: account, password: password)
            dismiss()
        } catch {
            errorMessage = ConnectionErrorText.friendly(error, kind: account.kind, port: account.port)
        }
    }
}
