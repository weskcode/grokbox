import SwiftUI
import GrokboxCore

/// Shown instead of the app's normal content when biometric lock is on and
/// this launch has not yet passed it. Reuses the same empty-state visual
/// language as `RootView`'s own empty states rather than inventing a new one.
struct LockView: View {
    let state: AppState

    @State private var isUnlocking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Grokbox is locked").font(.title2.weight(.semibold))
            Text("Unlock with Face ID or Touch ID to see your mail.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
            Button("Unlock Grokbox") { Task { await unlock() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isUnlocking)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .task { await unlock() }
    }

    private func unlock() async {
        guard !isUnlocking, !state.isUnlocked else { return }
        isUnlocking = true
        let success = await BiometricAuthenticator.unlock()
        isUnlocking = false
        if success {
            errorMessage = nil
            state.isUnlocked = true
        } else {
            errorMessage = "Could not verify it's you. Try again."
        }
    }
}
