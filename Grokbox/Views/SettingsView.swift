import SwiftUI
import UniformTypeIdentifiers
import SwiftData
import GrokboxCore

struct SettingsView: View {
    let state: AppState
    let accounts: [MailAccount]

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SenderRule.createdAt, order: .reverse) private var rules: [SenderRule]

    @AppStorage("grokbox.preferredModel") private var preferredModel = ""
    @AppStorage("grokbox.ollamaModel") private var ollamaModel = OllamaProvider.defaultModel
    @AppStorage("grokbox.autoMaintain") private var autoMaintain = false
    @AppStorage("grokbox.autoIntervalMinutes") private var intervalMinutes = 30
    @AppStorage("grokbox.readLimit") private var readLimit = 25
    @AppStorage("grokbox.indexDepth") private var indexDepth = 1_000
    @AppStorage("grokbox.notify") private var notify = false
    @State private var policy = CleanupPolicy.current

    @State private var confirmingErase = false
    @State private var exportDocument: ExportFile?
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var transferMessage: String?

    var body: some View {
        Form {
            Section("Reading model") {
                ForEach(state.modelStatuses, id: \.name) { status in
                    HStack {
                        Button {
                            preferredModel = status.name
                            Task { await state.refreshModels() }
                        } label: {
                            Image(systemName: state.model?.name == status.name ? "largecircle.fill.circle" : "circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(!status.availability.isAvailable)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(status.name)
                            switch status.availability {
                            case .available:
                                Text("Available").font(.caption).foregroundStyle(.green)
                            case .unavailable(let reason):
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                TextField("Ollama model", text: $ollamaModel, prompt: Text(OllamaProvider.defaultModel))
                    .onSubmit { Task { await state.refreshModels() } }
                Button("Check again") { Task { await state.refreshModels() } }

                Text("Both options run entirely on this Mac. Apple's model needs no setup. Ollama is the open-source route: `brew install ollama`, then `ollama pull \(ollamaModel)`.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Keep it clean") {
                Toggle("Show Grokbox in the menu bar", isOn: Bindable(state).showMenuBar)
                Toggle("Tidy up automatically while Grokbox is open", isOn: $autoMaintain)
                Picker("Every", selection: $intervalMinutes) {
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("3 hours").tag(180)
                }
                .disabled(!autoMaintain)

                Toggle("Notify me when a tidy-up finds something that needs me", isOn: $notify)
                    .onChange(of: notify) { _, on in if on { NotificationService.requestPermission() } }

                LabeledContent("Status") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(state.maintainer.phase.label)
                        if let last = state.maintainer.lastRunAt {
                            Text("Last run \(last, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.secondary)
                        }
                        if let next = state.maintainer.nextRunAt, autoMaintain {
                            Text("Next \(next, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Button("Tidy up all accounts now") {
                    Task { await state.maintainer.run(accounts: accounts, model: state.model, settings: .load()) }
                }
                .disabled(state.isBusy || accounts.isEmpty)

                Text("A tidy-up indexes new mail, applies the rules you have already approved, and reads what matters. It never sweeps a sender you have not approved — new suggestions wait for you in Sweep.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            CleanupPolicyEditor(policy: $policy)

            Section("Budgets") {
                Stepper("Read up to \(readLimit) messages per pass", value: $readLimit, in: 10...500, step: 10)
                Picker("Index depth on first tidy-up", selection: $indexDepth) {
                    Text("Last 500").tag(500)
                    Text("Last 1,000").tag(1_000)
                    Text("Last 5,000").tag(5_000)
                }
                Text("The model is the slow part — roughly one to three seconds per message on-device. Reading is capped so a pass finishes in minutes, not hours. After the first pass, tidy-ups only fetch what is new.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Rules (\(rules.count))") {
                if rules.isEmpty {
                    Text("No rules yet. Approving a sender in Sweep, or choosing Always sweep / Always keep in Senders, adds one.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(rules) { rule in
                        HStack {
                            Image(systemName: rule.decision == .sweep ? "wind" : "pin.fill").foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rule.address)
                                Text("\(rule.decision.label) · applied \(rule.timesApplied)×").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") { RuleStore.clear(for: rule.address, in: modelContext) }.controlSize(.small)
                        }
                    }
                }
            }

            Section("Your data") {
                Text("Accounts (never passwords), rules, the action log and saved digests, as one JSON file. Message headers are a cache of your mail server and are not included.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Export…") {
                        do {
                            exportDocument = ExportFile(data: try DataExport.encode(DataExport.document(from: modelContext)))
                            showingExporter = true
                        } catch { transferMessage = error.localizedDescription }
                    }
                    Button("Import rules…") { showingImporter = true }
                    if let transferMessage { Text(transferMessage).font(.callout).foregroundStyle(.secondary) }
                }
                .fileExporter(isPresented: $showingExporter, document: exportDocument, contentType: .json,
                              defaultFilename: "grokbox-export") { result in
                    if case .failure(let error) = result { transferMessage = error.localizedDescription }
                    else { transferMessage = "Exported." }
                }
                .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
                    do {
                        let url = try result.get()
                        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
                        defer { url.stopAccessingSecurityScopedResource() }
                        let document = try DataExport.decode(try Data(contentsOf: url))
                        let count = try DataExport.importRules(from: document, into: modelContext)
                        transferMessage = "Imported \(count) rule\(count == 1 ? "" : "s")."
                    } catch { transferMessage = error.localizedDescription }
                }
            }

            Section("Privacy") {
                Text("Grokbox makes exactly three kinds of network connection: IMAP to your own mail server, a loopback call to Ollama if you use it, and — only when you click Unsubscribe — an HTTPS request to the address a sender put in their own headers. There is nothing else. See docs/PRIVACY.md in the source for the full inventory.")
                    .font(.caption).foregroundStyle(.secondary)

                Button("Erase everything Grokbox knows…", role: .destructive) { confirmingErase = true }
                    .confirmationDialog("Erase all local data?", isPresented: $confirmingErase) {
                        Button("Erase", role: .destructive) { state.eraseEverything() }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("Removes every account, password, index, rule, and log from this Mac. Your mailboxes on the server are not touched.")
                    }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onChange(of: policy) { CleanupPolicy.current = policy }
    }
}


/// A plain JSON file for `fileExporter`.
struct ExportFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
