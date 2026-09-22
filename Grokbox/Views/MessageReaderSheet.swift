import SwiftUI
import GrokboxCore

/// Reads one message's body on demand, display-only. Uses `MessageBodyReader`,
/// which opens its own IMAP connection — separate from the sync engine's —
/// so an unrelated Stop action can never tear this down. Nothing read here
/// is written back to `MessageHeader`; the text is discarded on close.
struct MessageReaderSheet: View {
    let message: MessageHeader
    let account: MailAccount

    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading
        case loaded(String)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 560, height: 480)
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(message.subject).font(.title3.weight(.semibold)).lineLimit(2)
                Text(message.senderName.isEmpty ? message.senderAddress : message.senderName)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack { ProgressView("Reading…") }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let text):
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case .failed(let description):
            ContentUnavailableView("Could not read this message", systemImage: "exclamationmark.triangle",
                                   description: Text(description))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        do {
            let text = try await MessageBodyReader.read(uid: message.uid, mailbox: message.mailbox, account: account)
            state = .loaded(text)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
