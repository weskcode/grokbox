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

    public var decision: RuleDecision {
        get { RuleDecision(rawValue: decisionRaw) ?? .sweep }
        set { decisionRaw = newValue.rawValue }
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

    public static func bumpApplied(for addresses: [String], in context: ModelContext) {
        let wanted = Set(addresses)
        for rule in (try? context.fetch(FetchDescriptor<SenderRule>())) ?? [] where wanted.contains(rule.address) {
            rule.timesApplied += 1
        }
        try? context.save()
    }
}
