import Foundation
import Testing
@testable import GrokboxCore

struct RuleProposalTests {
    static let senders: [KnownSender] = [
        .init(address: "digest@medium.example", displayName: "Medium Daily Digest", category: .newsletter, supportsOneClickUnsubscribe: true),
        .init(address: "deals@megamart.example", displayName: "MegaMart", category: .promotion, supportsOneClickUnsubscribe: true),
        .init(address: "offers@shop.example", displayName: "Shop Offers", category: .promotion, supportsOneClickUnsubscribe: false),
        .init(address: "weekly@club.example", displayName: "Club Weekly", category: .newsletter, supportsOneClickUnsubscribe: false),
        .init(address: "photos@life.example", displayName: "Life in Pictures", category: .newsletter, supportsOneClickUnsubscribe: false),
        .init(address: "news@paper.example", displayName: "The Paper", category: .newsletter, supportsOneClickUnsubscribe: false),
        .init(address: "alerts@bank.example", displayName: "Bank", category: .transactional, supportsOneClickUnsubscribe: false),
        .init(address: "service@paypal.example", displayName: "PayPal", category: .transactional, supportsOneClickUnsubscribe: false),
        .init(address: "service@paypa1.example", displayName: "PayPal", category: .promotion, supportsOneClickUnsubscribe: true),
        .init(address: "promo@paypal-deals.example", displayName: "PayPal!", category: .promotion, supportsOneClickUnsubscribe: true)
    ]

    static let rules: [String: SenderOverride] = [
        "digest@medium.example": .init(decision: .sweep, disposition: .archiveOnly),
        "deals@megamart.example": .init(decision: .sweep, disposition: .fileIntoFolders, autoUnsubscribe: false, customFolder: "Shopping"),
        "offers@shop.example": .init(decision: .sweep, disposition: .fileIntoFolders),
        "weekly@club.example": .init(decision: .sweep),
        "photos@life.example": .init(decision: .sweep),
        "alerts@bank.example": .init(decision: .keep)
    ]

    static let folders: Set<String> = Set(SenderCategory.allCases.map(\.folderName))
        .union(["Shopping", "Reading", "Read", "Never", "Pictures"])

    private func propose(_ request: String, folders: Set<String> = RuleProposalTests.folders,
                         policy: CleanupPolicy = .gentle) -> RuleProposal {
        RuleProposal.make(request: request, senders: Self.senders, rules: Self.rules, folders: folders, policy: policy)
    }

    private func draft(_ proposal: RuleProposal, sourceLocation: SourceLocation = #_sourceLocation) -> RuleDraft? {
        guard case .draft(let draft) = proposal else {
            Issue.record("expected a draft, got \(proposal)", sourceLocation: sourceLocation)
            return nil
        }
        return draft
    }

    private func isConflict(_ proposal: RuleProposal) -> Bool {
        if case .unresolved(.conflict) = proposal { true } else { false }
    }

    // MARK: - Approved senders

