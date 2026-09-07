import Foundation
import SwiftData

/// A decision the user made once about a sender, so Grokbox never asks again.
///
/// This is what makes the inbox *stay* clean: approving a sweep writes a
/// `sweep` rule, and every later maintenance pass applies it automatically.
/// Rules are global across accounts — a newsletter is a newsletter.
@Model
public final class SenderRule {
    @Attribute(.unique) public var address: String = ""
    public var decisionRaw: String = RuleDecision.sweep.rawValue
    public var createdAt: Date = Date()
    public var timesApplied: Int = 0

    /// Where this sender's mail goes, overriding the policy. Nil means "do
    /// whatever the policy says for this kind of sender" — the common case.
    /// This is how someone says "always bin MegaMart" without turning the
    /// whole policy up.
    public var dispositionRaw: String?

    /// Overrides the policy's automatic unsubscribe for this sender alone.
    /// Nil follows the policy; false means never, even under Thorough; true
    /// means yes, if the sender has a one-click link.
    public var autoUnsubscribeOverride: Bool?

    public var decision: RuleDecision {
        get { RuleDecision(rawValue: decisionRaw) ?? .sweep }
        set { decisionRaw = newValue.rawValue }
    }

    public var disposition: CleanupPolicy.Disposition? {
        get { dispositionRaw.flatMap(CleanupPolicy.Disposition.init(rawValue:)) }
        set { dispositionRaw = newValue?.rawValue }
    }

    /// One line describing everything this rule does, for the UI.
    public var summary: String {
        var parts = [decision.label]
        if let disposition { parts.append("→ \(disposition.label.lowercased())") }
        if autoUnsubscribeOverride == false { parts.append("never unsubscribe") }
        if autoUnsubscribeOverride == true { parts.append("unsubscribe when possible") }
        return parts.joined(separator: ", ")
    }

    public init(address: String, decision: RuleDecision) {
        self.address = address
        self.decisionRaw = decision.rawValue
        self.createdAt = Date()
    }
}

public enum RuleDecision: String, Codable, Sendable, CaseIterable {
    /// Archive and label anything from this sender, now and in future.
    case sweep
    /// Never suggest sweeping this sender again.
    case keep

    public var label: String {
        switch self {
        case .sweep: "Always sweep"
        case .keep: "Always keep"
        }
    }
}

@MainActor
public enum RuleStore {
    public static func all(in context: ModelContext) -> [String: RuleDecision] {
        let rules = (try? context.fetch(FetchDescriptor<SenderRule>())) ?? []
        return Dictionary(rules.map { ($0.address, $0.decision) }, uniquingKeysWith: { a, _ in a })
    }

    /// Every rule, whole — what the plan needs to honour per-sender overrides.
    public static func overrides(in context: ModelContext) -> [String: SenderOverride] {
        let rules = (try? context.fetch(FetchDescriptor<SenderRule>())) ?? []
        return Dictionary(rules.map { ($0.address, SenderOverride(decision: $0.decision, disposition: $0.disposition, autoUnsubscribe: $0.autoUnsubscribeOverride)) },
                          uniquingKeysWith: { a, _ in a })
    }

    /// Sets or clears the per-sender disposition without touching the
    /// sweep/keep decision.
    public static func setDisposition(_ disposition: CleanupPolicy.Disposition?, for address: String, in context: ModelContext) {
        let rule = existingOrNew(address, in: context)
        rule.disposition = disposition
        try? context.save()
    }

    public static func setAutoUnsubscribe(_ allowed: Bool?, for address: String, in context: ModelContext) {
        let rule = existingOrNew(address, in: context)
        rule.autoUnsubscribeOverride = allowed
        try? context.save()
    }

    private static func existingOrNew(_ address: String, in context: ModelContext) -> SenderRule {
        let descriptor = FetchDescriptor<SenderRule>(predicate: #Predicate { $0.address == address })
        if let existing = try? context.fetch(descriptor).first { return existing }
        // A disposition on its own implies "sweep this sender": you would not
        // say where mail goes for a sender you never sweep.
        let rule = SenderRule(address: address, decision: .sweep)
        context.insert(rule)
        return rule
    }

    public static func set(_ decision: RuleDecision, for address: String, in context: ModelContext) {
        let descriptor = FetchDescriptor<SenderRule>(predicate: #Predicate { $0.address == address })
        if let existing = try? context.fetch(descriptor).first {
            existing.decision = decision
        } else {
            context.insert(SenderRule(address: address, decision: decision))
        }
        try? context.save()
    }

    public static func clear(for address: String, in context: ModelContext) {
        let descriptor = FetchDescriptor<SenderRule>(predicate: #Predicate { $0.address == address })
        for rule in (try? context.fetch(descriptor)) ?? [] {
            context.delete(rule)
        }
        try? context.save()
    }

    /// Rules whose sender appears in no account any more.
    ///
    /// Rules are global on purpose — a newsletter is a newsletter, whichever
    /// mailbox it lands in — but a rule about a sender you can no longer
    /// receive mail from is dead weight, and worse than that: rules from a
    /// removed demo mailbox would still steer a real one.
    public static func orphaned(in context: ModelContext) -> [SenderRule] {
        let known = Set(((try? context.fetch(FetchDescriptor<SenderProfile>())) ?? []).map(\.address))
        let rules = (try? context.fetch(FetchDescriptor<SenderRule>())) ?? []
        return rules.filter { !known.contains($0.address) }
    }

    @discardableResult
    public static func clearOrphaned(in context: ModelContext) -> Int {
        let dead = orphaned(in: context)
        for rule in dead { context.delete(rule) }
        if !dead.isEmpty { try? context.save() }
        return dead.count
    }

    public static func bumpApplied(for addresses: [String], in context: ModelContext) {
        let wanted = Set(addresses)
        for rule in (try? context.fetch(FetchDescriptor<SenderRule>())) ?? [] where wanted.contains(rule.address) {
            rule.timesApplied += 1
        }
        try? context.save()
    }
}


/// A sender's rule, flattened for the planner.
public struct SenderOverride: Sendable, Equatable {
    public var decision: RuleDecision
    public var disposition: CleanupPolicy.Disposition?
    public var autoUnsubscribe: Bool?

    public init(decision: RuleDecision, disposition: CleanupPolicy.Disposition? = nil, autoUnsubscribe: Bool? = nil) {
        self.decision = decision
        self.disposition = disposition
        self.autoUnsubscribe = autoUnsubscribe
    }
}
