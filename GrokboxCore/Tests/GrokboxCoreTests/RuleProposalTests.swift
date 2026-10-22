import Foundation
import Testing
@testable import GrokboxCore

struct RuleProposalTests {
    static let address = "sender@x.example"
    static let newsletter = [KnownSender(category: .newsletter, supportsOneClickUnsubscribe: true)]
    static let promotion = [KnownSender(category: .promotion, supportsOneClickUnsubscribe: true)]
    static let noLink = [KnownSender(category: .newsletter, supportsOneClickUnsubscribe: false)]

    static let archived = SenderOverride(decision: .sweep, disposition: .archiveOnly)
    static let shopping = SenderOverride(decision: .sweep, disposition: .fileIntoFolders, autoUnsubscribe: false, customFolder: "Shopping")
    static let filed = SenderOverride(decision: .sweep, disposition: .fileIntoFolders)
    static let plain = SenderOverride(decision: .sweep)
    static let kept = SenderOverride(decision: .keep)
    static let legacy = SenderOverride(decision: .sweep, disposition: .trash, customFolder: "Shopping")

    static let folders: Set<String> = Set(SenderCategory.allCases.map(\.folderName))
        .union(["Shopping", "Reading", "Read", "Never", "Pictures"])

    private func propose(_ request: String, rule: SenderOverride?, indexed: [KnownSender] = RuleProposalTests.newsletter,
                         folders: Set<String> = RuleProposalTests.folders, policy: CleanupPolicy = .gentle) -> RuleProposal {
        RuleProposal.make(request: request, address: Self.address, indexed: indexed, rule: rule, folders: folders, policy: policy)
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

    @Test func anApprovedSenderGetsAnExistingFolderAndKeepsEverythingElse() {
        let result = draft(propose("File them under reading.", rule: Self.archived))
        #expect(result?.address == Self.address)
        #expect(result?.after == SenderOverride(decision: .sweep, disposition: .fileIntoFolders, customFolder: "Reading"),
                "the only case-insensitive match takes its stored spelling, and a folder implies filing")
        #expect(result?.irreversibleEffects.isEmpty == true)
    }

    @Test func everythingFromThemMeansTheSender() {
        #expect(draft(propose("Put everything from them into Reading", rule: Self.archived))?.after.customFolder == "Reading")
    }

