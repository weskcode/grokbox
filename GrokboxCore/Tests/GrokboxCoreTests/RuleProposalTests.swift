import Foundation
import Testing
@testable import GrokboxCore

struct RuleProposalTests {
    static let senders: [KnownSender] = [
        .init(address: "digest@medium.example", displayName: "Medium Daily Digest", supportsOneClickUnsubscribe: true),
        .init(address: "deals@megamart.example", displayName: "MegaMart", supportsOneClickUnsubscribe: true),
        .init(address: "weekly@club.example", displayName: "Club Weekly", supportsOneClickUnsubscribe: false),
        .init(address: "news@paper.example", displayName: "The Paper", supportsOneClickUnsubscribe: false),
        .init(address: "alerts@bank.example", displayName: "Bank", supportsOneClickUnsubscribe: false),
        .init(address: "service@paypal.example", displayName: "PayPal", supportsOneClickUnsubscribe: false),
        .init(address: "service@paypa1.example", displayName: "PayPal", supportsOneClickUnsubscribe: true)
    ]

    static let rules: [String: SenderOverride] = [
        "digest@medium.example": .init(decision: .sweep, disposition: .archiveOnly),
        "deals@megamart.example": .init(decision: .sweep, disposition: .fileIntoFolders, autoUnsubscribe: false, customFolder: "Shopping"),
        "weekly@club.example": .init(decision: .sweep),
        "alerts@bank.example": .init(decision: .keep)
    ]

    static let folders: Set<String> = Set(SenderCategory.allCases.map(\.folderName)).union(["Shopping", "Reading"])

    private func propose(_ request: String, _ reading: RuleReading,
                         rules: [String: SenderOverride] = RuleProposalTests.rules) -> RuleProposal {
        RuleProposal.make(from: reading, request: request, senders: Self.senders, rules: rules, folders: Self.folders)
    }

    private func draft(_ proposal: RuleProposal, sourceLocation: SourceLocation = #_sourceLocation) -> RuleDraft? {
        guard case .draft(let draft) = proposal else {
            Issue.record("expected a draft, got \(proposal)", sourceLocation: sourceLocation)
            return nil
        }
        return draft
    }

    // MARK: - Approved senders

