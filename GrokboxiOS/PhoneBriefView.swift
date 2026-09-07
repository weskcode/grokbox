import SwiftUI
import SwiftData
import GrokboxCore

struct PhoneBriefView: View {
    let accounts: [MailAccount]
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var modelContext
    @Query private var classified: [MessageHeader]
    @Query private var contacts: [ContactedAddress]
    @State private var tick = Date()
    @State private var showWorthKnowing = false

    init(accounts: [MailAccount]) {
        self.accounts = accounts
        _classified = Query(filter: #Predicate<MessageHeader> { $0.briefRank > 0 && $0.isSweptLocally == false && $0.isInInbox == true },
                            sort: \MessageHeader.receivedAt, order: .reverse)
    }

    private var accountIDs: Set<UUID> { Set(accounts.map(\.id)) }
    private var ranked: [BriefItem] {
        let counts = Dictionary(contacts.map { ($0.address, $0.timesContacted) }, uniquingKeysWith: { a, _ in a })
        let now = tick
        return BriefRanking.rank(classified.filter { accountIDs.contains($0.accountID) }, contactCounts: counts, now: now)
    }
    private var needsYou: [BriefItem] { ranked.filter { $0.message.importance == .needsYou } }
    private var worthKnowing: [BriefItem] { ranked.filter { $0.message.importance == .worthKnowing } }
    private var digest: InboxDigest? { DigestBuilder.latest(scopeKey: accounts.count == 1 ? accounts[0].id.uuidString : "all", in: modelContext) }

    var body: some View {
        List {
            Section {
                if let digest {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(digest.headline).font(.headline)
                        Text(digest.narrative).font(.subheadline).foregroundStyle(.secondary)
                        Text(digest.generatedAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Text("Press Refresh for a plain-language summary of where things stand.").foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        Task { await state.readAll(accounts) }
                    } label: { Label("Read new mail", systemImage: "text.magnifyingglass") }
                    .disabled(state.model == nil || state.isBusy)
                    Spacer()
                    Button { state.refreshDigest(accounts); tick = Date() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(state.isBusy)
                }
                .buttonStyle(.bordered).controlSize(.small)
                if state.engine.phase.isRunning || state.maintainer.phase.isRunning {
                    PhoneStatusRow(label: state.engine.phase.isRunning ? state.engine.phase.label : state.maintainer.phase.label,
                                   fraction: state.engine.phase.fraction, isRunning: true, isFailed: false,
                                   onStop: { state.engine.cancel(); state.maintainer.cancel() })
                } else if case .failed(let why) = state.engine.phase {
                    PhoneStatusRow(label: why, fraction: nil, isRunning: false, isFailed: true)
                }
            } header: {
                Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day()).font(.title3.weight(.semibold)).textCase(nil)
            }

            Section("Now · start here, three things, then stop") {
                if needsYou.isEmpty { Text("Nothing needs you right now.").foregroundStyle(.secondary) }
                ForEach(needsYou.prefix(3)) { row($0, accent: .orange) }
            }
            if needsYou.count > 3 {
                Section("Then · \(needsYou.count - 3) more") {
                    ForEach(needsYou.dropFirst(3)) { row($0, accent: .secondary) }
                }
            }
            if !worthKnowing.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showWorthKnowing) {
                        ForEach(worthKnowing) { row($0, accent: .secondary) }
                    } label: {
                        Text("Worth knowing · \(worthKnowing.count) — nothing required of you")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Brief")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await state.readAll(accounts); state.refreshDigest(accounts); tick = Date() }
        .onChange(of: state.engine.phase) { tick = Date() }
        .onChange(of: state.executor.phase) { tick = Date() }
    }

    private func row(_ item: BriefItem, accent: Color) -> some View {
        let m = item.message
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if m.isUnread { Circle().fill(accent).frame(width: 7, height: 7).accessibilityLabel("Unread") }
                Text(m.senderName.isEmpty ? m.senderAddress : m.senderName).font(.headline).lineLimit(1)
                Spacer()
                Text(m.receivedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
            }
            Text(m.subject).font(.subheadline).lineLimit(1)
            if let summary = m.summary { Text(summary).font(.footnote).foregroundStyle(.secondary).lineLimit(3) }
            HStack(spacing: 6) {
                if let due = item.result.dueLabel { chip(due, item.result.isOverdue ? .red : .orange) }
                if m.actionType != .none { chip(m.actionType.label, .secondary) }
                if m.isQuick { chip("2 min", .green) }
                if !item.others.isEmpty { chip("\(item.thread.count) in thread", .secondary) }
                if accounts.count > 1, let a = accounts.first(where: { $0.id == m.accountID }) { chip(a.displayName, .secondary) }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BriefRanking.spokenSummary(item))
        .swipeActions(edge: .trailing) {
            Button {
                guard let account = accounts.first(where: { $0.id == m.accountID }) else { return }
                let thread = item.thread
                Task { for message in thread { await state.executor.sweep(message, in: account) } }
            } label: { Label("Done", systemImage: "archivebox") }
            .tint(.green)
        }
        .swipeActions(edge: .leading) {
            Button { snooze(item.thread, days: 1) } label: { Label("Tomorrow", systemImage: "clock") }.tint(.indigo)
            Button { snooze(item.thread, days: 7) } label: { Label("Next week", systemImage: "calendar") }.tint(.blue)
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color == .secondary ? .secondary : color)
    }

    private func snooze(_ messages: [MessageHeader], days: Int) {
        var until = Calendar.current.date(byAdding: .day, value: days, to: .now) ?? .now
        var parts = Calendar.current.dateComponents([.year, .month, .day], from: until); parts.hour = 9
        until = Calendar.current.date(from: parts) ?? until
        for m in messages { m.snoozedUntil = until }
        try? modelContext.save(); tick = Date()
    }
}
