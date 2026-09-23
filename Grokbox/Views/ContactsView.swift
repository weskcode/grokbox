import SwiftUI
import SwiftData
import GrokboxCore

/// Who you have actually written to, ranked by how often — the strongest
/// "this matters" signal in an inbox, and Grokbox already computes it
/// (`SyncEngine.learnContacts`). This view only reads it: no new model, no
/// new sync work, no network connection.
struct ContactsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var contacts: [ContactedAddress]
    @Query private var profiles: [SenderProfile]

    private var summaries: [ContactSummary] {
        ContactDirectory.summaries(contacts: contacts, profiles: profiles)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if summaries.isEmpty {
                ContentUnavailableView("No contacts yet", systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text("Grokbox learns who you have written to from your Sent mail."))
            } else {
                List(summaries) { contact in row(contact) }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private var header: some View {
        HStack {
            Text("Contacts").font(.title3.weight(.semibold))
            Spacer()
            Text("\(summaries.count)").font(.callout).foregroundStyle(.secondary)
            Button("Close") { dismiss() }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func row(_ contact: ContactSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName).font(.headline)
                if contact.displayName != contact.address {
                    Text(contact.address).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(contact.timesContacted)×").font(.callout.monospacedDigit())
                Text(contact.lastContactedAt, format: .relative(presentation: .named))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(contact.displayName), contacted \(contact.timesContacted) times, last \(contact.lastContactedAt.formatted(.relative(presentation: .named)))")
    }
}
