import SwiftUI
import GrokboxCore

/// The settings that decide what a sweep actually does. Presented as three
/// named starting points plus the individual dials, because "how aggressive
/// should this be" is a feeling first and a set of numbers second.
struct CleanupPolicyEditor: View {
    @Binding var policy: CleanupPolicy

    var body: some View {
        Section("How Grokbox cleans") {
            Picker("Approach", selection: presetBinding) {
                ForEach([CleanupPolicy.Preset.gentle, .balanced, .thorough]) { preset in
                    Text(preset.label).tag(preset)
                }
                if policy.matchingPreset == .custom { Text("Custom").tag(CleanupPolicy.Preset.custom) }
            }
            .pickerStyle(.segmented)
            Text(policy.matchingPreset == .custom ? policy.summary : CleanupPolicy.Preset.blurbOrSummary(policy))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("This policy will: \(policy.summary)")
        }

        Section("Where swept mail goes") {
            Picker("Everything else", selection: $policy.disposition) {
                ForEach(CleanupPolicy.Disposition.allCases) { d in Text(d.label).tag(d) }
            }
            Text(policy.disposition.explanation).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = policy.disposition.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            Picker("Promotions", selection: promotionBinding) {
                Text("Same as everything else").tag(nil as CleanupPolicy.Disposition?)
                ForEach(CleanupPolicy.Disposition.allCases) { d in Text(d.label).tag(d as CleanupPolicy.Disposition?) }
            }
            if let promo = policy.promotionDisposition, let warning = promo.warning {
                Label("Promotions: \(warning)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Mark swept mail as read", isOn: $policy.markRead)
        }

        Section("What is never swept") {
            Picker("Keep anything from the last", selection: $policy.protectRecentDays) {
                Text("No limit").tag(0)
                Text("1 day").tag(1)
                Text("2 days").tag(2)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }
            Picker("Always keep the newest", selection: $policy.keepNewestPerSender) {
                Text("None").tag(0)
                Text("1 per sender").tag(1)
                Text("2 per sender").tag(2)
                Text("5 per sender").tag(5)
            }
            Toggle("Receipts, orders, appointments and security mail", isOn: $policy.guardTransactional)
            Toggle("Senders you have written to", isOn: $policy.guardContacted)
            Text("Flagged mail and anything the model says needs you are always kept, whatever these say.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }

        Section("Unsubscribing") {
            Picker("Unsubscribe", selection: $policy.unsubscribe) {
                ForEach(CleanupPolicy.UnsubscribeMode.allCases) { mode in Text(mode.label).tag(mode) }
            }
            if policy.unsubscribe == .automaticOneClick {
                Picker("Only if at least this much is unread", selection: $policy.autoUnsubscribeMinimumUnreadRatio) {
                    Text("75%").tag(0.75)
                    Text("90%").tag(0.9)
                    Text("95%").tag(0.95)
                }
                Picker("And at least this many messages", selection: $policy.autoUnsubscribeMinimumMessages) {
                    Text("5").tag(5)
                    Text("10").tag(10)
                    Text("20").tag(20)
                }
                Toggle("Only senders you have never written to", isOn: $policy.autoUnsubscribeRequiresNeverContacted)
                Text("Grokbox only uses the sender's own one-click link (RFC 8058). Anything needing a browser is left for you in Senders. An unsubscribe cannot be undone.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var presetBinding: Binding<CleanupPolicy.Preset> {
        Binding(get: { policy.matchingPreset },
                set: { chosen in if chosen != .custom { policy = CleanupPolicy.preset(chosen) } })
    }

    private var promotionBinding: Binding<CleanupPolicy.Disposition?> {
        Binding(get: { policy.promotionDisposition }, set: { policy.promotionDisposition = $0 })
    }
}

extension CleanupPolicy.Preset {
    /// The preset's blurb when the policy is one, its own summary otherwise.
    static func blurbOrSummary(_ policy: CleanupPolicy) -> String {
        policy.matchingPreset == .custom ? policy.summary : policy.matchingPreset.blurb + "\n\n" + policy.summary
    }
}
