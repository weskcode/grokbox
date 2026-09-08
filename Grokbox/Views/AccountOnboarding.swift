import SwiftUI
import SwiftData
import GrokboxCore

/// What happens the moment an account is added: confirm it worked, ask the two
/// questions that matter, then do the work while showing it happening.
///
/// Adding a mailbox and being returned to an empty screen is the worst moment
/// in the app — the person has just handed over a password and has no idea
/// whether it took. This is the answer to that.
struct AccountOnboarding: View {
    let account: MailAccount
    let state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var step: Step = .connected
    @State private var probe: Probe?
    @State private var depth = 1_000
    @State private var policy = CleanupPolicy.gentle
    @State private var runError: String?
    @State private var result: Result?

    enum Step { case connected, depth, approach, running, done }

    /// What a quick look at the server found, so the first screen says
    /// something true and specific rather than "success".
    struct Probe: Equatable {
        var mailboxes: Int
        var inboxMessages: Int
        var archiveName: String
    }

    struct Result: Equatable {
        var indexed: Int
        var senders: Int
        var bulkSenders: Int
        var bulkMessages: Int
        var read: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .connected: connected
                case .depth: depthStep
                case .approach: approachStep
                case .running: runningStep
                case .done: doneStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 420)
        .task { await runProbe() }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: step == .done ? "checkmark.circle.fill" : "tray.and.arrow.down.fill")
                .foregroundStyle(step == .done ? .green : .accentColor)
                .font(.title2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(account.username).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var title: String {
        switch step {
        case .connected: "Account added"
        case .depth: "How much mail should Grokbox look at?"
        case .approach: "How tidy do you want it?"
        case .running: "Working through your mailbox"
        case .done: "Ready"
        }
    }

    private var footer: some View {
        HStack {
            if step == .running, state.isBusy {
                Button("Stop") { state.engine.cancel() }
            }
            Spacer()
            switch step {
            case .connected:
                Button("Later") { dismiss() }
                Button("Continue") { step = .depth }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            case .depth:
                Button("Back") { step = .connected }
                Button("Continue") { step = .approach }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            case .approach:
                Button("Back") { step = .depth }
                Button("Start") { start() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            case .running:
                EmptyView()
            case .done:
                Button("Show me the Brief") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    // MARK: - Steps

    private var connected: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Your password was accepted and stored in the macOS Keychain.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            if let probe {
                VStack(alignment: .leading, spacing: 6) {
                    row("Mailboxes found", "\(probe.mailboxes)")
                    row("Messages in the inbox", probe.inboxMessages.formatted())
                    row("Grokbox will read", probe.archiveName)
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            } else if let runError {
                Label(runError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking at your mailbox…").foregroundStyle(.secondary) }
            }
            Text("Nothing has been changed. Grokbox reads with IMAP's peek, so opening a message here does not mark it read on the server.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(16)
    }

    private var depthStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Grokbox downloads message headers — sender, subject, date — not the mail itself. More history means better advice about who fills your inbox.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $depth) {
                Text("The last 1,000 — about a minute").tag(1_000)
                Text("The last 5,000 — a few minutes").tag(5_000)
                Text("The last 25,000 — ten minutes or so").tag(25_000)
                Text("Everything — go and make tea").tag(1_000_000)
            }
            #if os(macOS)
            .pickerStyle(.radioGroup)
            #else
            .pickerStyle(.inline)
            #endif
            .labelsHidden()
            if let probe, probe.inboxMessages > depth {
                Label("Your inbox has \(probe.inboxMessages.formatted()) messages, so this covers part of it. You can go deeper later.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
    }

    private var approachStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: presetBinding) {
                ForEach([CleanupPolicy.Preset.gentle, .balanced, .thorough]) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(policy.matchingPreset.blurb).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(policy.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label("Nothing is swept now. Grokbox will show you a plan and wait for you to approve it.", systemImage: "hand.raised")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("You can change any of this later in Settings.").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(16)
    }

    private var runningStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView(value: state.engine.phase.fraction ?? 0)
                .progressViewStyle(.linear)
                .accessibilityLabel(state.engine.phase.label)
            Text(state.engine.phase.label).font(.callout)
            Text("You can close this window — the work carries on.")
                .font(.caption).foregroundStyle(.secondary)
            if let runError {
                Label(runError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result {
                VStack(alignment: .leading, spacing: 6) {
                    row("Messages indexed", result.indexed.formatted())
                    row("Senders found", result.senders.formatted())
                    row("Bulk senders", "\(result.bulkSenders.formatted()) — \(result.bulkMessages.formatted()) messages")
                    if result.read > 0 { row("Read by the on-device model", result.read.formatted()) }
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                if result.bulkSenders > 0 {
                    Text("Sweep has a plan waiting for you covering \(result.bulkMessages.formatted()) messages. Nothing runs until you approve it.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let runError {
                Label(runError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var presetBinding: Binding<CleanupPolicy.Preset> {
        Binding(get: { policy.matchingPreset },
                set: { if $0 != .custom { policy = CleanupPolicy.preset($0) } })
    }

    // MARK: - Work

    /// A cheap look at the server, so the first screen can say what was found
    /// rather than just "connected".
    private func runProbe() async {
        guard probe == nil, !account.kind.isDemo else {
            if account.kind.isDemo { probe = Probe(mailboxes: 4, inboxMessages: 0, archiveName: "the demo mailbox") }
            return
        }
        do {
            let provider = try await MailProviderFactory.connect(to: account)
            defer { Task { await provider.finish() } }
            let mailboxes = try await provider.discoverMailboxes()
            guard let archive = mailboxes.primaryArchive else {
                runError = "Connected, but no mailbox could be found to read."
                return
            }
            let status = try await provider.openReadOnly(archive.name)
            probe = Probe(mailboxes: mailboxes.count, inboxMessages: status.exists, archiveName: archive.displayName)
        } catch {
            runError = ConnectionErrorText.friendly(error, kind: account.kind, port: account.port)
        }
    }

    private func start() {
        state.policy = policy
        step = .running
        runError = nil
        Task {
            await state.engine.indexNow(account: account, mode: .full(limit: depth))
            if case .failed(let why) = state.engine.phase {
                runError = why
                step = .done
                return
            }
            if let model = state.model {
                await state.engine.readNow(account: account, model: model, limit: 25)
                if case .failed(let why) = state.engine.phase { runError = why }
            }
            state.refreshDigest([account])
            result = summarise()
            step = .done
        }
    }

    private func summarise() -> Result {
        let id = account.id
        let indexed = (try? modelContext.fetchCount(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == id }))) ?? 0
        let profiles = (try? modelContext.fetch(FetchDescriptor<SenderProfile>(predicate: #Predicate { $0.accountID == id }))) ?? []
        let bulk = profiles.filter { $0.verdict == .bulk }
        let read = (try? modelContext.fetchCount(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == id && $0.summary != nil }))) ?? 0
        return Result(indexed: indexed, senders: profiles.count,
                      bulkSenders: bulk.count, bulkMessages: bulk.reduce(0) { $0 + $1.pendingUIDs.count }, read: read)
    }
}