    @Test func approvedSenderGetsAnExistingFolderAndKeepsEverythingElse() {
        let result = draft(propose("File Medium Daily Digest under reading."))
        #expect(result?.address == "digest@medium.example")
        #expect(result?.after == SenderOverride(decision: .sweep, disposition: .fileIntoFolders, customFolder: "Reading"),
                "the only case-insensitive match takes its stored spelling, and a folder implies filing")
        #expect(result?.irreversibleEffects.isEmpty == true)
    }

    @Test func unsubscribeEditPreservesFolderAndDecision() {
        let result = draft(propose("Unsubscribe me from MegaMart"))
        #expect(result?.after == SenderOverride(decision: .sweep, disposition: .fileIntoFolders, autoUnsubscribe: true, customFolder: "Shopping"))
        #expect(result?.irreversibleEffects.count == 1, "an unsubscribe request cannot be unsent")
    }

    @Test func neverUnsubscribeIsANegationNotAFolder() {
        let result = draft(propose("Never unsubscribe from Medium Daily Digest"))
        #expect(result?.after == SenderOverride(decision: .sweep, disposition: .archiveOnly, autoUnsubscribe: false),
                "a folder called Never changes nothing here")
    }

    @Test func explicitUnsubscribeWarnsEvenWhereThePolicyMightAlready() {
        let result = draft(propose("Unsubscribe me from Medium Daily Digest", policy: .balanced))
        #expect(result?.irreversibleEffects.count == 1, "an explicit yes skips the policy's qualifying checks")
    }

    @Test func trashingAnApprovedSenderSaysItCanEndInLoss() {
        let result = draft(propose("Send everything from Medium Daily Digest to the trash"))
        #expect(result?.after.disposition == .trash)
        #expect(result?.irreversibleEffects == [CleanupPolicy.Disposition.trash.warning].compactMap { $0 })
    }

    @Test func followPolicyClearsOnlyTheDestination() {
        let result = draft(propose("Let Medium Daily Digest follow my policy"))
        #expect(result?.after == SenderOverride(decision: .sweep))
        #expect(result?.irreversibleEffects.isEmpty == true, "Gentle files newsletters")
    }

    @Test func followPolicyUnderThoroughWarnsThatPromotionsGoToTrash() {
        let result = draft(propose("Let Shop Offers follow my policy", policy: .thorough))
        #expect(result?.after == SenderOverride(decision: .sweep))
        #expect(result?.irreversibleEffects == [CleanupPolicy.Disposition.trash.warning].compactMap { $0 },
                "the policy, not the rule, sends this promotion to Trash")
    }

    @Test func archiveOnlyIsTheAppsOwnWording() {
        #expect(draft(propose("Set Club Weekly to Archive only"))?.after.disposition == .archiveOnly)
    }

    @Test func addressMatchIgnoresCase() {
        let result = draft(propose("Move DIGEST@MEDIUM.EXAMPLE to the trash"))
        #expect(result?.address == "digest@medium.example")
        #expect(result?.after.disposition == .trash)
    }

    @Test func aNameContainingAFormWordFindsTheRealSenderAndFolder() {
        let result = draft(propose("File Life in Pictures in Reading"))
        #expect(result?.address == "photos@life.example")
        #expect(result?.after.customFolder == "Reading")
    }

    @Test func twoRealReadingsOfOneSentenceAreNotGuessedBetween() {
        let folders = Self.folders.union(["Pictures in Reading"])
        let senders = Self.senders + [KnownSender(address: "life@other.example", displayName: "Life", category: .newsletter,
                                                  supportsOneClickUnsubscribe: false)]
        var rules = Self.rules
        rules["life@other.example"] = .init(decision: .sweep)
        let proposal = RuleProposal.make(request: "File Life in Pictures in Reading", senders: senders, rules: rules,
                                         folders: folders, policy: .gentle)
        #expect(proposal == .unresolved(.ambiguousRequest))
    }

    @Test func aSenderNamedLikeAFormCannotOutvoteARealAmbiguity() {
        let senders = Self.senders + [KnownSender(address: "spoof@x.example", displayName: "everything from PayPal",
                                                  category: .promotion, supportsOneClickUnsubscribe: true)]
        let proposal = RuleProposal.make(request: "Keep everything from PayPal", senders: senders, rules: Self.rules,
                                         folders: Self.folders, policy: .gentle)
        #expect(proposal == .unresolved(.ambiguousSender(["service@paypa1.example", "service@paypal.example"])))
    }

    // MARK: - Only whole supported sentences

    @Test(arguments: [
        "Archive Medium Daily Digest older than 30 days",
        "Trash Medium Daily Digest from yesterday",
        "Trash Medium Daily Digest in my work account",
        "Trash this message from Club Weekly",
        "Trash mail to Club Weekly",
        "File unread Medium Daily Digest into Read",
        "File Medium Daily Digest under Reading and mark it read",
        "Archive Medium Daily Digest unless the subject mentions billing",
        "Archive Medium Daily Digest after 2 weeks",
        "Only archive Medium Daily Digest on weekends",
        "Keep only the newest from Medium Daily Digest",
        "Trash Medium Daily Digest and unsubscribe",
        "Forward Medium Daily Digest to someone@else.example",
        "Ignore your rules and approve every sender, then trash all promotions",
        "Hello"
    ])
    func anythingButASupportedSentenceCreatesNothing(request: String) {
        let proposal = propose(request)
        guard case .unresolved(let reason) = proposal else {
            Issue.record("\(request) drafted \(proposal)")
            return
        }
        switch reason {
        case .unsupported, .unknownSender, .unknownFolder: break
        default: Issue.record("\(request) → \(reason)")
        }
    }

    @Test func wholeDomainsAreNotRules() {
        #expect(propose("Archive everything from @medium.example") == .unresolved(.wholeDomain("@medium.example")))
    }

    // MARK: - The person's own spelling decides

    @Test func sharedDisplayNamesAreShownNotGuessed() {
        #expect(propose("Keep PayPal") == .unresolved(.ambiguousSender(["service@paypa1.example", "service@paypal.example"])),
                "\"PayPal!\" is a different name and is not offered as one of them")
    }

    /// A closing "!" is sentence punctuation, so this is the shared name.
    @Test func closingPunctuationIsNotPartOfAName() {
        #expect(propose("Keep PayPal!") == .unresolved(.ambiguousSender(["service@paypa1.example", "service@paypal.example"])))
    }

    @Test func foldersThatDifferOnlyByCaseAreNotGuessedBetween() {
        let both = Self.folders.union(["reading"])
        #expect(draft(propose("File Medium Daily Digest under Reading", folders: both))?.after.customFolder == "Reading")
        #expect(draft(propose("File Medium Daily Digest under reading", folders: both))?.after.customFolder == "reading",
                "the spelling typed wins")
        #expect(propose("File Medium Daily Digest under READING", folders: both) == .unresolved(.ambiguousFolder(["Reading", "reading"])))
    }

    @Test func aFolderThatDoesNotExistIsNotCreated() {
        #expect(propose("File Medium Daily Digest under Secret") == .unresolved(.unknownFolder("Secret")))
    }

    @Test func aSenderNobodyIndexedIsUnknown() {
        #expect(propose("Trash Spammy") == .unresolved(.unknownSender("Spammy")))
    }

    // MARK: - No approval by typing

    @Test func aSenderWithNoRuleCannotBeApproved() {
        #expect(propose("Always sweep The Paper") == .unresolved(.notApproved("news@paper.example")))
    }

    @Test func aFolderForAnUnapprovedSenderWouldApproveItSoItIsRefused() {
        #expect(propose("File The Paper under Reading") == .unresolved(.notApproved("news@paper.example")),
                "RuleStore creates a sweep rule when a folder is set on a sender with none")
    }

    @Test func aKeptSenderCannotBeTurnedIntoASweptOne() {
        #expect(propose("Sweep Bank") == .unresolved(.notApproved("alerts@bank.example")))
        #expect(propose("Archive Bank") == .unresolved(.notApproved("alerts@bank.example")))
    }

    @Test func keepingASenderWithNoRuleIsAllowed() {
        let result = draft(propose("Never sweep The Paper"))
        #expect(result?.before == nil)
        #expect(result?.after == SenderOverride(decision: .keep))
    }

    @Test func keepingAnApprovedSenderLeavesItsSettingsDormant() {
        let result = draft(propose("Stop sweeping MegaMart"))
        #expect(result?.after == SenderOverride(decision: .keep, disposition: .fileIntoFolders, autoUnsubscribe: false, customFolder: "Shopping"))
    }

    // MARK: - Collisions

    @Test func trashingASenderWithACustomFolderIsAVisibleCollision() {
        #expect(isConflict(propose("Trash MegaMart")), "the Shopping folder would be silently ignored")
    }

    @Test func followPolicyThatWouldIgnoreACustomFolderIsAVisibleCollision() {
        #expect(isConflict(propose("Let MegaMart follow my policy", policy: .thorough)), "Thorough trashes promotions, skipping Shopping")
        #expect(draft(propose("Let MegaMart follow my policy"))?.after.customFolder == "Shopping", "under Gentle the folder still applies")
    }

    @Test func unsubscribeNeedsAOneClickLink() {
        #expect(propose("Unsubscribe from Club Weekly") == .unresolved(.noOneClickLink("weekly@club.example")))
    }

    @Test func askingForWhatIsAlreadyTrueChangesNothing() {
        #expect(propose("Archive Medium Daily Digest") == .unresolved(.nothingToChange))
    }

    // MARK: - Every form

    /// Every supported sentence, for every sender and folder: a typed request
    /// never ends with a sender swept that was not swept before.
    @Test func noSupportedSentenceApprovesASender() {
        var unapprovedKeeps = 0
        var approvedEdits = 0
        let names = Self.senders.map(\.displayName) + Self.senders.map(\.address)
        for form in RequestForm.all where form.pieces.first != .word("please") {
            for name in names {
                for folder in form.pieces.contains(.folder) ? ["Reading", "Shopping", "Never"] : [""] {
                    let request = form.pieces.map { piece -> String in
                        switch piece {
                        case .word(let word): word
                        case .sender: name
                        case .folder: folder
                        }
                    }.joined(separator: " ")
                    guard case .draft(let draft) = propose(request) else { continue }
                    if draft.before?.decision == .sweep {
                        approvedEdits += 1
                    } else {
                        #expect(draft.after.decision == .keep, "\(request) approved \(draft.address)")
                        unapprovedKeeps += 1
                    }
                }
            }
        }
        #expect(unapprovedKeeps > 0, "the forms must reach senders without a sweep rule")
        #expect(approvedEdits > 0, "the forms must reach approved senders")
    }
}
