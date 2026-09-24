import Foundation

/// Keeps one read-only connection per account idling on its inbox (IMAP
/// IDLE, RFC 2177) and reports new mail as it arrives, so an automatic
/// tidy-up can run then instead of waiting for its timer.
///
/// Inbox only, as Thunderbird for Android does by default: one connection
/// per watched folder, and servers cap connections. It listens and nothing
/// else; the mailbox is opened with `EXAMINE`. A server without IDLE is
/// left to the timer. Demo accounts are never watched.
@MainActor
public final class InboxWatcher {
    /// Called on the main actor with the account that has new mail.
    public var onNewMail: (@MainActor (UUID) -> Void)?
    /// Milestones for the app's log: account labels and states, no contents.
    public var onLog: (@MainActor (String) -> Void)?

    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// RFC 2177 asks for IDLE to be re-issued within 29 minutes.
    static let idleWindow: Duration = .seconds(25 * 60)

    public init() {}

    /// Watches exactly these accounts, or none when `enabled` is false.
    /// Accounts already being watched are left alone.
    public func watch(_ accounts: [MailAccount], enabled: Bool) {
        let wanted = enabled ? Dictionary(accounts.filter { !$0.kind.isDemo }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) : [:]
        for (id, task) in tasks where wanted[id] == nil {
            task.cancel()
            tasks[id] = nil
        }
        for (id, account) in wanted where tasks[id] == nil {
            tasks[id] = Task { [weak self] in await self?.run(account) }
        }
    }

    public func stopAll() { watch([], enabled: false) }

    /// Stops watching one account at once. Must be called before the account
    /// is deleted: the watcher reconnects with the account's own settings.
    public func forget(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    private func run(_ account: MailAccount) async {
        let id = account.id
        let name = account.displayName
        var backoff: Duration = .seconds(30)
        while !Task.isCancelled {
            var provider: (any MailProvider)?
            do {
                let connected = try await MailProviderFactory.connect(to: account)
                provider = connected
                guard await connected.capabilities.supportsIdle else {
                    onLog?("watcher: \(name) has no IDLE; the timer covers it")
                    await connected.finish()
                    tasks[id] = nil
                    return
                }
                _ = try await connected.openReadOnly("INBOX")
                onLog?("watcher: idling on \(name)'s inbox")
                backoff = .seconds(30)
                while !Task.isCancelled {
                    if try await connected.waitForNewMail(maxWait: Self.idleWindow) {
                        onNewMail?(id)
                    }
                }
            } catch {
                if Task.isCancelled { break }
                onLog?("watcher: \(name) dropped (\(error.localizedDescription)); retrying in \(backoff)")
            }
            await provider?.abort()
            if Task.isCancelled { return }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(15 * 60))
        }
        // Cancelled: close without a LOGOUT, since an IDLE may be in flight.
    }
}
