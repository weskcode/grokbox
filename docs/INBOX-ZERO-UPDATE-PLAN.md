# Inbox Zero audit and Grokbox update plan

Date: 2026-10-21. This is a source-backed product and engineering comparison, not a runtime security audit or an implementation approval.

## Recommendation

Make Grokbox the dependable local-first inbox triage companion: show what needs attention, reduce accumulated bulk mail safely, and keep approved decisions working. Preserve its native interface, on-device reading, sender-level decisions, bounded Brief, and visible reasoning.

Inbox Zero offers useful precedents for onboarding, sender inspection, rule testing, conversation state, and operational recovery. Its broader email-client, sending, calendar, collaboration, and integration surface would substantially expand Grokbox's scope. Borrow the useful workflows through independent implementation rather than rebuilding its entire product.

The next release should improve confidence and first-use value before adding more AI features. The first three work packages are: reconcile safety promises with current behavior, harden and clarify unsubscribe, and preview existing rules with the same logic used during execution.

## Evidence and limits

- Grokbox baseline: `bae8b57361d8b3373ac29a503d969a7b7ba216ba`, branch `develop`, initially clean checkout. Current source takes precedence over older audit documents.
- Inbox Zero baseline: [`efd3d39b98882c1316866179da7d4a38f4a0cbe2`](https://github.com/elie222/inbox-zero/tree/efd3d39b98882c1316866179da7d4a38f4a0cbe2), shallow read-only checkout at `/tmp/grokbox-inbox-zero-audit-20261021`.
- Inspected implementation and test source, project configuration, README files, license notices, and the [public product page](https://www.getinboxzero.com/). The site claims 25,000+ professionals. That is vendor-reported adoption, not independently verified active or paying users. Feature presence does not establish that a feature caused adoption.
- Neither app was built or exercised in this comparison. No live mailbox, hosted authenticated Inbox Zero session, migration, model evaluation, or test suite was run. Test files establish intended coverage, not passing results. No performance or accuracy numbers were measured.
- Grokbox has native macOS and iOS targets sharing `GrokboxCore`, as defined in `project.yml`. Inbox Zero's README describes a web assistant and email client, an Electron desktop app, and a native iOS app whose code is not public. Native iOS parity cannot be audited from this repository.

## Reuse boundary

Inbox Zero's root [LICENSE](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/LICENSE) includes AGPLv3 text and additional commercial monetization and enterprise-use restrictions. Its [`apps/web/ee/LICENSE.md`](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/apps/web/ee/LICENSE.md) contains separate commercial terms. Grokbox currently uses GPL-3.0 and advertises no third-party code.

This plan copies no implementation, prompt text, artwork, fixtures, or interface assets. It records general workflows and independently specified acceptance cases. Any later literal reuse needs a review of the applicable file notices and distribution terms. This comparison does not determine legal compatibility.

## What Grokbox already has

Avoid scheduling these as missing features:

| Capability | Current evidence | Actual next opportunity |
| --- | --- | --- |
| Guided account setup | `Grokbox/Views/AccountOnboarding.swift`: connection probe, indexing depth, cleanup preset, progress, result | End with a few inspectable recommendations and a direct route to the first safe action |
| Sender triage and drill-down | `SendersView.swift`, `SenderMessagesSheet.swift`, `SenderProfileBuilder.swift` | Make recommendation evidence and current inbox impact easier to compare |
| Preview, guard, execution, undo | `CleanupPlan.swift`, `SweepGuard.swift`, `PlanExecutor.swift`, `ActivityView.swift` | Extend preview to rule edits and expose uncertainty without weakening existing guards |
| Approved sender rules | `Models/SenderRule.swift`: sweep, keep, folder and disposition overrides | Preview edits, expose rule scope, and surface save failures |
| Local reading and prioritization | `Analysis/LocalModel.swift`, `BriefRanking.swift`, `PriorityScorer.swift` | Add adversarial model evaluation and reader coverage indicators |
| Repeated cleanup and inbox watching | `Maintainer.swift`, `InboxWatcher.swift`, `AppState.swift` | Verify recovery and platform-specific background behavior on real paths |
| One-click unsubscribe and manual fallback | `UnsubscribeService.swift`, `UnsubscribeChecklistView.swift`, `UnsubscribeExport.swift` | Correct outcome language and address resolved-host safety |
| Timeout, cancellation, migration scaffolding | `IMAPConnection.swift`, `PlanExecutor.cancel`, `GrokboxStore.swift` | Re-verify current behavior rather than treating the September audit's old findings as still open |

Paths without a directory above are under `Grokbox/`, `Grokbox/Views/`, or `GrokboxCore/Sources/GrokboxCore/` in its `Analysis`, `Sync`, `Mail/IMAP`, `Storage`, or `Services` subdirectory. Detailed work packages below name exact locations.

## Lessons to adopt, adapt, or avoid

### 1. Put a concrete first win inside setup

Observed: Inbox Zero's `StepBulkUnsubscribe.tsx` shows a bounded set of personalized sender suggestions. `suggestions.ts` filters already handled senders and ranks low-read candidates by volume. The current implementation uses a minimum sample and a read-rate threshold. Its onboarding also includes sales questions, drafting, and team invitation steps that Grokbox does not need. [Source: onboarding](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/apps/web/app/%28app%29/%5BemailAccountId%5D/onboarding/StepBulkUnsubscribe.tsx), [suggestion logic](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/apps/web/app/%28app%29/%5BemailAccountId%5D/bulk-unsubscribe/suggestions.ts).

Adapt: keep Grokbox's existing setup, then show up to three sender recommendations with sample subjects, inbox count, held count, and proposed destination. Let the user inspect, approve individually, or skip. A low read rate is evidence about flags, not proof that the user does not value the sender. Do not copy thresholds or preselection automatically.

### 2. Make sender inspection answer a decision

Observed: `SenderPanel.tsx` combines total messages, read percentage, inbox count, message inspection, and actions. [Source](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/apps/web/app/%28app%29/%5BemailAccountId%5D/bulk-unsubscribe/SenderPanel.tsx).

Adapt: build on Grokbox's existing sender drill-down. Show the evidence supporting the recommendation beside what the action will actually affect. Separate all indexed mail from inbox candidates. Show the scan's date range and whether indexing is partial. Start with existing data and text; a chart is useful only if it changes the decision.

### 3. Use the same plan for testing and execution

Observed: `executeMatchedRule` prepares actions before returning from test mode, avoiding execution. Conversation tests can use only the supplied message while live execution fetches the thread, so test context can differ. [Source: rule execution](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/apps/web/utils/ai/choose-rule/run-rules.ts), [conversation context](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/apps/web/utils/reply-tracker/handle-conversation-status.ts).

Adopt: add a read-only preview for existing Grokbox sender-rule changes before natural-language rules. Return proposed operations, held messages and reasons, scope, destination, and irreversible effects. Execution must recheck current mailbox state and guards. Explain changes since preview rather than promising a frozen count. Do not build a second evaluator for the UI.

### 4. Keep AI suggestions inside deterministic authority

Observed: `combineActionsWithAiArgs` merges permitted model fields into configured actions. It does not let the model create arbitrary action kinds. Security tests cover injected recipient fields and invented forwarding actions. `aiChooseRule` resolves model-selected names against offered rules. [Source: argument boundary](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/apps/web/utils/ai/choose-rule/choose-args.ts), [containment tests](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/apps/web/utils/ai/choose-rule/choose-args.security.test.ts), [rule selection](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/apps/web/utils/ai/choose-rule/ai-choose-rule.ts).

Adopt the principle in Grokbox's existing types: model output may suggest classification or a supported rule draft. It may not expand approval scope, disable guards, choose an arbitrary external destination, or directly invoke a provider mutation. Invalid or unsupported output needs a visible unresolved result. Grokbox's prompt already treats email as untrusted text; prompts alone are insufficient proof.

### 5. Evaluate hostile email on the actual local models

Observed: Inbox Zero has adversarial evaluations for rule overrides, fabricated relationship history, conversation-state overrides, and contaminated knowledge extraction. [Source](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/apps/web/__tests__/eval/prompt-security-core-paths.test.ts).

Adopt: write original cases for Grokbox's actual tasks. Include a promotion pretending to be urgent, a real bill asking the model to mark it noise, false deadlines, quoted old requests, mixed receipt and marketing mail, multilingual requests, and injection in subjects as well as bodies. Pair semantic evaluation with deterministic checks that no new sender is approved or guard bypassed. Run against each supported backend and record model version and configuration. Avoid paid API evaluation without spend approval.

### 6. Treat unsubscribe as a stateful external request

Observed: Inbox Zero validates resolved addresses and pins checked DNS answers for unsubscribe connections. It checks redirects and bounds requests. Some fallback paths can classify an HTTP-successful GET as unsubscribe success without semantic confirmation. [Source: request handling](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/apps/web/utils/senders/unsubscribe.ts), [resolved URL policy](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/packages/network/src/safe-url.ts), [DNS pinning](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/packages/network/src/pinned-dns.ts).

Adopt resolved-host protection; avoid overclaiming success. Grokbox's `PublicHostPolicy.check` rejects private IP literals and local hostnames but does not resolve arbitrary public-looking hostnames. That is a source-observed validation gap, not a reproduced exploit. A native implementation must validate the address actually connected to while preserving TLS hostname validation; a DNS preflight followed by an unrelated lookup is insufficient.

Grokbox's `performOneClick` calls any HTTP 2xx response `.unsubscribed`. The immediate macOS and iOS sender alerts already describe acknowledgment rather than guaranteed removal. Preserve that distinction and carry it into Activity, whose title currently says "Unsubscribed from", and the executor's completion summary. Distinguish no automatic method, needs browser, failed, accepted, and outcome unknown. Archive and unsubscribe outcomes must remain separate. Do not automatically resubmit after ambiguous connection loss. Do not add generic browser form automation now.

### 7. Extend the execution journal rather than replacing it

Observed: Inbox Zero records individual action outcomes and uses restricted retry policy for non-idempotent writes. [Source: action execution](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/apps/web/utils/ai/choose-rule/execute.ts), [retry policy](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/apps/web/utils/retry/provider-retry.ts).

Adapt: Grokbox already records actions before mutation and distinguishes interrupted work from confirmed undoable actions. It has Stop, partial outcomes, UIDVALIDITY checks, and move mappings. Verify those paths and improve Activity's explanations. A dropped acknowledgment must not be presented as proof that nothing changed. Reconcile mailbox state before replaying ambiguous MOVE or unsubscribe operations. Successful sub-actions must not be repeated simply because another sub-action failed.

### 8. Track conversation responsibility after establishing identity

Observed: Inbox Zero uses conversation chronology and provider-derived sent direction to distinguish reply-needed and awaiting-reply states. Its outbound handler deduplicates events with ownership-aware locks. [Source: status](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/apps/web/utils/reply-tracker/handle-conversation-status.ts), [outbound events](https://github.com/elie222/inbox-zero/blob/efd3d39b98882c1316866179da7d4a38f4a0cbe2/apps/web/utils/reply-tracker/handle-outbound.ts).

Adapt later: Grokbox's `ThreadKey` groups by account, sender, and normalized subject. That is useful Brief deduplication, but it cannot reliably connect a user's sent reply with a different sender address or distinguish unrelated same-subject conversations. `MessageHeader` has `messageID`, but no persisted References or In-Reply-To fields. First establish thread identity and Sent coverage. Then propose local "Needs reply", "Waiting", "Done", and "Uncertain" states with user correction. A receipt, automatic reply, or the user's latest message does not by itself prove the task is complete.

### 9. Preserve focus while learning from a larger product

Defer autonomous sending, draft generation, calendar and attachment integrations, team comments, Slack and Telegram, and a replacement email client. They add authority, data access, or infrastructure beyond current triage. Inbox Zero's provider abstraction is a useful precedent, but Grokbox already has `MailProvider`; extend it only for a proven provider need. Do not copy its web framework, hosted queues, database, billing, or analytics stack into the native app.

## Current Grokbox issues that change the order

1. **Safety copy contradicts shipped options.** README's "What it will not do" promises no deletion and click-only unsubscribe. `CleanupPolicy.balanced` and `.thorough` both enable automatic one-click unsubscribe, and `.thorough` also moves promotions to Trash. Per-sender Trash disposition and `autoUnsubscribeOverride = true` can produce the same effects under other presets. Gentle remains the default in policy loading and onboarding. `PlanExecutor.apply` performs those operations. The macOS Sweep introduction also says everything is filed and nothing is deleted. A MOVE to Trash is distinct from issuing EXPUNGE, but provider retention can still permanently remove mail. Reconcile promises and show the selected effects at approval. Do not silently change existing defaults or saved policies under a documentation fix.
2. **Rules are global across accounts.** `SenderRule` keys by address and says this is intentional. Rule preview must disclose that scope. Account-scoped rules are a product and persistence decision, not a cleanup refactor.
3. **Some persistence failures are hidden, including before mutations.** `RuleStore.set`, override setters, and `clear` use `try? context.save()`. `PlanExecutor.record` and `run` also suppress save failures before a provider write. Records are created before mutation, but their durability is not guaranteed by this code. Reproduce controlled storage failure and verify that the app refuses a remote mutation when its recovery journal cannot be saved. A rule must not appear durably enabled when it was not saved. Treat this as a release-blocking risk to investigate, not a failure reproduced by this comparison.
4. **Old audit findings are not the current backlog.** The September audit describes absent cancellation, inert deadlines, and missing schema versioning. Current source contains cancellation-aware networking, executor cancellation, `VersionedSchema`, a migration plan, and recovery. Re-run relevant regression paths before reopening those findings. `docs/ROADMAP.md` also says bodies are not read while the reader pipeline explicitly reads transient bodies.

## Delivery sequence

These are independently reviewable work packages, not calendar estimates. Each ends with evidence and an independent review. Implementation requires the relevant product decisions and named approvals below.

### Phase 0: establish the release baseline

**0A. Reconcile product promises.** Inventory Gentle, Balanced, Thorough, and per-sender overrides. Produce an effect table covering folders, archive, Trash, mark-read, unsubscribe, reversibility, and provider retention. Update only incorrect README, roadmap, privacy, and affected confirmation copy after checking current behavior. Include README's macOS-only description and privacy copy that omits onboarding as a way to enable automatic unsubscribe. Likely files: `README.md`, `docs/ROADMAP.md`, `docs/PRIVACY.md`, `Grokbox/Views/SweepView.swift`, `GrokboxiOS/PhoneSweepView.swift`, and shared `CleanupPolicyEditor.swift`.

Acceptance: every displayed promise agrees with the selected plan on both platforms. Trash retention and irreversible unsubscribe are explicit. Existing saved preferences do not change. New visual direction is unnecessary; any unsettled policy behavior goes to the owner.

**0B. Verify current safety and provider behavior.** Run the narrow core suites covering `P1RegressionTests`, `SweepSafetyTests`, `MaintainerFailureTests`, `ProviderCompatibilityTests`, `StartTLSTests`, and `SenderOverrideTests`. Drive preview, apply, Stop, Activity, undo, reconnect, and incremental sync in the actual app. Add focused behavior tests only where a gap is reproduced. Use designated disposable messages on user-approved test mailboxes for real-server mutation tests. Include Gmail and a non-Gmail IMAP server, then Proton Bridge when available.

Acceptance: preserved protected messages; no remote write when its required recovery journal cannot persist; no rule enabled after failed or stopped unapproved work; correct handling of UIDVALIDITY changes; accurate partial results; no duplicate replay after lost acknowledgment. Record server capabilities, platform, tested SHA, and remaining gaps. No release readiness claim until required real paths pass.

### Phase 1: make existing automation trustworthy

**1A. Unsubscribe safety and outcomes.** Extend `Security/PublicHostPolicy.swift`, `Services/UnsubscribeService.swift`, and related tests. Specify the native connection-time destination check before implementation. Show accepted, unknown, failed, and manual outcomes accurately in Senders, Activity, and the checklist. Keep the existing manual fallback and one-click-only automatic path.

Acceptance: controlled DNS tests reject private destinations and rebinding, redirects are rechecked, requests are bounded, TLS validation remains intact, HTTP acceptance is not labeled confirmed removal, and an unsubscribe failure does not hide a successful archive. Durable outcome history requires persistence approval.

**1B. Preview existing rule changes.** Build on `Sync/CleanupPlan.swift`, `Sync/SweepGuard.swift`, and `Models/SenderRule.swift`, with views in existing Settings, sender inspection, and Sweep. Begin with the existing rule language. Show representative affected and held messages, account scope, destination and irreversible effects. Surface save errors using existing error presentation conventions.

Acceptance: preview causes no provider writes, rules, log entries, or network unsubscribe. Preview and execution use the same evaluation logic and current guards. Changing flags or mailbox state between them is handled explicitly. Failed persistence is visible. Do not introduce a general rules framework for this step.

**1C. AI quality gate.** Add original adversarial cases beside the existing core analysis and Brief tests. Keep deterministic boundary tests separate from real-model semantic evaluations. Capture backend, model, configuration, input corpus revision, and failures without personal mail content.

Acceptance: protected actions cannot be authorized by model prose; malformed output fails safely; ambiguous cases remain reviewable; performance is measured before changing reader strategy. No cloud evaluation or telemetry is introduced.

### Phase 2: shorten the path to useful results

**2A. First-win setup.** Extend `Grokbox/Views/AccountOnboarding.swift` using the existing recommendation and plan builders. Offer a small set of inspectable candidates after the first bounded index. Link to the existing Sweep review. Keep setup skippable and usable when the model is unavailable.

Acceptance: first setup, partial index, zero candidates, connection failure, Stop, and return-later paths work. No unsubscribe or mail mutation occurs merely by progressing through setup. Show comps for new visual choices before building.

**2B. Sender decisions and honest progress.** Extend `SenderMessagesSheet.swift`, `SendersView.swift`, and the iOS sender flow. Show indexed coverage, inbox count, recommendation evidence, held count, and current rule scope. Use existing saved digests and action records for local progress where the data supports it. Do not claim time saved from message counts.

Acceptance: counts agree with the plan for the same indexed scope; partial and stale data are labeled; successful, held, failed, and unknown outcomes are distinguishable with text; keyboard, VoiceOver, Dynamic Type, and long sender names remain usable.

### Phase 3: add conversation responsibility

**3A. Thread identity first.** Specify account-scoped References and In-Reply-To handling, Sent discovery, aliases, missing headers, subject collisions, and forwarding. Preserve the current subject grouping as a labeled fallback. Likely files: `Models/MessageHeader.swift`, `Analysis/ThreadKey.swift`, mail parsing, `Sync/SyncEngine.swift`, and `Storage/GrokboxStore.swift`.

Acceptance: fixtures cover unrelated same-subject mail, aliases, multi-party replies, forwarded mail, missing references, duplicate sync, and mailbox renumbering. Existing stores upgrade without losing rules or action history. This work waits for schema and stored-data approval.

**3B. Needs reply and waiting.** Once 3A passes, propose explicit conversation states in the Brief. Include uncertainty, last evidence, and a manual correction. Sending remains in the user's mail client. No notification change is bundled.

Acceptance: sent replies update state, acknowledgments do not close unresolved work automatically, duplicate events do not duplicate state transitions, and out-of-order sync converges. Owner decides what counts as done and whether manual corrections persist across later mail before implementation.

### Phase 4: natural-language rules and provider expansion

**4A. Compile language into supported rule proposals.** Use the local model to translate a request into a small, reviewable rule shape with explicit unsupported cases. Route it through 1B's preview and confirmation. Start with approved senders, supported age conditions, and existing destinations only after the owner chooses semantics and precedence.

Acceptance: editing preserves unrelated conditions and actions, collisions are visible, unsupported requests create nothing, and the model cannot approve a new sender or bypass guards. New rule shapes and persistence need approval. No embeddings dependency is justified merely by this feature.

**4B. Consider Gmail or Microsoft APIs only after measuring an IMAP limitation.** Keep `MailProvider`. Document the concrete failure or performance limit, required scopes, verification burden, fallback, and operating cost before choosing OAuth or a server. Auth, dependencies, hosting, permissions, and architecture changes all wait for named decisions. No provider expansion is necessary for Phases 0 through 2.

## Decisions and approvals before implementation

- Confirm whether the next release keeps current Trash and automatic unsubscribe policies or adopts a stricter safety contract. The plan proposes accurate disclosure first, not changing saved behavior.
- Decide rule scope before any account-scoping change. Preview can disclose the current global scope without changing it.
- Choose new onboarding and conversation UI only after reviewing comps. Existing approved styling can be retained.
- Approve any persistence changes for durable unsubscribe status, conversation references, rule shapes, or corrected-state history. Approve each concrete schema and migration separately when prepared.
- Approve auth, provider scopes, dependencies, notifications, hosting, CI, signing, release, or spend only if a later package actually requires them. This plan makes none of those changes.

## Success criteria and measurement

Use local test evidence and consented user sessions first. No telemetry is assumed.

- First-use value: observe setup through the first inspected and approved action, including abandonment and failure causes. Establish a baseline before choosing a time target.
- Safety: verify that protected test messages remain untouched and ambiguous writes are not blindly replayed. Treat regressions as release blockers.
- Rule trust: verify preview and execution agreement for unchanged inputs and clear explanations when inputs change.
- AI usefulness: evaluate false-negative important mail separately from noisy false positives. Keep failures and uncertainty visible rather than hiding them in one aggregate score.
- Ongoing value: use confirmed archived or filed counts and explicit user feedback. Do not treat "request accepted" as confirmed unsubscribe or invented minutes saved as an outcome.

## Decision trail and verification record

The comparison kept Grokbox's native local-first architecture because both its product contract and current core support it. It prioritized preview and outcome accuracy because the source shows existing execution safety worth preserving and misleading promises worth correcting. It deferred conversation state until identity is reliable, and literal source reuse because license terms require separate review.

Only this plan was added. No code, dependency, schema, workflow, signing setting, saved preference, or mailbox was changed. No branch, commit, push, pull request, or external message was created. App behavior remains unverified by this audit.

Reference checks confirmed that every linked upstream source path exists in the pinned checkout and every cited Swift filename has a tracked match at the Grokbox baseline. `git diff --no-index --check /dev/null docs/INBOX-ZERO-UPDATE-PLAN.md` passed. The inline report was previewed at widths 728 and 390 with no browser console messages.

Independent source review by Claude Opus 5.5 identified three documentation corrections: Balanced also enables automatic unsubscribe, the abbreviated path note omitted directories, and the verification section promised a missing review record. All three were corrected. The review also confirmed the source claims it sampled and the approval boundaries. Final correction review by a fresh Claude Opus 5.5 agent found no remaining blocking issues.

Verdict: VERIFIED for this source-backed planning document against Grokbox HEAD `bae8b57361d8b3373ac29a503d969a7b7ba216ba` plus this uncommitted document. This verdict does not verify app behavior or release readiness. Builds, live mailbox tests, and model evaluations were omitted because this task produced a plan without changing runtime behavior.
