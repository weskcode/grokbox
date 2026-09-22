import SwiftUI
import SwiftData
import GrokboxCore

/// Review the senders Grokbox recommends "Unsubscribe & sweep" for, approve
/// the ones you actually want, and export them as JSON.
///
/// This view makes no network connection and does not call
/// `UnsubscribeService`. It only reads `SenderProfile.recommendation` and
/// writes a file — what you do with that file, including whether you feed it
/// to a browser-automation tool, happens entirely outside Grokbox.
struct PhoneUnsubscribeChecklistView: View {
    let account: MailAccount

    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [SenderProfile]
    @State private var approved: Set<String> = []
    @State private var didInitializeSelection = false
    @State private var exportURL: URL?

    init(account: MailAccount) {
        self.account = account
        let id = account.id
        _profiles = Query(filter: #Predicate<SenderProfile> { $0.accountID == id })
    }

    private var candidates: [SenderProfile] {
        profiles
            .filter { $0.recommendation == .unsubscribeAndSweep && $0.assessment.cluster.unsubscribeURL != nil }
            .sorted { $0.messageCount > $1.messageCount }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView("Nothing suggested", systemImage: "checkmark.circle",
                                           description: Text("No sender is currently recommended for unsubscribe & sweep."))
                } else {
                    List {
                        Section {
                            ForEach(candidates) { profile in row(profile) }
                        } footer: {
                            Text("Exports the addresses and unsubscribe links you approve, as a JSON file. Grokbox does not visit them — that only happens if you run the exported list through a browser-automation tool yourself.")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Unsubscribe list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("All") { approved = Set(candidates.map(\.address)); exportURL = nil }
                        Button("None") { approved.removeAll(); exportURL = nil }
                    } label: {
                        Image(systemName: "checklist")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Share export", systemImage: "square.and.arrow.up") }
                        .padding(10).frame(maxWidth: .infinity)
                } else {
                    Button("Prepare export") { prepareExport() }
                        .disabled(approved.isEmpty)
                        .padding(10).frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            guard !didInitializeSelection else { return }
            approved = Set(candidates.map(\.address))
            didInitializeSelection = true
        }
    }

    private func row(_ profile: SenderProfile) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName.isEmpty ? profile.address : profile.displayName).font(.headline)
                Text(profile.address).font(.caption).foregroundStyle(.secondary)
                Text(profile.recommendationReason).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(profile.messageCount.formatted()).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(profile.address) }
        .swipeActions(edge: .leading) {
            Button(approved.contains(profile.address) ? "Exclude" : "Approve") { toggle(profile.address) }
                .tint(approved.contains(profile.address) ? .secondary : .accentColor)
        }
        .opacity(approved.contains(profile.address) ? 1 : 0.45)
        .accessibilityAddTraits(approved.contains(profile.address) ? [.isSelected] : [])
    }

    private func toggle(_ address: String) {
        if approved.contains(address) { approved.remove(address) } else { approved.insert(address) }
        exportURL = nil
    }

    private func prepareExport() {
        let clusters = candidates.filter { approved.contains($0.address) }.map(\.assessment.cluster)
        let document = UnsubscribeExport.document(from: clusters)
        do {
            let data = try UnsubscribeExport.encode(document)
            let url = FileManager.default.temporaryDirectory.appending(path: "grokbox-unsubscribe-export.json")
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch { Log.note("unsubscribe export failed: \(error.localizedDescription)") }
    }
}