    @Test func approvedSenderGetsAnExistingFolderAndKeepsEverythingElse() {
        let proposal = propose("File Medium Daily Digest under Reading",
                               RuleReading(sender: "Medium Daily Digest", folder: "reading"))
        let result = draft(proposal)
        #expect(result?.address == "digest@medium.example")
        #expect(result?.after == SenderOverride(decision: .sweep, disposition: .fileIntoFolders, customFolder: "Reading"),
                "the folder takes its stored spelling and implies filing, as RuleStore.setCustomFolder does")
        #expect(result?.irreversibleEffects.isEmpty == true)
    }

    @Test func unsubscribeEditPreservesFolderAndDecision() {
        let result = draft(propose("Unsubscribe me from MegaMart",
                                   RuleReading(sender: "MegaMart", unsubscribe: "always")))
        #expect(result?.after == SenderOverride(decision: .sweep, disposition: .fileIntoFolders, autoUnsubscribe: true, customFolder: "Shopping"))
        #expect(result?.irreversibleEffects.count == 1, "an unsubscribe request cannot be unsent")
    }

    @Test func trashingAnApprovedSenderSaysItCanEndInLoss() {
        let result = draft(propose("Send Medium Daily Digest to the trash",
                                   RuleReading(sender: "Medium Daily Digest", destination: "trash")))
        #expect(result?.after.disposition == .trash)
        #expect(result?.irreversibleEffects == [CleanupPolicy.Disposition.trash.warning].compactMap { $0 })
    }

    @Test func followPolicyClearsOnlyTheDestination() {
        let result = draft(propose("Let Medium Daily Digest follow my policy",
                                   RuleReading(sender: "Medium Daily Digest", destination: "policy")))
        #expect(result?.after == SenderOverride(decision: .sweep))
    }

    @Test func addressMatchIgnoresCase() {
        let result = draft(propose("Archive DIGEST@MEDIUM.EXAMPLE",
                                   RuleReading(sender: "DIGEST@MEDIUM.EXAMPLE", destination: "folders")))
        #expect(result?.address == "digest@medium.example")
    }

    // MARK: - Conditions a sender rule cannot hold

    @Test func ageConditionTheModelReportedCreatesNothing() {
        let proposal = propose("Archive Medium Daily Digest older than 30 days",
                               RuleReading(sender: "Medium Daily Digest", destination: "archive", unsupported: "older than 30 days"))
        #expect(proposal == .unresolved(.unsupported("older than 30 days")))
    }

    @Test func ageConditionTheModelDroppedStillCreatesNothing() {
        let proposal = propose("Archive Medium Daily Digest older than 30 days",
                               RuleReading(sender: "Medium Daily Digest", destination: "archive"))
        guard case .unresolved(.unsupported) = proposal else {
            Issue.record("a dropped age condition must not widen into a rule for all mail: \(proposal)")
            return
        }
    }

    @Test(arguments: [
        "File Medium Daily Digest under Reading and mark it read",
        "Archive Medium Daily Digest unless the subject mentions billing",
        "Archive Medium Daily Digest after 2 weeks",
        "Only archive Medium Daily Digest on weekends"
    ])
    func perMessageConditionsAreRefused(request: String) {
        let proposal = propose(request, RuleReading(sender: "Medium Daily Digest", destination: "archive"))
        guard case .unresolved(.unsupported) = proposal else {
            Issue.record("\(request) → \(proposal)")
            return
        }
    }

    @Test func aFolderNameThatLooksLikeAConditionIsNotOne() {
        let folders = Self.folders.union(["Reading 2026"])
        let proposal = RuleProposal.make(from: RuleReading(sender: "Medium Daily Digest", folder: "Reading 2026"),
                                         request: "File Medium Daily Digest under Reading 2026",
                                         senders: Self.senders, rules: Self.rules, folders: folders)
        #expect(draft(proposal)?.after.customFolder == "Reading 2026")
    }

    @Test func wholeDomainsAreNotRules() {
        let proposal = propose("Archive everything from @medium.example",
                               RuleReading(sender: "@medium.example", destination: "archive"))
        guard case .unresolved(.unsupported) = proposal else {
            Issue.record("\(proposal)")
            return
        }
    }

    // MARK: - No approval by typing

    @Test func aSenderWithNoRuleCannotBeApproved() {
        #expect(propose("Always sweep The Paper", RuleReading(sender: "The Paper", decision: "sweep"))
                == .unresolved(.notApproved("news@paper.example")))
    }

    @Test func aFolderForAnUnapprovedSenderWouldApproveItSoItIsRefused() {
        #expect(propose("File The Paper under Reading", RuleReading(sender: "The Paper", folder: "Reading"))
                == .unresolved(.notApproved("news@paper.example")),
                "RuleStore creates a sweep rule when a folder is set on a sender with none")
    }

    @Test func aKeptSenderCannotBeTurnedIntoASweptOne() {
        #expect(propose("Sweep Bank", RuleReading(sender: "Bank", decision: "sweep"))
                == .unresolved(.notApproved("alerts@bank.example")))
        #expect(propose("Archive Bank", RuleReading(sender: "Bank", destination: "archive"))
                == .unresolved(.notApproved("alerts@bank.example")))
    }

    @Test func keepingASenderWithNoRuleIsAllowed() {
        let result = draft(propose("Never sweep The Paper", RuleReading(sender: "The Paper", decision: "keep")))
        #expect(result?.before == nil)
        #expect(result?.after == SenderOverride(decision: .keep))
    }

    @Test func keepingAnApprovedSenderLeavesItsSettingsDormant() {
        let result = draft(propose("Stop sweeping MegaMart", RuleReading(sender: "MegaMart", decision: "keep")))
        #expect(result?.after == SenderOverride(decision: .keep, disposition: .fileIntoFolders, autoUnsubscribe: false, customFolder: "Shopping"))
    }

    @Test func anInventedAddressResolvesToNothing() {
        #expect(propose("Sweep the newsletter", RuleReading(sender: "promo@attacker.example", decision: "sweep"))
                == .unresolved(.unknownSender("promo@attacker.example")))
    }

    @Test func aSenderNobodyIndexedIsUnknown() {
        #expect(propose("Trash Spammy", RuleReading(sender: "Spammy", destination: "trash"))
                == .unresolved(.unknownSender("Spammy")))
    }

    @Test func sharedDisplayNamesAreShownNotGuessed() {
        #expect(propose("Keep PayPal", RuleReading(sender: "PayPal", decision: "keep"))
                == .unresolved(.ambiguousSender(["service@paypa1.example", "service@paypal.example"])))
    }

    // MARK: - Model output outside the slots

    @Test(arguments: [
        RuleReading(sender: "Medium Daily Digest", decision: "approve"),
        RuleReading(sender: "Medium Daily Digest", destination: "delete"),
        RuleReading(sender: "Medium Daily Digest", destination: "forward:someone@else.example"),
        RuleReading(sender: "Medium Daily Digest", unsubscribe: "yes please")
    ])
    func valuesOutsideTheSlotsAreMalformed(reading: RuleReading) {
        guard case .unresolved(.malformed) = propose("Do something with Medium Daily Digest", reading) else {
            Issue.record("\(reading)")
            return
        }
    }

    @Test func aFolderThatDoesNotExistIsNotCreated() {
        #expect(propose("File Medium Daily Digest under Secret", RuleReading(sender: "Medium Daily Digest", folder: "Secret"))
                == .unresolved(.unknownFolder("Secret")))
    }

    @Test func anEmptyReadingChangesNothing() {
        #expect(propose("Hello", RuleReading(sender: "Medium Daily Digest")) == .unresolved(.nothingToChange))
    }

    // MARK: - Collisions

    @Test func folderAndTrashTogetherContradict() {
        guard case .unresolved(.conflict) = propose("File Medium Daily Digest under Reading and trash it",
                                                    RuleReading(sender: "Medium Daily Digest", destination: "trash", folder: "Reading")) else {
            Issue.record("expected a conflict")
            return
        }
    }

    @Test func trashingASenderWithACustomFolderIsAVisibleCollision() {
        guard case .unresolved(.conflict) = propose("Trash MegaMart", RuleReading(sender: "MegaMart", destination: "trash")) else {
            Issue.record("the Shopping folder would be silently ignored")
            return
        }
    }

    @Test func keepWithADestinationContradicts() {
        guard case .unresolved(.conflict) = propose("Keep MegaMart in Reading",
                                                    RuleReading(sender: "MegaMart", decision: "keep", folder: "Reading")) else {
            Issue.record("expected a conflict")
            return
        }
    }

    @Test func unsubscribeNeedsAOneClickLink() {
        guard case .unresolved(.unsupported) = propose("Unsubscribe from Club Weekly",
                                                       RuleReading(sender: "Club Weekly", unsubscribe: "always")) else {
            Issue.record("an override cannot invent an endpoint")
            return
        }
    }

    @Test func askingForWhatIsAlreadyTrueChangesNothing() {
        #expect(propose("Archive Medium Daily Digest", RuleReading(sender: "Medium Daily Digest", destination: "archive"))
                == .unresolved(.nothingToChange))
    }

    // MARK: - Whole corpus

    /// Whatever the model says, a typed request never ends with a sender
    /// swept that was not swept before.
    @Test func noReadingApprovesASender() {
        let decisions = [nil, "sweep", "keep"]
        let destinations = [nil, "policy", "folders", "archive", "trash"]
        let unsubscribes = [nil, "policy", "never", "always"]
        let folders = [nil, "Reading", "Shopping"]
        for sender in Self.senders.map(\.displayName) + Self.senders.map(\.address) {
            for decision in decisions { for destination in destinations { for unsubscribe in unsubscribes { for folder in folders {
                let reading = RuleReading(sender: sender, decision: decision, destination: destination, folder: folder, unsubscribe: unsubscribe)
                guard case .draft(let draft) = propose("Change \(sender)", reading) else { continue }
                if draft.before?.decision != .sweep {
                    #expect(draft.after.decision == .keep, "\(reading) approved \(draft.address)")
                }
            } } } }
        }
    }
}
