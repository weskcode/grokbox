import SwiftUI
import SwiftData
import GrokboxCore

/// The phone is the Brief in your pocket. Heavy lifting — deep indexing,
/// thousand-message sweeps — is a Mac job; here the point is to see what
/// needs you and deal with it in a minute.
struct PhoneRootView: View {
    @Environment(AppState.self) private var state
    @Query(sort: \MailAccount.createdAt) private var accounts: [MailAccount]
    @State private var scope: UUID?          // nil = all accounts
    @State private var addingAccount = false
    @State private var onboarding: MailAccount?
    /// `--section senders` at launch opens on that tab (screenshots, tests).
    @State private var tab: AppSection = LaunchOptions.current.section ?? .brief

    private var scoped: [MailAccount] {
        guard let scope, let one = accounts.first(where: { $0.id == scope }) else { return accounts }
        return [one]
    }

    var body: some View {
        Group {
            if accounts.isEmpty {
                welcome
            } else {
                TabView(selection: $tab) {
                    Tab("Brief", systemImage: "sun.horizon", value: AppSection.brief) { NavigationStack { PhoneBriefView(accounts: scoped).toolbar { scopeMenu } } }
                    Tab("Senders", systemImage: "person.2", value: AppSection.senders) { NavigationStack { PhoneSendersView(account: scoped.first ?? accounts[0]).toolbar { scopeMenu } } }
                    Tab("Sweep", systemImage: "wind", value: AppSection.sweep) { NavigationStack { PhoneSweepView(account: scoped.first ?? accounts[0]).toolbar { scopeMenu } } }
                    Tab("Activity", systemImage: "clock.arrow.circlepath", value: AppSection.activity) { NavigationStack { PhoneActivityView(accounts: scoped).toolbar { scopeMenu } } }
                    Tab("Settings", systemImage: "gearshape", value: AppSection.settings) { NavigationStack { PhoneSettingsView(accounts: accounts, addAccount: { addingAccount = true }) } }
                }
            }
        }
        .sheet(isPresented: $addingAccount) { PhoneAddAccountView(onCreate: { onboarding = $0 }) }
        .sheet(item: $onboarding) { account in
            NavigationStack { AccountOnboarding(account: account, state: state) }
        }
        .task {
            Log.note("phone root appeared")
            await state.startIfNeeded()
            if let recovery = AppEnvironment.opened.recovery { state.storeRecovery = recovery }
        }
    }

    private var scopeMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button { scope = nil } label: { Label("All accounts", systemImage: scope == nil ? "checkmark" : "tray.2") }
                Divider()
                ForEach(accounts) { account in
                    Button { scope = account.id } label: {
                        Label(account.displayName, systemImage: scope == account.id ? "checkmark" : "tray")
                    }
                }
            } label: {
                Label(scoped.count == 1 && accounts.count > 1 ? scoped[0].displayName : "All accounts", systemImage: "tray.2")
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityLabel("Account scope")
            .accessibilityIdentifier("scopeMenu")
        }
    }

    private var welcome: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "tray").font(.system(size: 52)).foregroundStyle(.secondary)
                Text("No account yet").font(.title2.weight(.semibold))
                Text("Add a mailbox, or try the built-in demo. Grokbox indexes headers only, reads with a model on this device, and never changes mail without a plan you approved.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
                Button("Add Account") { addingAccount = true }.buttonStyle(.borderedProminent)
                Button("Try the demo") { Task { _ = await state.addDemoAccounts() } }
            }
            .padding()
            .navigationTitle("Grokbox")
        }
    }
}

/// Status line + progress, shared by every tab that runs an engine.
struct PhoneStatusRow: View {
    let label: String
    let fraction: Double?
    let isRunning: Bool
    let isFailed: Bool
    var onStop: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if isRunning {
                ProgressView(value: fraction ?? 0).frame(maxWidth: 120).accessibilityLabel(label)
                if let onStop { Button("Stop", action: onStop).font(.caption) }
            }
            Text(label).font(.footnote).foregroundStyle(isFailed ? .red : .secondary).lineLimit(2)
            Spacer()
        }
    }
}
