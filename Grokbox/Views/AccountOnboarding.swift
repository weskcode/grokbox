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
    /// Opens Sweep for this account. Setup itself never moves mail; ticked
    /// senders only decide what Sweep opens with.
    var onReviewInSweep: ((MailAccount) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var step: Step = .connected
    @State private var probe: Probe?
    @State private var depth = 1_000
    @State private var policy = CleanupPolicy.gentle
    @State private var runError: String?
    @State private var result: Result?
    @State private var candidates: [FirstActionCandidate] = []
    @State private var ticked: Set<String> = []
    @State private var skipped: Set<String> = []
    @State private var inspecting: String?
    @State private var previews: [String: CandidatePreview] = [:]
    @State private var wasStopped = false

    enum CandidatePreview {
        case ready(RulePreview)
        case failed(String)
    }

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
        var coverage: IndexCoverage
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
                Button("Stop") { wasStopped = true; state.stop() }
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
                if result == nil {
                    Button("Later") { dismiss() }
                    Button("Try again") { start() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else if !ticked.isEmpty, onReviewInSweep != nil {
                    Button("Later") { dismiss() }
                    Button("Review in Sweep (\(ticked.count))") { reviewInSweep() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("reviewInSweep")
                } else {
                    Button("Show me the Brief") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let result {
                    VStack(alignment: .leading, spacing: 6) {
                        row("Messages indexed", indexedText(result))
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
                    firstActions(result)
                }
                if let runError {
                    Label(runError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func indexedText(_ result: Result) -> String {
        if case .partial(let indexed, let total) = result.coverage { return "\(indexed.formatted()) of \(total.formatted())" }
        return result.indexed.formatted()
    }

    private func coverageNote(_ coverage: IndexCoverage) -> String? {
        switch coverage {
        case .complete: nil
        case .partial(let indexed, let total):
            "Based on the newest \(indexed.formatted()) of \(total.formatted()) messages. You can go deeper later."
        case .unknown(let indexed): "Based on the \(indexed.formatted()) messages Grokbox has read."
        }
    }

    // MARK: - First actions

    @ViewBuilder
    private func firstActions(_ result: Result) -> some View {
        let shown = candidates.filter { !skipped.contains($0.id) }
        VStack(alignment: .leading, spacing: 8) {
            if wasStopped {
                Label("Stopped. Showing what was indexed so far.", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary)
            }
            if candidates.isEmpty {
                Text(result.coverage.isPartial
                     ? "Nothing obvious to tidy in the newest \(result.coverage.indexed.formatted()) messages."
                     : "Nothing obvious to tidy in these \(result.coverage.indexed.formatted()) messages.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("Senders still lists everyone Grokbox found.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Places to start").font(.headline).accessibilityAddTraits(.isHeader)
                if let note = coverageNote(result.coverage) {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Unread is a signal, not proof you don't want these.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if shown.isEmpty {
                    Text("You skipped these. They are all still in Sweep.").font(.callout)
                }
                ForEach(shown) { candidateCard($0) }
            }
            if state.model == nil {
                Text("Categories are rule-based because no on-device model is available.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Nothing has changed in your mailbox.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func candidateCard(_ candidate: FirstActionCandidate) -> some View {
        let item = candidate.item
        let name = item.cluster.displayName
        let isTicked = ticked.contains(item.cluster.address)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name).font(.headline)
                Text("\(item.cluster.category.label) → \(destination(item))").font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule())
            }
            Text(item.cluster.address).font(.caption).foregroundStyle(.secondary)
            Text(candidateCounts(item)).font(.callout)
            Text(candidate.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let subject = item.cluster.sampleSubjects.first {
                Text("Latest: \(subject)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            if inspecting == item.cluster.address { inspector(item) }
            HStack {
                Button { toggleTick(item.cluster.address) } label: {
                    Label(isTicked ? "In first sweep" : "Add to first sweep", systemImage: isTicked ? "checkmark.circle.fill" : "plus.circle")
                }
                .accessibilityLabel(isTicked ? "Remove \(name) from first sweep" : "Add \(name) to first sweep")
                .accessibilityIdentifier("tickCandidate")
                Button(inspecting == item.cluster.address ? "Hide" : "Inspect") { toggleInspect(item.cluster.address) }
                    .accessibilityLabel(inspecting == item.cluster.address ? "Hide details for \(name)" : "Inspect \(name)")
                    .accessibilityIdentifier("inspectCandidate")
                Button("Not now") { skip(item.cluster.address) }
                    .accessibilityLabel("Not now for \(name)")
                    .accessibilityIdentifier("skipCandidate")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isTicked ? Color.accentColor : Color.secondary.opacity(0.3)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstActionCard")
    }

    private func destination(_ item: CleanupPlan.Item) -> String {
        switch item.disposition {
        case .fileIntoFolders: item.folder
        case .archiveOnly: "Archive"
        case .trash: "Trash"
        }
    }

    private func candidateCounts(_ item: CleanupPlan.Item) -> String {
        "\(item.cluster.pendingUIDs.count.formatted()) in inbox · \(item.heldCount.formatted()) held back"
    }

    @ViewBuilder
    private func inspector(_ item: CleanupPlan.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch previews[item.cluster.address] {
            case .ready(let preview):
                if let effect = preview.accounts.first(where: { $0.accountID == account.id }), case .sweeps(let sweep) = effect.outcome {
                    Text(effectLine(sweep)).font(.caption).fixedSize(horizontal: false, vertical: true)
                    sampleLines("Would move", sweep.affected)
                    sampleLines("Held back", sweep.held)
                    ForEach(Array(preview.irreversibleEffects.enumerated()), id: \.offset) { _, effect in
                        Label(irreversibleLine(effect), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Nothing from this sender would move right now.").font(.caption)
                }
                Text("Applying it in Sweep saves a rule for this address in every account.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .failed(let why):
                Label("Could not preview this sender. \(why)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            case nil:
                ProgressView().controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func effectLine(_ sweep: RulePreview.Sweep) -> String {
        let count = "\(sweep.affectedCount.formatted()) message\(sweep.affectedCount == 1 ? "" : "s")"
        switch sweep.disposition {
        case .fileIntoFolders: return "Files \(count) in \(sweep.folder). Nothing is deleted."
        case .archiveOnly: return "Archives \(count). Nothing is deleted."
        case .trash: return "Moves \(count) to Trash."
        }
    }

    private func irreversibleLine(_ effect: RulePreview.IrreversibleEffect) -> String {
        switch effect {
        case .unsubscribeRequest: "Also sends a one-click unsubscribe request. That cannot be undone."
        case .movesToTrash: "Trash is recoverable only until the provider empties it."
        }
    }

    @ViewBuilder
    private func sampleLines(_ title: String, _ messages: [RulePreview.Message]) -> some View {
        if !messages.isEmpty {
            Text(title).font(.caption.weight(.semibold))
            ForEach(messages) { message in
                Text(message.heldReason.map { "\(message.subject) (\($0))" } ?? message.subject)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func toggleTick(_ address: String) {
        if ticked.contains(address) { ticked.remove(address) } else { ticked.insert(address) }
    }

    private func skip(_ address: String) {
        skipped.insert(address)
        ticked.remove(address)
        if inspecting == address { inspecting = nil }
    }

    private func toggleInspect(_ address: String) {
        if inspecting == address { inspecting = nil; return }
        inspecting = address
        guard previews[address] == nil else { return }
        do {
            previews[address] = .ready(try RulePreview.make(address: address, edit: .decision(.sweep),
                                                            policy: state.policy, in: modelContext))
        } catch {
            previews[address] = .failed(error.localizedDescription)
        }
    }

    private func reviewInSweep() {
        state.firstSweepSelection = FirstSweepSelection(accountID: account.id, addresses: ticked)
        dismiss()
        onReviewInSweep?(account)
    }

    private func loadCandidates() {
        let assessed = SenderProfileBuilder.assessments(for: account, in: modelContext)
        var plan = CleanupPlan.suggested(from: assessed, rules: RuleStore.all(in: modelContext), policy: state.policy,
                                         overrides: RuleStore.overrides(in: modelContext))
        GuardPreview.apply(to: &plan, policy: state.policy, account: account, in: modelContext)
        let advice = Dictionary(SenderProfileBuilder.profiles(for: account, in: modelContext).map {
            ($0.address, (recommendation: $0.recommendation, reason: $0.recommendationReason))
        }, uniquingKeysWith: { first, _ in first })
        candidates = FirstActionCandidates.select(from: plan, advice: advice)
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
        result = nil
        candidates = []
        ticked = []
        skipped = []
        inspecting = nil
        previews = [:]
        wasStopped = false
        state.firstSweepSelection = nil
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
            loadCandidates()
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
                      bulkSenders: bulk.count, bulkMessages: bulk.reduce(0) { $0 + $1.pendingUIDs.count }, read: read,
                      coverage: indexCoverage())
    }

    /// What the index reached, judged against the mailbox size seen while
    /// indexing rather than the earlier probe, which mail may have outgrown.
    private func indexCoverage() -> IndexCoverage {
        let id = account.id
        let snapshots = (try? modelContext.fetch(FetchDescriptor<MailboxSnapshot>(predicate: #Predicate { $0.accountID == id }))) ?? []
        guard let main = snapshots.max(by: { $0.messageCountOnServer < $1.messageCountOnServer }) else {
            return IndexCoverage(indexed: 0, mailboxTotal: nil)
        }
        let name = main.mailbox
        let indexed = (try? modelContext.fetchCount(FetchDescriptor<MessageHeader>(
            predicate: #Predicate { $0.accountID == id && $0.mailbox == name }))) ?? 0
        return IndexCoverage(indexed: indexed, mailboxTotal: main.messageCountOnServer)
    }
}
