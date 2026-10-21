import Foundation
import Testing
@testable import GrokboxCore

struct RuleProposalTests {
    static let senders: [KnownSender] = [
        .init(address: "digest@medium.example", displayName: "Medium Daily Digest", category: .newsletter, supportsOneClickUnsubscribe: true),
        .init(address: "deals@megamart.example", displayName: "MegaMart", category: .promotion, supportsOneClickUnsubscribe: true),
        .init(address: "offers@shop.example", displayName: "Shop Offers", category: .promotion, supportsOneClickUnsubscribe: false),
        .init(address: "weekly@club.example", displayName: "Club Weekly", category: .newsletter, supportsOneClickUnsubscribe: false),
        .init(address: "news@paper.example", displayName: "The Paper", category: .newsletter, supportsOneClickUnsubscribe: false),
        .init(address: "alerts@bank.example", displayName: "Bank", category: .transactional, supportsOneClickUnsubscribe: false),
        .init(address: "service@paypal.example", displayName: "PayPal", category: .transactional, supportsOneClickUnsubscribe: false),
        .init(address: "service@paypa1.example", displayName: "PayPal", category: .promotion, supportsOneClickUnsubscribe: true)
    ]

    static let rules: [String: SenderOverride] = [
        "digest@medium.example": .init(decision: .sweep, disposition: .archiveOnly),
        "deals@megamart.example": .init(decision: .sweep, disposition: .fileIntoFolders, autoUnsubscribe: false, customFolder: "Shopping"),
        "offers@shop.example": .init(decision: .sweep, disposition: .fileIntoFolders),
        "weekly@club.example": .init(decision: .sweep),
        "alerts@bank.example": .init(decision: .keep)
    ]

    static let folders: Set<String> = Set(SenderCategory.allCases.map(\.folderName)).union(["Shopping", "Reading", "Read"])

    private func propose(_ request: String, _ reading: RuleReading,
                         folders: Set<String> = RuleProposalTests.folders,
                         policy: CleanupPolicy = .gentle) -> RuleProposal {
        RuleProposal.make(from: reading, request: request, senders: Self.senders, rules: Self.rules,
                          folders: folders, policy: policy)
    }

    private func draft(_ proposal: RuleProposal, sourceLocation: SourceLocation = #_sourceLocation) -> RuleDraft? {
        guard case .draft(let draft) = proposal else {
            Issue.record("expected a draft, got \(proposal)", sourceLocation: sourceLocation)
            return nil
        }
        return draft
    }

    private func isUnsupported(_ proposal: RuleProposal) -> Bool {
        if case .unresolved(.unsupported) = proposal { true } else { false }
    }

    private func isConflict(_ proposal: RuleProposal) -> Bool {
        if case .unresolved(.conflict) = proposal { true } else { false }
    }

    // MARK: - Approved senders