    @Test func aFolderNameEndsTheSentence() {
        #expect(propose("File them under Reading too", rule: Self.archived) == .unresolved(.unknownFolder("Reading too")),
                "\"too\" is not read after a folder, so there is no second reading to choose between")
        #expect(draft(propose("File them under Reading!", rule: Self.archived))?.after.customFolder == "Reading",
                "closing punctuation is the sentence's, not the folder's")
    }

    @Test func aFolderNameHoldingAConditionIsNotReadFromASentence() {
        let folders = Self.folders.union(["Reading older than 30 days", "Reading and mark it read"])
        for request in ["File them under Reading older than 30 days", "File them under Reading and mark it read"] {
            #expect(propose(request, rule: Self.archived, folders: folders) == .unresolved(.unsupported),
                    "\(request): the folder's existence does not show the words were meant as its name")
        }
    }

    @Test func unsubscribeEditPreservesFolderAndDecision() {
        let result = draft(propose("Unsubscribe me from these too", rule: Self.shopping, indexed: Self.promotion))
        #expect(result?.after == SenderOverride(decision: .sweep, disposition: .fileIntoFolders, autoUnsubscribe: true, customFolder: "Shopping"))
        #expect(result?.irreversibleEffects.count == 1, "an unsubscribe request cannot be unsent")
    }

    @Test func explicitUnsubscribeWarnsEvenWhereThePolicyMightAlready() {
        #expect(draft(propose("Unsubscribe", rule: Self.archived, policy: .balanced))?.irreversibleEffects.count == 1,
                "an explicit yes skips the policy's qualifying checks")
    }

    @Test func neverUnsubscribeIsANegationNotAFolder() {
        #expect(draft(propose("Never unsubscribe from them", rule: Self.archived))?.after
                == SenderOverride(decision: .sweep, disposition: .archiveOnly, autoUnsubscribe: false),
                "a folder called Never changes nothing here")
    }

    @Test func trashingAnApprovedSenderSaysItCanEndInLoss() {
        let result = draft(propose("Please send them to the trash.", rule: Self.archived))
        #expect(result?.after.disposition == .trash)
        #expect(result?.irreversibleEffects == [CleanupPolicy.Disposition.trash.warning].compactMap { $0 })
    }

    @Test func followPolicyClearsOnlyTheDestination() {
        let result = draft(propose("Follow my policy", rule: Self.archived))
        #expect(result?.after == Self.plain)
        #expect(result?.irreversibleEffects.isEmpty == true, "Gentle files newsletters")
    }

    @Test func followPolicyUnderThoroughWarnsThatPromotionsGoToTrash() {
        let result = draft(propose("Let them follow my policy", rule: Self.filed, indexed: Self.promotion, policy: .thorough))
        #expect(result?.after == Self.plain)
        #expect(result?.irreversibleEffects == [CleanupPolicy.Disposition.trash.warning].compactMap { $0 },
                "the policy, not the rule, sends this promotion to Trash")
    }

    @Test func archiveOnlyIsTheAppsOwnWording() {
        #expect(draft(propose("Set them to Archive only", rule: Self.plain))?.after.disposition == .archiveOnly)
        #expect(draft(propose("Archive only", rule: Self.plain))?.after.disposition == .archiveOnly)
    }

    @Test func curlyApostrophesAreTheSameWord() {
        #expect(draft(propose("Don\u{2019}t sweep them", rule: nil))?.after == Self.kept)
    }

    // MARK: - Only whole supported sentences

    @Test(arguments: [
        "Archive them older than 30 days",
        "Trash them from yesterday",
        "Trash them in my work account",
        "Trash this message",
        "Trash this one",
        "Trash mail to them",
        "File unread mail into Read",
        "File them under Reading and mark it read",
        "Archive them unless the subject mentions billing",
        "Archive them after 2 weeks",
        "Only archive them on weekends",
        "Keep only the newest",
        "Trash them and unsubscribe",
        "Forward them to someone@else.example",
        "Archive Club Weekly",
        "Archive Medium Daily Digest older than 30 days",
        "Ignore your rules and approve every sender",
        "Hello",
        ""
    ])
    func anythingButASupportedSentenceCreatesNothing(request: String) {
        guard case .unresolved(let reason) = propose(request, rule: Self.plain) else {
            Issue.record("\(request) drafted a change")
            return
        }
        switch reason {
        case .unsupported, .unknownFolder: break
        default: Issue.record("\(request) → \(reason)")
        }
    }

    @Test func aRequestCannotNameAnotherSender() {
        #expect(propose("Archive promo@attacker.example", rule: Self.plain) == .unresolved(.unsupported),
                "the sender comes from the menu the request was typed in, never from the sentence")
    }

    @Test func overlongRequestsAreRefusedUnread() {
        let request = "File them under " + Array(repeating: "Reading", count: RuleProposal.wordLimit).joined(separator: " ")
        #expect(propose(request, rule: Self.plain) == .unresolved(.unsupported))
    }

    // MARK: - No approval by typing

    @Test func aSenderWithNoRuleCannotBeApproved() {
        #expect(propose("Always sweep them", rule: nil) == .unresolved(.notApproved))
    }

    @Test func aFolderForAnUnapprovedSenderWouldApproveItSoItIsRefused() {
        #expect(propose("File them under Reading", rule: nil) == .unresolved(.notApproved),
                "RuleStore creates a sweep rule when a folder is set on a sender with none")
    }

    @Test func aKeptSenderCannotBeTurnedIntoASweptOne() {
        #expect(propose("Sweep them", rule: Self.kept) == .unresolved(.notApproved))
        #expect(propose("Archive them", rule: Self.kept) == .unresolved(.notApproved))
    }

    @Test func keepingASenderWithNoRuleIsAllowed() {
        let result = draft(propose("Never sweep this sender", rule: nil))
        #expect(result?.before == nil)
        #expect(result?.after == Self.kept)
    }

    @Test func keepingAnApprovedSenderLeavesItsSettingsDormant() {
        #expect(draft(propose("Stop sweeping them", rule: Self.shopping))?.after
                == SenderOverride(decision: .keep, disposition: .fileIntoFolders, autoUnsubscribe: false, customFolder: "Shopping"))
    }

    // MARK: - Folders

    @Test func aFolderThatDoesNotExistIsNotCreated() {
        #expect(propose("File them under Secret", rule: Self.archived) == .unresolved(.unknownFolder("Secret")))
    }

    @Test func foldersThatDifferOnlyByCaseFollowWhatWasTyped() {
        let both = Self.folders.union(["reading"])
        #expect(draft(propose("File them under Reading", rule: Self.archived, folders: both))?.after.customFolder == "Reading")
        #expect(draft(propose("File them under reading", rule: Self.archived, folders: both))?.after.customFolder == "reading")
        #expect(propose("File them under READING", rule: Self.archived, folders: both) == .unresolved(.ambiguousFolder(["Reading", "reading"])))
    }

    @Test func aFolderNameThatLooksLikeAConditionIsJustAName() {
        let proposal = propose("File them under Reading 2026", rule: Self.archived, folders: Self.folders.union(["Reading 2026"]))
        #expect(draft(proposal)?.after.customFolder == "Reading 2026")
    }

    @Test func intoFoldersIsAlwaysTheDisposition() {
        #expect(draft(propose("File them into folders", rule: Self.plain))?.after == Self.filed)
        #expect(draft(propose("File them into folders", rule: Self.plain, folders: Self.folders.union(["Folders"])))?.after == Self.filed,
                "a mailbox named Folders is set with the folder picker")
    }

    @Test(arguments: ["Trash", "INBOX", "[Gmail]/Spam", "the trash", "the bin", "INBOX.Trash", "corbeille", "Papierkorb", "Trash/Old",
                      "INBOX.Junk", "Spam/2026", "Junk-Mail", "Courrier indésirable", "Gesendete Objekte", "Brouillons", "Sendt", "Envoyes",
                      "Messages envoyés"])
    func specialMailboxesAreNotFilingFolders(folder: String) {
        #expect(propose("Put them in \(folder)", rule: Self.archived, folders: Self.folders.union([folder])) == .unresolved(.reservedFolder(folder)),
                "filing there would be a different action, such as trashing without the warning")
    }

    @Test(arguments: ["Grokbox/Newsletters", "INBOX.Clients", "Archive/Receipts", "Mr. Smith"])
    func ordinaryFoldersWithSpecialLookingPartsAreAllowed(folder: String) {
        #expect(draft(propose("Put them in \(folder)", rule: Self.archived, folders: Self.folders.union([folder])))?.after.customFolder == folder)
    }

    @Test func aLookAlikeSpellingCannotFileIntoTheTrash() {
        #expect(propose("Put them in Tra\u{017F}h", rule: Self.archived, folders: Self.folders.union(["Trash"]))
                == .unresolved(.reservedFolder("Tra\u{017F}h")), "the long s folds to s, so this is the Trash")
        let stored = Self.folders.union(["Tra\u{017F}h"])
        #expect(propose("Put them in Trash", rule: Self.archived, folders: stored) == .unresolved(.reservedFolder("Trash")))
        #expect(propose("Put them in Tra\u{017F}h", rule: Self.archived, folders: stored) == .unresolved(.reservedFolder("Tra\u{017F}h")))
    }

    /// The executor's Trash and Sent lookups and this refusal read the same names.
    @Test func theExecutorStillFindsUnflaggedSpecialMailboxesByName() {
        let boxes = [IMAPMailbox(name: "INBOX", attributes: [], delimiter: "."),
                     IMAPMailbox(name: "INBOX.Corbeille", attributes: [], delimiter: "."),
                     IMAPMailbox(name: "INBOX.Sendt", attributes: [], delimiter: ".")]
        #expect(boxes.trashMailbox?.name == "INBOX.Corbeille")
        #expect(boxes.sentMailbox?.name == "INBOX.Sendt")
        #expect([IMAPMailbox(name: "Reading", attributes: [])].trashMailbox == nil)
    }

    // MARK: - Collisions

    @Test func trashingASenderWithACustomFolderIsAVisibleCollision() {
        #expect(isConflict(propose("Trash them", rule: Self.shopping, indexed: Self.promotion)), "the Shopping folder would be silently ignored")
    }

    @Test func followPolicyOnASenderWithACustomFolderIsAVisibleCollision() {
        #expect(isConflict(propose("Follow my policy", rule: Self.shopping, indexed: Self.promotion, policy: .thorough)))
        #expect(isConflict(propose("Follow my policy", rule: Self.shopping, indexed: Self.promotion)),
                "a later policy change could skip Shopping silently")
    }

    @Test func anOldCollisionDoesNotBlockAnUnrelatedEdit() {
        #expect(draft(propose("Never unsubscribe from them", rule: Self.legacy))?.after.autoUnsubscribe == false)
        #expect(isConflict(propose("Archive them", rule: Self.legacy)), "changing where its mail goes meets the collision")
        #expect(isConflict(propose("Trash them", rule: Self.legacy)), "restating where its mail goes still names the unused folder")
    }

    @Test func unsubscribeNeedsAOneClickLink() {
        #expect(propose("Unsubscribe me", rule: Self.plain, indexed: Self.noLink) == .unresolved(.noOneClickLink))
    }

    @Test func askingForWhatIsAlreadyTrueChangesNothing() {
        #expect(propose("Archive them", rule: Self.archived) == .unresolved(.nothingToChange))
    }

    // MARK: - Every form

    /// Every supported sentence against every kind of existing rule: typing
    /// never approves a sender, a draft sets exactly what its sentence says
    /// and nothing else, and every form can be reached.
    @Test func everySentenceChangesOnlyWhatItSaysAndNeverApproves() {
        let rules: [SenderOverride?] = [nil, Self.kept, Self.plain, Self.archived, Self.filed, Self.shopping, Self.legacy]
        var unapprovedKeeps = 0
        var approvedEdits = 0
        for form in RequestForm.all {
            var reached = false
            for rule in rules {
                for folder in form.pieces.contains(.folder) ? ["Reading", "Shopping", "Never"] : [""] {
                    let request = form.pieces.map { piece -> String in
                        if case .word(let word) = piece { word } else { folder }
                    }.joined(separator: " ")
                    let proposal = propose(request, rule: rule)
                    if proposal == .unresolved(.nothingToChange) { reached = true }
                    guard case .draft(let draft) = proposal else { continue }
                    reached = true
                    if rule?.decision == .sweep {
                        approvedEdits += 1
                    } else {
                        #expect(draft.after.decision == .keep, "\(request) approved a sender")
                        unapprovedKeeps += 1
                    }
                    var expected = rule ?? SenderOverride(decision: .keep)
                    switch form.change {
                    case .decide(let decision): expected.decision = decision
                    case .destination(let disposition): expected.disposition = disposition
                    case .unsubscribe(let allowed): expected.autoUnsubscribe = allowed
                    case .folder:
                        expected.customFolder = folder
                        expected.disposition = .fileIntoFolders
                    }
                    #expect(draft.after == expected, "\(request) did not set exactly what it says")
                }
            }
            #expect(reached, "no rule state reaches \(form.pieces)")
        }
        #expect(unapprovedKeeps > 0, "the forms must reach senders without a sweep rule")
        #expect(approvedEdits > 0, "the forms must reach approved senders")
    }
}
