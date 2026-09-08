import Foundation
import Testing
@testable import GrokboxCore

/// The credential hints are the first thing a new person reads, and the most
/// common place setup fails. They must name the right thing for the provider
/// they are looking at.
struct CredentialHintTests {
    @Test func gmailSaysAppPasswordAndWhy() {
        let hint = AccountKind.gmail.credentialHint
        #expect(hint.localizedCaseInsensitiveContains("app password"))
        #expect(hint.localizedCaseInsensitiveContains("2-step") || hint.localizedCaseInsensitiveContains("two-step"))
        #expect(hint.localizedCaseInsensitiveContains("will not work"), "it must say the normal password is rejected")
    }

    @Test func protonNamesBridgeAndItsOwnPassword() {
        let hint = AccountKind.protonBridge.credentialHint
        #expect(hint.localizedCaseInsensitiveContains("bridge"))
        #expect(hint.localizedCaseInsensitiveContains("not your proton password"))
        #expect(hint.localizedCaseInsensitiveContains("ssl"))
    }

    @Test func demoNeedsNothing() {
        #expect(AccountKind.demo.credentialHint.localizedCaseInsensitiveContains("no password"))
    }
}