    @Test func approvedSenderGetsAnExistingFolderAndKeepsEverythingElse() {
        let result = draft(propose("File Medium Daily Digest under reading",
                                   RuleReading(sender: "Medium Daily Digest", folder: "reading")))
        #expect(result?.address == "digest@medium.example")
        #expect(result?.after == SenderOverride(decision: .sweep, disposition: .fileIntoFolders, customFolder: "Reading"),
                "the folder takes its stored spelling and implies filing, as RuleStore.setCustomFolder does")
        #expect(result?.irreversibleEffects.isEmpty == true)
    }

    @Test func unsubscribeEditPreservesFolderAndDecision() {
        let result = draft(propose("Unsubscribe me from MegaMart", RuleReading(sender: "MegaMart", unsubscribe: "always")))
        #expect(result?.after == SenderOverride(decision: .sweep, disposition: .fileIntoFolders, autoUnsubscribe: true, customFolder: "Shopping"))
        #expect(result?.irreversibleEffects.count == 1, "an unsubscribe request cannot be unsent")
    }

    @Test func explicitUnsubscribeWarnsEvenWhereThePolicyMightAlready() {
        let result = draft(propose("Unsubscribe me from Medium Daily Digest",
                                   RuleReading(sender: "Medium Daily Digest", unsubscribe: "always"), policy: .balanced))
        #expect(result?.irreversibleEffects.count == 1, "an explicit yes skips the policy's qualifying checks")
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
        #expect(result?.irreversibleEffects.isEmpty == true, "Gentle files newsletters")
    }

    @Test func followPolicyUnderThoroughWarnsThatPromotionsGoToTrash() {
        let result = draft(propose("Let Shop Offers follow my policy",
                                   RuleReading(sender: "Shop Offers", destination: "policy"), policy: .thorough))
        #expect(result?.after == SenderOverride(decision: .sweep))
        #expect(result?.irreversibleEffects == [CleanupPolicy.Disposition.trash.warning].compactMap { $0 },
                "the policy, not the rule, sends this promotion to Trash")
    }

    @Test func archiveOnlyIsTheAppsOwnWordingNotACondition() {
        let result = draft(propose("Set Club Weekly to Archive only", RuleReading(sender: "Club Weekly", destination: "archive")))
        #expect(result?.after.disposition == .archiveOnly)
    }

    @Test func addressMatchIgnoresCase() {
        let result = draft(propose("Move DIGEST@MEDIUM.EXAMPLE to the trash",
                                   RuleReading(sender: "digest@medium.example", destination: "trash")))
        #expect(result?.address == "digest@medium.example")
        #expect(result?.after.disposition == .trash)
    }

    // MARK: - Every word accounted for

    @Test func ageConditionTheModelReportedCreatesNothing() {
        let proposal = propose("Archive Medium Daily Digest older than 30 days",
                               RuleReading(sender: "Medium Daily Digest", destination: "archive", unsupported: "older than 30 days"))
        #expect(proposal == .unresolved(.unsupported("older than 30 days")))
    }

    @Test(arguments: [
        "Archive Medium Daily Digest older than 30 days",
        "Trash Medium Daily Digest from yesterday",
        "Trash Medium Daily Digest in my work account",
        "File Medium Daily Digest under Reading and mark it read",
        "Archive Medium Daily Digest unless the subject mentions billing",
        "Archive Medium Daily Digest after 2 weeks",
        "Only archive Medium Daily Digest on weekends",
        "Trash Medium Daily Digest from now on"
    ])
    func wordsTheModelDroppedStillCreateNothing(request: String) {
        let reading = RuleReading(sender: "Medium Daily Digest",
                                  destination: request.lowercased().hasPrefix("trash") ? "trash" : "archive",
                                  folder: request.contains("Reading") ? "Reading" : nil)
        #expect(isUnsupported(propose(request, reading)), "\(request) must not widen into a rule for all mail")
    }

    @Test func aFolderNameIsMatchedAsWholeWordsInOnePlace() {
        let proposal = propose("File unread Medium Daily Digest into Read",
                               RuleReading(sender: "Medium Daily Digest", folder: "Read"))
        #expect(isUnsupported(proposal), "\"unread\" is a condition, not part of the folder \"Read\": \(proposal)")
    }

    @Test func aFolderNameThatLooksLikeAConditionIsNotOne() {
        let proposal = propose("File Medium Daily Digest under Reading 2026",
                               RuleReading(sender: "Medium Daily Digest", folder: "Reading 2026"),
                               folders: Self.folders.union(["Reading 2026"]))
        #expect(draft(proposal)?.after.customFolder == "Reading 2026")
    }

    @Test func wholeDomainsAreNotRules() {
        #expect(isUnsupported(propose("Archive everything from @medium.example",
                                      RuleReading(sender: "@medium.example", destination: "archive"))))
    }

    // MARK: - The model's slots must match the words

    @Test func aSlotTheRequestNeverAskedForIsAMisread() {
        #expect(propose("Archive Medium Daily Digest", RuleReading(sender: "Medium Daily Digest", destination: "trash"))
                == .unresolved(.misread))
    }

    @Test func aPhraseTheModelIgnoredIsAMisread() {
        #expect(propose("Trash Medium Daily Digest and unsubscribe", RuleReading(sender: "Medium Daily Digest", destination: "trash"))
                == .unresolved(.misread))
    }

    @Test func aSenderTheRequestNeverNamedIsRefused() {
        #expect(propose("Keep PayPal", RuleReading(sender: "service@paypa1.example", decision: "keep"))
                == .unresolved(.notInRequest("service@paypa1.example")),
                "the model cannot pick one PayPal for the person")
        #expect(propose("Sweep the newsletter", RuleReading(sender: "promo@attacker.example", decision: "sweep"))
                == .unresolved(.notInRequest("promo@attacker.example")))
    }

    @Test func aFolderTheRequestNeverNamedIsRefused() {
        #expect(propose("File Medium Daily Digest", RuleReading(sender: "Medium Daily Digest", folder: "Reading"))
                == .unresolved(.notInRequest("Reading")))
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
        RuleReading(sender: "Medium Daily Digest", unsubscribe: "policy"),
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

    @Test func foldersThatDifferOnlyByCaseAreNotGuessedBetween() {
        let both = Self.folders.union(["reading"])
        #expect(draft(propose("File Medium Daily Digest under Reading",
                              RuleReading(sender: "Medium Daily Digest", folder: "Reading"), folders: both))?.after.customFolder == "Reading",
                "an exact spelling wins")
        #expect(propose("File Medium Daily Digest under READING",
                        RuleReading(sender: "Medium Daily Digest", folder: "READING"), folders: both)
                == .unresolved(.ambiguousFolder(["Reading", "reading"])))
    }

    @Test func anEmptyReadingChangesNothing() {
        #expect(propose("Hello", RuleReading(sender: "Medium Daily Digest")) == .unresolved(.nothingToChange))
    }

    // MARK: - Collisions

    @Test func folderAndTrashTogetherContradict() {
        #expect(isConflict(propose("File Medium Daily Digest under Reading and trash it",
                                   RuleReading(sender: "Medium Daily Digest", destination: "trash", folder: "Reading"))))
    }

    @Test func trashingASenderWithACustomFolderIsAVisibleCollision() {
        #expect(isConflict(propose("Trash MegaMart", RuleReading(sender: "MegaMart", destination: "trash"))),
                "the Shopping folder would be silently ignored")
    }

    @Test func followPolicyThatWouldIgnoreACustomFolderIsAVisibleCollision() {
        let proposal = propose("Let MegaMart follow my policy", RuleReading(sender: "MegaMart", destination: "policy"), policy: .thorough)
        #expect(isConflict(proposal), "Thorough trashes promotions, which would skip Shopping: \(proposal)")
        #expect(draft(propose("Let MegaMart follow my policy", RuleReading(sender: "MegaMart", destination: "policy")))?.after.customFolder == "Shopping",
                "under Gentle the folder still applies")
    }

    @Test func keepWithADestinationContradicts() {
        #expect(isConflict(propose("Keep MegaMart in Reading", RuleReading(sender: "MegaMart", decision: "keep", folder: "Reading"))))
    }

    @Test func unsubscribeNeedsAOneClickLink() {
        #expect(isUnsupported(propose("Unsubscribe from Club Weekly", RuleReading(sender: "Club Weekly", unsubscribe: "always"))),
                "an override cannot invent an endpoint")
    }

    @Test func askingForWhatIsAlreadyTrueChangesNothing() {
        #expect(propose("Archive Medium Daily Digest", RuleReading(sender: "Medium Daily Digest", destination: "archive"))
                == .unresolved(.nothingToChange))
    }

    // MARK: - Whole matrix

    /// Whatever slots the model fills, and with the request worded to match
    /// them, a typed request never ends with a sender swept that was not
    /// swept before.
    @Test func noReadingApprovesASender() {
        let decisions: [(String?, String)] = [(nil, ""), ("sweep", "sweep"), ("keep", "keep")]
        let destinations: [(String?, String)] = [(nil, ""), ("policy", "follow my policy"), ("folders", "file"), ("archive", "archive"), ("trash", "trash")]
        let unsubscribes: [(String?, String)] = [(nil, ""), ("never", "never unsubscribe"), ("always", "unsubscribe")]
        let folders: [String?] = [nil, "Reading", "Shopping"]
        var unapprovedKeeps = 0
        var approvedEdits = 0
        for sender in Self.senders.map(\.displayName) + Self.senders.map(\.address) {
            for decision in decisions { for destination in destinations { for unsubscribe in unsubscribes { for folder in folders {
                let request = [decision.1, destination.1, unsubscribe.1, sender, folder.map { "under \($0)" } ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                let reading = RuleReading(sender: sender, decision: decision.0, destination: destination.0,
                                          folder: folder, unsubscribe: unsubscribe.0)
                guard case .draft(let draft) = propose(request, reading) else { continue }
                if draft.before?.decision == .sweep {
                    approvedEdits += 1
                } else {
                    #expect(draft.after.decision == .keep, "\(request) approved \(draft.address)")
                    unapprovedKeeps += 1
                }
            } } } }
        }
        #expect(unapprovedKeeps > 0, "the matrix must reach senders without a sweep rule")
        #expect(approvedEdits > 0, "the matrix must reach approved senders")
    }
}
