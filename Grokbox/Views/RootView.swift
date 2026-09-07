import SwiftUI
import SwiftData
import GrokboxCore


struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MailAccount.createdAt) private var accounts: [MailAccount]

    /// Sentinel for the cross-account Brief.
    static let allAccountsID = UUID(uuidString: "00000000-0000-0000-0000-00000000A11A")!

    @Environment(AppState.self) private var state
    @State private var selectedAccountID: UUID?
    @State private var section: AppSection = .brief
    @State private var passwordAccount: MailAccount?
    @State private var onboardingAccount: MailAccount?
    @State private var isAddingAccount = false

    private var selectedAccount: MailAccount? {
        accounts.first { $0.id == selectedAccountID }
    }

    private var isAllAccounts: Bool { selectedAccountID == Self.allAccountsID }

    var body: some View {
        switch LaunchOptions.current.ui {
        case "bare": Text("bare").task { Log.note("bare appeared") }
        case "sidebar": sidebar.task { Log.note("sidebar-only appeared") }
        case "detail": detail(state: state).task { Log.note("detail-only appeared") }
        default: full
        }
    }

    private var full: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail(state: state)
        }
        .safeAreaInset(edge: .top) {
            if let message = state.storeRecovery {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { state.storeRecovery = nil }.controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.orange.opacity(0.12))
            }
        }
        .task {
            Log.note("root view appeared")
            if state.storeRecovery == nil, let recovery = AppEnvironment.opened.recovery {
                state.storeRecovery = recovery
                Log.note("store recovery: \(recovery)")
            }
            state.mainWindowSeen = true
            logWindowFrame()
            await state.startIfNeeded()
            if let section = LaunchOptions.current.section { self.section = section }
            if LaunchOptions.current.onboard, let first = accounts.first { onboardingAccount = first }
            chooseInitialSelection()
            Log.note("root task finished; section=\(section.rawValue) selected=\(selectedAccountID?.uuidString ?? "nil") accounts=\(accounts.count)")
        }
        // The account query fills in after the first appearance; choose then too.
        .onChange(of: accounts.count) { chooseInitialSelection() }
        .sheet(item: $passwordAccount) { account in
            UpdatePasswordSheet(account: account, state: state)
        }
        .sheet(item: $onboardingAccount) { account in
            AccountOnboarding(account: account, state: state)
        }
        .onChange(of: state.pendingCommand) { _, command in
            guard let command else { return }
            state.pendingCommand = nil
            perform(command)
        }
        .sheet(isPresented: $isAddingAccount) {
            AddAccountSheet(state: state) { newAccount in
                selectedAccountID = newAccount.id
                // Straight into "what now?" — an account added and nothing
                // visible happening is the moment people give up.
                onboardingAccount = newAccount
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedAccountID) {
            if accounts.count > 1 {
                Label("All Accounts", systemImage: "tray.2")
                    .tag(Self.allAccountsID)
            }
            Section("Accounts") {
                ForEach(accounts) { account in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(account.displayName)
                            if account.kind.isDemo {
                                Text("demo").font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        Text(account.username)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if account.lastSyncedAt == nil, account.lastSyncError == nil {
                            Text("not set up yet").font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.tint.opacity(0.18), in: Capsule())
                        }
                        if let error = account.lastSyncError {
                            Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
                            if ConnectionErrorText.looksLikeAuthFailure(error), !account.kind.isDemo {
                                Button("Update password…") { passwordAccount = account }
                                    .controlSize(.mini)
                            }
                        }
                    }
                    .tag(account.id)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel(for: account))
                    .contextMenu {
                        Button("Run Setup Again…") { onboardingAccount = account }
                        if !account.kind.isDemo {
                            Button("Update Password…") { passwordAccount = account }
                        }
                        Button("Remove Account", role: .destructive) { remove(account) }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if state.maintainer.phase.isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(state.maintainer.phase.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Button {
                    isAddingAccount = true
                } label: {
                    Label("Add Account", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("addAccount")
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func detail(state: AppState) -> some View {
        Group {
            if section == .settings {
                SettingsView(state: state, accounts: accounts)
            } else if isAllAccounts && !accounts.isEmpty {
                switch section {
                case .brief: BriefView(accounts: accounts, state: state)
                default: allAccountsPlaceholder
                }
            } else if let account = selectedAccount, account.lastSyncedAt == nil {
                // An account that has never synced has nothing to show and no
                // obvious next move, so offer the one that matters.
                getStarted(account)
            } else if let account = selectedAccount {
                switch section {
                case .brief: BriefView(accounts: [account], state: state)
                case .senders: SendersView(account: account, state: state)
                case .sweep: SweepView(account: account, state: state)
                case .activity: ActivityView(account: account, state: state)
                case .settings: EmptyView()
                }
            } else {
                emptyState
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $section) {
                    ForEach(AppSection.allCases) { section in
                        Label(section.title, systemImage: section.icon).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("sectionPicker")
            }
        }
    }

    private var allAccountsPlaceholder: some View {
        ContentUnavailableView {
            Label("Pick an account", systemImage: "tray.2")
        } description: {
            Text("\(section.title) works per account. The Brief shows every account together.")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if accounts.isEmpty {
            ContentUnavailableView {
                Label("No account yet", systemImage: "tray")
            } description: {
                Text("Add a mailbox to begin, or try the built-in demo. Grokbox indexes headers only, reads with a model that runs on this Mac, and never modifies mail without you approving a plan first.")
            } actions: {
                Button("Add Account") { isAddingAccount = true }
            }
        } else {
            ContentUnavailableView("Pick an account", systemImage: "sidebar.left",
                                   description: Text("Choose a mailbox in the sidebar, or All Accounts for the combined Brief."))
        }
    }

    /// Honors `--account`, otherwise All Accounts when there is more than one.
    /// Safe to call repeatedly: it only ever fills an empty selection.
    private func chooseInitialSelection() {
        guard selectedAccountID == nil, !accounts.isEmpty else { return }
        if let pick = LaunchOptions.current.account {
            if pick == "all" { selectedAccountID = Self.allAccountsID; return }
            if let index = Int(pick), accounts.indices.contains(index) { selectedAccountID = accounts[index].id; return }
        }
        selectedAccountID = accounts.count > 1 ? Self.allAccountsID : accounts.first?.id
    }

    /// Pixel rectangle of the main window, for scripted screenshots.
    private func logWindowFrame() {
        guard let window = NSApp.windows.first(where: { $0.className != "NSStatusBarWindow" && $0.contentView != nil }),
              let screen = window.screen ?? NSScreen.main else { return }
        let scale = window.backingScaleFactor
        let frame = window.frame
        let top = (screen.frame.maxY - frame.maxY) * scale
        Log.note("window frame px x=\(Int(frame.minX * scale)) y=\(Int(top)) w=\(Int(frame.width * scale)) h=\(Int(frame.height * scale))")
    }

    /// The first thing a newly added account shows: not an empty screen.
    private func getStarted(_ account: MailAccount) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.tint)
            Text("\(account.displayName) is connected").font(.title2.weight(.semibold))
            Text("Nothing has been read yet. Grokbox will look at your mail, work out who fills your inbox, and show you a plan — it changes nothing without your approval.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
            Button("Get started") { onboardingAccount = account }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("getStarted")
            if let error = account.lastSyncError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
                if ConnectionErrorText.looksLikeAuthFailure(error) {
                    Button("Update password…") { passwordAccount = account }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func accessibilityLabel(for account: MailAccount) -> String {
        var parts = [account.displayName, account.username]
        if account.kind.isDemo { parts.append("demo account") }
        if let error = account.lastSyncError { parts.append("error: \(error)") }
        return parts.joined(separator: ", ")
    }

    private func perform(_ command: AppCommand) {
        switch command {
        case .settings: section = .settings
        case .addAccount: isAddingAccount = true
        case .stop:
            state.engine.cancel(); state.executor.cancel(); state.maintainer.cancel()
        case .readNewMail:
            let targets = selectedAccount.map { [$0] } ?? accounts
            Task { await state.readAll(targets) }
        case .tidyUp:
            let targets = selectedAccount.map { [$0] } ?? accounts
            Task { await state.tidyUp(targets) }
        case .index:
            if let account = selectedAccount { section = .senders; state.engine.index(account: account, messageLimit: 1_000) }
            else if let first = accounts.first { selectedAccountID = first.id; section = .senders; state.engine.index(account: first, messageLimit: 1_000) }
        case .summarize:
            section = .brief
            state.refreshDigest(selectedAccount.map { [$0] } ?? accounts)
        }
    }

    private func remove(_ account: MailAccount) {
        state.remove(account)
        if selectedAccountID == account.id { selectedAccountID = accounts.first?.id }
    }
}

// MARK: - Shared bits

/// Status line + progress used by every section that runs an engine.
struct EngineStatusBar: View {
    let label: String
    let fraction: Double?
    let isRunning: Bool
    let isFailed: Bool
    var onStop: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if isRunning {
                ProgressView(value: fraction ?? 0).progressViewStyle(.linear).frame(width: 160)
                    .accessibilityLabel(label)
                if let onStop { Button("Stop", action: onStop).controlSize(.small) }
            }
            Text(label)
                .font(.callout)
                .foregroundStyle(isFailed ? .red : .secondary)
                .lineLimit(1)
                .help(label)
            Spacer()
        }
    }
}

extension MailAccount {
    /// Deep link into Gmail's web UI for a message, by RFC 822 Message-ID.
    func webLink(for message: MessageHeader) -> URL? {
        guard kind == .gmail, let id = message.messageID else { return nil }
        let bare = id.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard let encoded = bare.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "https://mail.google.com/mail/u/0/#search/rfc822msgid%3A\(encoded)")
    }
}
