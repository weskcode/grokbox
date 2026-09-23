import Foundation
import Testing
@testable import GrokboxCore

struct BiometricLockSettingsModelTests {
    @Test func defaultIsDisabled() {
        let empty = UserDefaults(suiteName: "grokbox.tests.biometric.empty.\(UUID().uuidString)")!
        #expect(BiometricLockSettings.load(from: empty) == .disabled)
    }

    @Test func roundTripsThroughDefaults() {
        let defaults = UserDefaults(suiteName: "grokbox.tests.biometric.\(UUID().uuidString)")!
        let settings = BiometricLockSettings(enabled: true)
        BiometricLockSettings.save(settings, to: defaults)
        #expect(BiometricLockSettings.load(from: defaults) == settings)
    }
}
