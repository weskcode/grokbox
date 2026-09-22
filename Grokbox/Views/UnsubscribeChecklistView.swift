import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import GrokboxCore

/// Review the senders Grokbox recommends "Unsubscribe & sweep" for, approve
/// the ones you actually want, and export them as JSON.
///
/// This view makes no network connection and does not call
/// `UnsubscribeService`. It only reads `SenderProfile.recommendation` and
/// writes a file — what you do with that file, including whether you feed it
/// to a browser-automation tool, happens entirely outside Grokbox.
struct UnsubscribeChecklistView: View {
    let account: MailAccount

    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [SenderProfile]
    @State private var approved: Set<String> = []
    @State private var didInitializeSelection = false
    @State private var exportDocument: ExportFile?
    @State private var showingExporter = false

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
        VStack(spacing: 0) {
            header
            Divider()
            if candidates.isEmpty {
                ContentUnavailableView("Nothing suggested", systemImage: "checkmark.circle",
                                       description: Text("No sender is currently recommended for unsubscribe & sweep."))
            } else {
                List {
                    ForEach(candidates) { profile in row(profile) }
                }
            }
            Divider()
            Text("Exports the addresses and unsubscribe links you approve, as a JSON file. Grokbox does not visit them — that only happens if you run the exported list through a browser-automation tool yourself.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            guard !didInitializeSelection else { return }
            approved = Set(candidates.map(\.address))
            didInitializeSelection = true
        }
        .fileExporter(isPresented: $showingExporter, document: exportDocument, contentType: .json,
                      defaultFilename: "grokbox-unsubscribe-export") { _ in }
        .frame(minWidth: 480, minHeight: 480)
    }

    private var header: some View {
        HStack {
            Text("Unsubscribe list").font(.title3.weight(.semibold))
            Spacer()
            Button("All") { approved = Set(candidates.map(\.address)) }
                .disabled(candidates.isEmpty).controlSize(.small)
            Button("None") { approved.removeAll() }
                .disabled(approved.isEmpty).controlSize(.small)
            Button("Export…") { exportApproved() }
                .disabled(approved.isEmpty).controlSize(.small).buttonStyle(.borderedProminent)
            Button("Close") { dismiss() }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func row(_ profile: SenderProfile) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: binding(for: profile.address)).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName.isEmpty ? profile.address : profile.displayName).font(.headline)
                Text(profile.address).font(.caption).foregroundStyle(.secondary)
                Text(profile.recommendationReason).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(profile.messageCount.formatted()).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func binding(for address: String) -> Binding<Bool> {
        Binding(
            get: { approved.contains(address) },
            set: { newValue in
                if newValue { approved.insert(address) } else { approved.remove(address) }
            }
        )
    }

    private func exportApproved() {
        let clusters = candidates.filter { approved.contains($0.address) }.map(\.assessment.cluster)
        let document = UnsubscribeExport.document(from: clusters)
        guard let data = try? UnsubscribeExport.encode(document) else { return }
        exportDocument = ExportFile(data: data)
        showingExporter = true
    }
}
