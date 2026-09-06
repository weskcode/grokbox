import SwiftUI
import SwiftData
import GrokboxCore

/// The landing screen. Answers one question, in order: what needs me *first*?
///
/// Bounded on purpose. "Now" is at most three things. Everything else is
/// there, but below the fold, so the list can be finished rather than fled.
struct BriefView: View {
    let accounts: [MailAccount]
    let state: AppState

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query private var classified: [MessageHeader]
    @Query private var contacts: [ContactedAddress]
    @Query(sort: \CleanupAction.performedAt, order: .reverse) private var allActions: [CleanupAction]

    @State private var unreadUnclassified = 0
    @State private var showWorthKnowing = false
    @State private var tick = Date()

    private static let nowLimit = 3

    init(accounts: [MailAccount], state: AppState) {
        self.accounts = accounts
        self.state = state
        _classified = Query(filter: Self.classifiedPredicate(accountID: accounts.count == 1 ? accounts.first?.id : nil),
                            sort: \MessageHeader.receivedAt, order: .reverse)
    }

    private static func classifiedPredicate(accountID: UUID?) -> Predicate<MessageHeader> {
        if let accountID {
            return #Predicate<MessageHeader> { message in
                message.accountID == accountID && message.briefRank > 0
                    && message.isSweptLocally == false && message.isInInbox == true
            }
        }
        return #Predicate<MessageHeader> { message in
            message.briefRank > 0 && message.isSweptLocally == false && message.isInInbox == true
        }
    }

    // MARK: - Ranking

    struct Ranked: Identifiable {
        let message: MessageHeader
        let result: PriorityScorer.Result
        var id: PersistentIdentifier { message.persistentModelID }
    }

    private var accountIDs: Set<UUID> { Set(accounts.map(\.id)) }
    private var isMulti: Bool { accounts.count > 1 }

    private var contactCounts: [String: Int] {
        Dictionary(contacts.map { ($0.address, $0.timesContacted) }, uniquingKeysWith: { a, _ in a })
    }

    private var ranked: [Ranked] {
        let counts = contactCounts
        let now = tick
        return classified
            .filter { (isMulti ? accountIDs.contains($0.accountID) : true) && !$0.isSnoozed }
            .map { message in
                Ranked(message: message, result: PriorityScorer.score(.init(
                    importance: message.importance, actionType: message.actionType, dueAt: message.dueAt,
                    receivedAt: message.receivedAt, isUnread: message.isUnread, isFlagged: message.isFlagged,
                    isQuick: message.isQuick, timesContacted: counts[message.senderAddress] ?? 0, now: now
                )))
            }
            .sorted { $0.result.score != $1.result.score ? $0.result.score > $1.result.score : $0.message.receivedAt > $1.message.receivedAt }
    }

    private var needsYou: [Ranked] { ranked.filter { $0.message.importance == .needsYou } }
    private var nowItems: [Ranked] { Array(needsYou.prefix(Self.nowLimit)) }
    private var quickWins: [Ranked] { needsYou.dropFirst(Self.nowLimit).filter { $0.message.isQuick }.prefix(5).map { $0 } }
    private var thenItems: [Ranked] {
        let quickIDs = Set(quickWins.map(\.id))
        return needsYou.dropFirst(Self.nowLimit).filter { !quickIDs.contains($0.id) }
    }
    private var worthKnowing: [Ranked] { ranked.filter { $0.message.importance == .worthKnowing } }
    private var snoozedCount: Int { classified.filter { $0.isSnoozed }.count }

    private var hasIndexedMail: Bool { accounts.contains { $0.lastSyncedAt != nil } }

    private var sweptToday: Int {
        let start = Calendar.current.startOfDay(for: .now)
        return allActions
            .filter { accountIDs.contains($0.accountID) && $0.kind == .archive && $0.performedAt >= start && !$0.isUndone && $0.errorMessage == nil }
            .reduce(0) { $0 + $1.messageCount }
    }

    private var heldToday: Int {
        let start = Calendar.current.startOfDay(for: .now)
        return allActions
            .filter { accountIDs.contains($0.accountID) && $0.kind == .archive && $0.performedAt >= start }
            .reduce(0) { $0 + $1.heldUIDs.count }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if hasIndexedMail { DigestCard(accounts: accounts, state: state) }
                if !hasIndexedMail {
                    notIndexed
                } else if needsYou.isEmpty && worthKnowing.isEmpty && unreadUnclassified > 0 && state.model == nil {
                    noModel
                } else {
                    stats
                    section("Now", subtitle: nowItems.isEmpty ? nil : "Start here. Three things, then stop.", items: nowItems,
                            empty: "Nothing is waiting on you.", accent: .orange)
                    if !quickWins.isEmpty {
                        section("Quick wins", subtitle: "Under two minutes each.", items: quickWins, empty: "", accent: .green)
                    }
                    if !thenItems.isEmpty {
                        section("Then", subtitle: nil, items: thenItems, empty: "", accent: .orange.opacity(0.6))
                    }
                    worthKnowingSection
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .navigationTitle(isMulti ? "All Accounts" : accounts.first?.displayName ?? "Brief")
        .task(id: accounts.map(\.id)) { refreshCounts() }
        .onChange(of: state.engine.phase) { refreshCounts(); tick = Date() }
        .onChange(of: state.executor.phase) { refreshCounts(); tick = Date() }
    }

    /// Counted in the store, not loaded: this can be tens of thousands of rows.
    private func refreshCounts() {
        let ids = Array(accountIDs)
        let descriptor = FetchDescriptor<MessageHeader>(
            predicate: #Predicate { message in
                ids.contains(message.accountID) && message.readAt == nil && message.isUnread == true
                    && message.isInInbox == true && message.isSweptLocally == false
            }
        )
        unreadUnclassified = (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    private func account(for message: MessageHeader) -> MailAccount? {
        accounts.first { $0.id == message.accountID }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.largeTitle.weight(.semibold))
            HStack(spacing: 12) {
                if state.engine.phase.isRunning {
                    EngineStatusBar(label: state.engine.phase.label, fraction: state.engine.phase.fraction,
                                    isRunning: true, isFailed: false, onStop: { state.engine.cancel() })
                } else {
                    Button {
                        Task { await state.readAll(accounts) }
                    } label: {
                        Label("Read new mail", systemImage: "text.magnifyingglass")
                    }
                    .disabled(state.model == nil || state.isBusy)
                    .keyboardShortcut("r")

                    Button {
                        Task { await state.tidyUp(accounts) }
                    } label: {
                        Label("Tidy up now", systemImage: "wind")
                    }
                    .disabled(state.isBusy)

                    Menu {
                        Button("Last 3 months") { Task { await state.readAll(accounts, scope: .catchUp(days: 90)) } }
                        Button("Last year") { Task { await state.readAll(accounts, scope: .catchUp(days: 365)) } }
                    } label: {
                        Label("Catch up on older mail", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(state.model == nil || state.isBusy)
                    .fixedSize()
                    .help("Reads older unread mail — but only from people and record-keeping senders, or flagged. Bulk mail is never worth the model's time.")

                    if case .failed(let message) = state.engine.phase {
                        Text(message).font(.callout).foregroundStyle(.red).lineLimit(1).help(message)
                    } else if case .finished(let message) = state.maintainer.phase, state.maintainer.lastRunAt != nil {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    } else if let model = state.model {
                        Text("Reading with \(model.name)").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("No local model available — see Settings").font(.callout).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 16) {
            stat("\(needsYou.count)", "need you")
            stat("\(worthKnowing.count)", "worth knowing")
            stat("\(sweptToday)", "swept today")
            if heldToday > 0 { stat("\(heldToday)", "held back for you") }
            if snoozedCount > 0 { stat("\(snoozedCount)", "for later") }
            if unreadUnclassified > 0 { stat("\(unreadUnclassified.formatted())", "unread, not yet read by the model") }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func section(_ title: String, subtitle: String?, items: [Ranked], empty: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.weight(.semibold))
                if !items.isEmpty { Text("\(items.count)").font(.callout).foregroundStyle(.secondary) }
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            if items.isEmpty {
                Text(empty).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ForEach(items) { item in row(item, accent: accent) }
            }
        }
    }

    private var worthKnowingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showWorthKnowing.toggle()
            } label: {
                HStack {
                    Image(systemName: showWorthKnowing ? "chevron.down" : "chevron.right").font(.caption)
                    Text("Worth knowing").font(.title3.weight(.semibold))
                    Text("\(worthKnowing.count)").font(.callout).foregroundStyle(.secondary)
                    Text("— nothing required of you").font(.callout).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if showWorthKnowing {
                if worthKnowing.isEmpty {
                    Text("Nothing new worth reading.").foregroundStyle(.secondary).padding(.vertical, 6)
                } else {
                    ForEach(worthKnowing) { item in row(item, accent: .blue) }
                }
            }
        }
    }

    private func row(_ item: Ranked, accent: Color) -> some View {
        let message = item.message
        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3).padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(message.senderName.isEmpty ? message.senderAddress : message.senderName).font(.headline)
                    if let due = item.result.dueLabel {
                        chip(due, color: item.result.isOverdue ? .red : .orange)
                    }
                    if message.actionType != .none { chip(message.actionType.label, color: .secondary) }
                    if message.isQuick { chip("2 min", color: .green) }
                    Text(message.receivedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                    if message.isUnread { Circle().fill(accent).frame(width: 6, height: 6) }
                    if isMulti, let name = account(for: message)?.displayName {
                        chip(name, color: .secondary)
                    }
                }
                Text(message.subject).font(.subheadline).lineLimit(1)
                if let summary = message.summary {
                    Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !item.result.reasons.isEmpty {
                    Text("Why here: " + item.result.reasons.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if let account = account(for: message), let url = account.webLink(for: message) {
                    Button("Open") { openURL(url) }.controlSize(.small)
                }
                Button("Done") {
                    guard let account = account(for: message) else { return }
                    Task { await state.executor.sweep(message, in: account) }
                }
                .controlSize(.small)
                .disabled(state.isBusy)
                .help("Archive this message. Undo from Activity.")
                Menu("Later") {
                    Button("This evening") { snooze(message, hours: 6) }
                    Button("Tomorrow") { snooze(message, days: 1) }
                    Button("In 3 days") { snooze(message, days: 3) }
                    Button("Next week") { snooze(message, days: 7) }
                }
                .controlSize(.small)
                .fixedSize()
                .help("Hide until then. Deferring on purpose is not the same as forgetting.")
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(item.result.isOverdue ? Color.red.opacity(0.5) : Color.secondary.opacity(0.2)))
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color == .secondary ? .secondary : color)
    }

    private func snooze(_ message: MessageHeader, days: Int = 0, hours: Int = 0) {
        var until = Calendar.current.date(byAdding: .day, value: days, to: .now) ?? .now
        until = Calendar.current.date(byAdding: .hour, value: hours, to: until) ?? until
        if days > 0 {
            // Land at 9am, not at the exact minute the button was pressed.
            var parts = Calendar.current.dateComponents([.year, .month, .day], from: until)
            parts.hour = 9
            until = Calendar.current.date(from: parts) ?? until
        }
        message.snoozedUntil = until
        try? modelContext.save()
        tick = Date()
    }

    private var notIndexed: some View {
        ContentUnavailableView {
            Label("Not indexed yet", systemImage: "tray")
        } description: {
            Text("Press Tidy up now to index this mailbox and read what matters, or go to Senders and press Index for a deeper first pass.")
        } actions: {
            Button("Tidy up now") {
                Task { await state.maintainer.run(accounts: accounts, model: state.model, settings: .load()) }
            }
            .disabled(state.isBusy)
        }
    }

    private var noModel: some View {
        ContentUnavailableView {
            Label("No local model available", systemImage: "cpu")
        } description: {
            Text("Reading needs a model that runs on this Mac. Enable Apple Intelligence in System Settings, or run Ollama. See Settings for details.")
        }
    }
}
