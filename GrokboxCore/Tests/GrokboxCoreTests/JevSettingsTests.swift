import Foundation
import Testing
@testable import GrokboxCore

struct JevSettingsModelTests {
    @Test func defaultIsDisabled() {
        let empty = UserDefaults(suiteName: "grokbox.tests.jev.empty.\(UUID().uuidString)")!
        #expect(JevSettings.load(from: empty) == .disabled)
    }

    @Test func roundTripsThroughDefaults() {
        let defaults = UserDefaults(suiteName: "grokbox.tests.jev.\(UUID().uuidString)")!
        let settings = JevSettings(enabled: true)
        JevSettings.save(settings, to: defaults)
        #expect(JevSettings.load(from: defaults) == settings)
    }
}
