import Foundation
import LocalAuthentication

/// Prompts for Face ID/Touch ID to unlock the app, falling back to the
/// device passcode/password so someone without biometrics enrolled is never
/// locked out of their own mail. Gates only the app's own UI — never touches
/// a Keychain item, and never gets between the user and their mail server.
public enum BiometricAuthenticator {
    public static func unlock(reason: String = "Unlock Grokbox") async -> Bool {
        let context = LAContext()
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else { return false }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
