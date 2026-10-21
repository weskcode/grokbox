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

    /// Where this sender's mail files, overriding the category's default
    /// folder. Nil means "use the category's folder" — the common case.
    /// Setting one always implies `.fileIntoFolders`; see
    /// `RuleStore.setCustomFolder`, which is the only way this is written.
    public var customFolder: String?

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
        if let customFolder { parts.append("→ \(customFolder)") }
        else if let disposition { parts.append("→ \(disposition.label.lowercased())") }
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
        return Dictionary(rules.map { ($0.address, SenderOverride(rule: $0)) }, uniquingKeysWith: { a, _ in a })
    }

    /// This sender's rule, whole, or nil when there is none. Unlike
    /// `overrides(in:)` a failed lookup is thrown, not read as "no rule".
    static func override(for address: String, in context: ModelContext) throws -> SenderOverride? {
        try context.fetch(FetchDescriptor<SenderRule>(predicate: #Predicate { $0.address == address }))
            .first.map(SenderOverride.init(rule:))
    }

    /// The one way a rule is written. The preview applies the same `RuleEdit`
    /// to the same starting point, so what it shows is what gets saved.
    ///
    /// A failed save is undone in memory before it is thrown. Otherwise the
    /// context keeps showing a rule the store never accepted, and a later
    /// autosave can quietly commit what the person was told had failed.
    public static func apply(_ edit: RuleEdit, for address: String, in context: ModelContext) throws {
        let existing: [SenderRule]
        do {
            existing = try context.fetch(FetchDescriptor<SenderRule>(predicate: #Predicate { $0.address == address }))
        } catch {
            throw RuleSaveError(address: address, underlying: error.localizedDescription)
        }
        let before = existing.first.map(SenderOverride.init(rule:))
        guard let after = edit.applied(to: before) else {
            // Deleted at the store, not marked for deletion in the context: a
            // refused delete then leaves nothing pending to undo.
            do {
                try context.delete(model: SenderRule.self, where: #Predicate { $0.address == address })
                try context.save()
            } catch {
                throw RuleSaveError(address: address, underlying: error.localizedDescription)
            }
            return
        }

        var inserted: SenderRule?
        if let rule = existing.first {
            after.write(to: rule)
        } else {
            let rule = SenderRule(address: address, decision: after.decision)
            after.write(to: rule)
            context.insert(rule)
            inserted = rule
        }

        do {
            try context.save()
        } catch {
            if let inserted {
                context.delete(inserted)
            } else if let rule = existing.first, let before {
                before.write(to: rule)
            }
            throw RuleSaveError(address: address, underlying: error.localizedDescription)
        }
    }

    public static func set(_ decision: RuleDecision, for address: String, in context: ModelContext) throws {
        try apply(.decision(decision), for: address, in: context)
    }

    /// Sets or clears the per-sender disposition without touching the
    /// sweep/keep decision.
    public static func setDisposition(_ disposition: CleanupPolicy.Disposition?, for address: String, in context: ModelContext) throws {
        try apply(.disposition(disposition), for: address, in: context)
    }

    public static func setAutoUnsubscribe(_ allowed: Bool?, for address: String, in context: ModelContext) throws {
        try apply(.autoUnsubscribe(allowed), for: address, in: context)
    }

    /// Sets or clears the per-sender custom folder. Setting one always forces
    /// `disposition = .fileIntoFolders`, so a folder pick can never be
    /// silently discarded by a trash/archive-only disposition.
    public static func setCustomFolder(_ folder: String?, for address: String, in context: ModelContext) throws {
        try apply(.customFolder(folder), for: address, in: context)
    }

    public static func clear(for address: String, in context: ModelContext) throws {
        try apply(.clear, for: address, in: context)
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
    public var customFolder: String?

    public init(decision: RuleDecision, disposition: CleanupPolicy.Disposition? = nil,
               autoUnsubscribe: Bool? = nil, customFolder: String? = nil) {
        self.decision = decision
        self.disposition = disposition
        self.autoUnsubscribe = autoUnsubscribe
        self.customFolder = customFolder
    }
}

/// A change to one sender's rule, as the Senders and Sweep screens make it.
public enum RuleEdit: Sendable, Equatable {
    case decision(RuleDecision)
    case disposition(CleanupPolicy.Disposition?)
    case autoUnsubscribe(Bool?)
    case customFolder(String?)
    case clear

    /// The rule after this edit, or nil when the edit removes it.
    ///
    /// A disposition, unsubscribe or folder on its own implies "sweep this
    /// sender": you would not say where mail goes for a sender you never
    /// sweep. A folder always implies filing into folders.
    func applied(to current: SenderOverride?) -> SenderOverride? {
        if case .clear = self { return nil }
        var rule = current ?? SenderOverride(decision: .sweep)
        switch self {
        case .decision(let decision):
            rule.decision = decision
        case .disposition(let disposition):
            rule.disposition = disposition
        case .autoUnsubscribe(let allowed):
            rule.autoUnsubscribe = allowed
        case .customFolder(let folder):
            rule.customFolder = folder
            if folder != nil { rule.disposition = .fileIntoFolders }
        case .clear:
            break
        }
        return rule
    }
}

/// A rule edit that did not reach the store. Nothing was changed.
public struct RuleSaveError: LocalizedError, Equatable {
    public let address: String
    public let underlying: String

    public var errorDescription: String? {
        "Grokbox couldn't save the rule for \(address), so nothing changed. \(underlying)"
    }
}

extension SenderOverride {
    init(rule: SenderRule) {
        self.init(decision: rule.decision, disposition: rule.disposition,
                  autoUnsubscribe: rule.autoUnsubscribeOverride, customFolder: rule.customFolder)
    }

    func write(to rule: SenderRule) {
        rule.decision = decision
        rule.disposition = disposition
        rule.autoUnsubscribeOverride = autoUnsubscribe
        rule.customFolder = customFolder
    }
}
