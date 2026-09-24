# Grokbox Upgrade — Research Notes

Scratch file for combining research threads on "what should Grokbox become," from
whatever angle each thread is coming from. Not a formal doc — `docs/DECISIONS.md`,
`docs/ROADMAP.md`, `docs/PRIVACY.md`, `docs/THREAT-MODEL.md` remain the source of
truth for what's actually been decided. Append new threads as dated sections below.

**Threads in this file:**
1. [ElectronMail comparison + current-state audit](#thread-1--electronmail-comparison--current-state-audit-2026-09-22) (2026-09-22)
2. [Jev QA-tooling test pass](#thread-2--jev-qa-tooling-test-pass-2026-09-22) (2026-09-22)
3. [Mailspring comparison + 5-feature build plan](#thread-3--mailspring-comparison--5-feature-build-plan-2026-09-22) (2026-09-22)
4. [DejaLu comparison + 5-item scoped implementation plan](#thread-4--dejalu-comparison--5-item-scoped-implementation-plan-2026-09-22) (2026-09-22)
5. [Full technical/UX/security/release audit](#thread-5--full-technicaluxsecurityrelease-audit-2026-09-05--2026-09-06) (2026-09-05 → 2026-09-06)
6. [Session status check, live sweep, and infrastructure findings](#thread-6--session-status-check-live-sweep-and-infrastructure-findings-2026-09-22) (2026-09-22)
7. [Thunderbird study for a full, private, good-looking client](#thread-7--thunderbird-study-for-a-full-private-good-looking-client-2026-09-23) (2026-09-23)

---

## Thread 1 — ElectronMail comparison + current-state audit (2026-09-22)

### The core tension

Grokbox and ElectronMail solve different problems. Grokbox is deliberately a
**read-only, no-send, no-body, no-cloud triage tool**. Several ADRs explicitly
reject the things that make an app "fully featured" in the conventional sense
(compose/send, delete, body reading, cloud sync). Any push toward "fully featured
email app" needs to first decide whether it's staying a triage tool with more
polish, or deliberately reversing specific ADRs.

### What Grokbox already has

- Multi-account IMAP, cross-account unified "Brief" (digest)
- Sender-level categorization (local model + optional Jev cloud fallback, address/subject only, never body)
- Rules (always sweep/keep), folder/label routing, snooze ("Later")
- RFC 8058 one-click unsubscribe, cleanup presets, sweep guard for flagged/needs-you mail
- Ephemeral-mail (OTP/reset link) decay scoring, due-date hints (`dueHint`, parsed by `DueDateParser`)
- Local notifications, macOS keyboard shortcuts, iOS swipe actions, data export/import
- Strong privacy posture: no telemetry, no body/attachment persistence, sandboxed (`network.client` only), TLS-enforced

### Architecture / sync details

- **IMAP only**, hand-written client (`GrokboxCore/Sources/GrokboxCore/Mail/IMAP/IMAPClient.swift`, `IMAPConnection.swift`). No SMTP, no Gmail API yet, no Exchange/JMAP.
- **Read-only by structural enforcement**: mailboxes opened with `EXAMINE`, bodies fetched with `BODY.PEEK`. Only `PlanExecutor` ever mutates (flags, labels, move); `SyncEngine` never does.
- **Poll, not push** — no IDLE, no APNs. `SyncEngine.swift` runs an Index pass (UIDVALIDITY + watermark, full/incremental) and a Read pass (up to 150 recent-unread candidates via `ImportanceScorer`, body fetched transiently, summarized, discarded — never persisted). Driven by `Maintainer.swift` on a timer or manual "Tidy up now."
- **On-device model layer** (`Analysis/LocalModel.swift`): `TextModel` protocol, conformers `FoundationModelsProvider` (Apple on-device, macOS 26+) and `OllamaProvider` (loopback-only). Given subject/sender/contact-flag/date/body-excerpt, returns summary, importance, reason, actionType, dueHint, isQuick. Also does sender `categorize`.
- **New in progress (untracked as of audit)**: `Security/JevKeyStore.swift`, `Services/JevCategorizer.swift`, `Services/JevSettings.swift` — an opt-in, off-by-default cloud fallback (`RemoteCategorizer` protocol, separate from `TextModel`) that POSTs sender address + sample subjects (never body) to `api.typesafe.ai` for 5-way sender categorization only, when the local model returns `.unknown`. Documented as ADR-0023.

### Blocked by explicit ADRs — would need a scope reversal, not a feature add

| Gap vs. "full email app" | Blocking decision |
|---|---|
| Compose/send mail | ROADMAP: "Sending mail. Out of scope. Grokbox is a triage tool." |
| Reading/searching message bodies | ROADMAP: "Headers answer every question the tool asks." + PRIVACY.md never persists bodies |
| Delete / true trash | ADR-0003/0019: never destroys a message, enforced by a test |
| Attachments (view/save) | PRIVACY.md: attachments never fetched at all |
| PGP/S-MIME | No body access at all, so no content to encrypt/decrypt |
| Hosted sync / push (APNs) | THREAT-MODEL: single `network.client` entitlement, no server, no cloud sync |
| Auto-acting on any cloud-model verdict beyond sender categorization | ADR-0023, verbatim "not planned" |
| Auto-sweep without prior explicit consent | ADR-0007: "a bulk verdict alone is not consent" |

Other decisions worth knowing before proposing anything adjacent:
- ADR-0001: Electron rejected (supply-chain risk) — macOS-only hand-written IMAP accepted as the cost.
- ADR-0002: Gmail API deferred — blocked on Google's OAuth restricted-scope verification + paid security assessment.
- ADR-0005: GPL-3.0 kept over MIT specifically to block a closed fork adding telemetry (flagged low-confidence, "revisit").
- ADR-0008: macOS < 26 support rejected (would require Foundation Models availability dance).
- ADR-0010: SwiftData to-many relationships rejected (quadratic insert cost) — plain `accountID` column + manual cascade delete instead.
- ADR-0011: Classifying every sender via the model rejected — deterministic-first is faster, no less accurate, more explainable.
- ADR-0015: Model-generated inbox digest rejected — deterministic/instant "Where things stand" digest chosen instead.

### Already on the roadmap (real, planned work)

- **v0.5**: live Gmail testing, Bridge STARTTLS support, XCUITest smoke suite, faster two-step reads (summary first, signals only for needs-you)
- **v0.6**: local-embedding sender clustering (dedupe `noreply@`/`news@` variants of the same brand)
- **v0.7**: natural-language rules ("sweep shipping notifications older than 30 days")
- **v0.8**: Gmail API backend (blocked on OAuth verification, ADR-0002)

### Fits the existing triage-tool philosophy — additive, no ADR conflict

- Local search over headers/summaries/sender metadata (not bodies) — ElectronMail's local-index idea, minus the body
- Command palette / expanded keyboard shortcuts (Superhuman-style) — macOS already has a shortcut base
- Accessibility audit pass (VoiceOver labels/Dynamic Type) — partial coverage today (~9 macOS + 2 iOS views), no dedicated audit yet
- Richer due-date/reminder surfacing (dueHint already parsed, could get its own view)
- Dark mode/theming polish, if not already complete
- Argon2-style master-password wrapping for the local SwiftData/Keychain store, mirroring ElectronMail's at-rest model (currently just Keychain — this is a persistence/security change, needs explicit sign-off)

### ElectronMail (github.com/vladimiry/ElectronMail) — what it actually is

Electron shell wrapping official ProtonMail/Tutanota/generic-IMAP webmail UIs; adds
native-app conveniences rather than reimplementing an email engine.

- Multi-account (isolated "API entry points"), switchable tabs; tray icon shows total unread across accounts + one-click "mark all read" — not a true unified inbox
- Local full-text search over cached bodies (needs opt-in local store)
- Offline access to cached mail/folders/contacts via encrypted local DB — **attachments not stored locally**, unavailable offline
- Local encrypted store (`database.bin`), opt-in
- Auto-login via OS keychain, auto-filled 2FA, experimental persistent sessions
- Custom JS-based message filtering (arbitrary user scripts, not a rules UI) — requires local store
- Native OS notifications per account, calendar notifications surfaced from the underlying webmail
- Batch move/delete (bypasses trash), batch export to `.eml`
- Dark mode, spell check, per-account custom CSS, image-proxying, Tor/per-account proxy support
- No dedicated snooze, no contacts app, no PGP/GPG of its own (delegates entirely to ProtonMail's crypto), no documented keyboard-shortcut set

**Security model**: `settings.bin` (credentials) encrypted via Argon2-derived key from
a master password. `database.bin`/`session.bin` encrypted with a random 32-byte key,
itself wrapped inside the Argon2-protected settings file — master-password-wraps-DEK
model. Whole DB decrypted into memory as a unit (not field-level) specifically to keep
metadata hidden, trading memory efficiency for that. No documented process-sandboxing
beyond Electron defaults. Explicitly defers transport/message crypto to the wrapped
webmail provider — its own threat model covers only local-disk-at-rest and login
automation.

**Sources**: github.com/vladimiry/ElectronMail (README, wiki, FAQ)

### General 2025/2026 "table stakes" checklist (Apple Mail, Spark, Airmail, Superhuman, Outlook, Mailbird)

- Unified inbox (Spark, Mailbird; Outlook notably lacks this)
- Thread/conversation view
- Snooze / Send Later (Spark, Mailbird, Airmail, Outlook)
- Undo Send (Superhuman, Mailbird)
- Split/VIP/Focused inbox (Superhuman Split Inbox, Outlook Focused Inbox)
- Templates/snippets with variable substitution (Superhuman)
- Unsubscribe detection (Outlook, Mailbird)
- Swipe actions (mobile)
- Search operators + rules/filters (advanced query syntax, automation)
- Offline mode (read/compose without connectivity, sync on reconnect)
- Multi-account switching, per-account signatures
- Push notifications
- Keyboard shortcuts / command palette (Superhuman: 100+ shortcuts, Cmd/Ctrl+K palette is the current bar)
- PGP/GPG or S/MIME (less common outside ProtonMail-adjacent/Canary Mail-class clients)
- Attachment previews (inline, no separate app)
- Calendar/scheduling integration
- Dark mode + accessibility (VoiceOver, Dynamic Type, high-contrast/reduced-motion)

Sources: spaceship.com/blog/best-email-clients, getmailbird.com (desktop clients /
multi-account rankings), canarymail.io/blog/superhuman-alternatives,
clean.email/blog/email-clients/superhuman-review, slashdot.org (Airmail vs Superhuman)

### Open question for whoever picks this up

Pick a direction before scoping further work:
1. **Stay a triage tool** — pull only from the "additive, no ADR conflict" list and the existing roadmap. No approval needed beyond normal feature work.
2. **Go for a real "full email app"** — reverse specific ADRs (send, body access, attachments, maybe PGP) one at a time, each needing its own explicit approval and ADR update.
3. **Hybrid** — name the one or two blocked items that actually matter (e.g. "I do want compose/send") and scope just that reversal, leaving the rest of the triage-only philosophy intact.

---

## Thread 2 — Jev QA-tooling test pass (2026-09-22)

A different angle from Thread 1: not "Jev as a shipped app feature" (that's the
`JevCategorizer`/ADR-0023 work Thread 1 already audits above) but "Jev as a QA
tool for testing Grokbox itself" — the `macos-jev-tester` skill, run against this
app to hunt bugs and review UI/UX copy. Two separate uses of the same underlying
TypeSafe API, kept deliberately distinct below.

### What Jev is, in this context

- TypeSafe's hosted API (`POST api.typesafe.ai/v1/systemone`, model `jev-latest` —
  `jev-1.13.0` observed in practice). Judges **text only** (`noul`/`choice`/`score`
  questions) — no vision, no local install, nothing named `jev` exists as a binary
  on this Mac.
- Needs `TYPESAFE_API_KEY`. Not exported into the shell by default on this
  machine — it lives in the macOS Keychain (`security find-generic-password -s
  "typesafe-api-key" -w`); confirmed present and working (200 OK live call).
- Distinct from Thread 1's `JevCategorizer`: that sends real sender-categorization
  requests as a shipped, opt-in app feature. This thread's use never ships — it's
  a testing tool driving the app's UI and judging test-run text (console output,
  accessibility labels, in-app copy), not real mail content, unless a live run
  accidentally exposes real account data (see blocker below).

### Privacy/architecture check done before running anything

- `docs/PRIVACY.md` (pre-Thread-1 wording) names exactly three outbound
  destinations — the user's IMAP server, loopback Ollama, and a clicked
  unsubscribe URL — and the sandbox carries only the `network.client` entitlement.
- `GrokboxCore/Tests/GrokboxCoreTests/PublicHostPolicyTests.swift` enforces that
  host allowlist in CI, not just in docs. Any new outbound host (`api.typesafe.ai`)
  needs that test updated deliberately — which is exactly what Thread 1's
  ADR-0023 work is already doing for the categorizer feature.
- Conclusion: **using Jev to test the app needs no privacy/architecture change**
  (Jev never becomes a host the shipped app talks to). Using Jev inside the
  shipped app is the one that needed the ADR + doc + allowlist-test update, and
  that's already underway per Thread 1.

### QA pass result (report-only, capped at 60 actions)

Pre-flight checks all passed: API key verified live via Keychain, Accessibility
permission granted, working tree unaffected by the run. Two of the skill's
optional add-ons were confirmed not applicable and skipped rather than run
pointlessly: **localization QA** (no `.xcstrings` or `.lproj` anywhere in the
repo — English-only today) and **Mac App Store metadata review** (`docs/
RELEASING.md` confirms Developer ID distribution outside the Mac App Store).

**Blocked before any live driving.** A real Grokbox instance (pid 19317,
`--section sweep --account 0`) was already running against real account data
when the agent went to pick a target pid. Launching the test pass's `--demo`
mode alongside it risked corrupting the shared SQLite-backed store and/or
exposing real sender/subject/body text to Jev, depending on default account
selection. The agent declined to guess past this and used none of the action
budget — this is the correct behavior, not a failure of the run.

**Completed anyway, since it needs no live app:** grepped the in-scope UI
strings (Senders/Sweep/Brief/Activity copy) and sent 20 to Jev for a
clarity/grammar pass.

| Issue | Location | Tier |
|---|---|---|
| "N look transactional" — missing "look**s**" | `GrokboxCore/Sources/GrokboxCore/.../SweepGuard.swift:76` | Flagged for review (score 0.86 / conf 0.59) |
| "N newest from this sender" — weak signal it reads as truncated | `SweepGuard.swift:78` | Weak, flagged (noul 0.53 / conf 0.53) |
| "Nothing is waiting on you — N unread not yet read by the model." reads self-contradictory | `GrokboxCore/Sources/GrokboxCore/Analysis/DigestBuilder.swift:104` | Below confidence threshold — direct read only, not Jev-confirmed |
| "not undoable" badge — double-negative phrasing | `Grokbox/Views/ActivityView.swift:73` | Below threshold — direct read only |
| "Moved on a non-Gmail server; find it in Archive." assumes IMAP folder knowledge | `ActivityView.swift:74` | Below threshold — direct read only |

Everything else sampled (guard banner, empty states, most per-sender
recommendation strings) scored clear at confidence 0.6–0.96 — no issues there.

**Not yet run**, pending the live-instance conflict above: full AX traversal,
accessibility-label audit, and live Senders/Sweep/Brief/Activity sort-filter
review.

### Next step for whoever picks this up

Quit the live Grokbox instance (or confirm it's disposable), then re-run
`macos-jev-tester` against `--demo` only to finish the live traversal and
accessibility audit this pass couldn't reach. The two grammar fixes in
`SweepGuard.swift` (lines 76/78) are small enough to act on now, independent of
that follow-up run.

---

## Thread 3 — Mailspring comparison + 5-feature build plan (2026-09-22)

A different comparison target from Thread 1 (ElectronMail): this thread compared
Grokbox against **Mailspring** (github.com/Foundry376/Mailspring), a full
send/receive client, then — once the user picked a direction — turned the gap
analysis into a concrete, sequenced implementation plan for 5 features. Same
core tension as Thread 1 reaches independently: Grokbox's ADRs and threat model
rule out most of what makes Mailspring "fully featured" (send, body storage,
cloud relay), so the question was scope direction first, features second.

### Mailspring, in brief

Local, native sync engine (a deliberate rewrite of the cloud-mandatory Nylas
Mail it forked from) — but it's a **hybrid**, not fully local: read receipts,
link tracking, and contact/company enrichment all route through Mailspring's
own cloud relay by design, and a "Mailspring ID" account exists for Pro
licensing. Compose/templates/signatures/undo-send/client-side scheduled send,
full-text search, thread view, snooze, follow-up nudges, and a genuine
plugin/theme architecture (its most distinctive feature — deeper than any
mainstream client offers). No native PGP/S-MIME (only an unmaintained
third-party plugin), no AI/priority-inbox triage.

### Scope decision (made by the user before any code was touched)

Given three options — (1) stay in-lane and cherry-pick fitting features, (2)
reverse ADRs for a full send/receive client, (3) hybrid opt-in send as a
disclosed exception like the Jev cloud fallback — **the user chose (1): stay
in-lane.** No ADRs are being reversed by this thread's work.

### The 5 features chosen (triage-side gaps, no ADR conflict)

1. Search — over already-synced metadata (subject/sender/date/category)
2. Thread/conversation view — extend existing thread grouping into a reader
3. Manual folder management — expose folder move/create to the user
4. Contacts-lite — surface the existing contacted-address frequency data
5. Local notifications — believed missing, turned out mostly already built

### Code-reading pass (two rounds — architecture survey, then per-feature grounding)

- **Search**: `MessageHeader` has queryable but unindexed `subject`/`senderName`/`summary`
  (full scan acceptable at current volumes, per existing code comments). No
  query/filter abstraction exists anywhere — every call site builds `#Predicate`
  inline. `SendersView.swift`/`PhoneSendersView.swift` already do exactly this
  kind of client-side `.localizedCaseInsensitiveContains` + `.searchable(text:)`
  filtering over senders — the pattern to copy for messages, not a new abstraction.
- **Thread view**: `ThreadKey.swift` groups by sender + normalized subject only
  (no `In-Reply-To`/`References`/Gmail thread-ID) — used today purely for
  bulk-action clustering (`BriefRanking.collapsedByThread()`), never for reading.
  A transient per-message body-fetch path already exists and is reusable
  (`MailProvider.bodyExcerpt(uid:)` → `BodyExtractor.plainText`), currently only
  called inside the batch reader pass in `SyncEngine.runRead`, excerpt never
  persisted. A real reader needs its own on-demand, independently-owned
  connection — must not reuse `SyncEngine`'s/`PlanExecutor`'s connection or it
  can be torn down by an unrelated Stop action.
- **Folder management**: folder targets are 100% automatic today
  (`CleanupPlan.Item.folder` ← `cluster.category.folderName`); `PlanExecutor.apply()`
  already has every primitive needed (`ensureMailbox` = create-only,
  `move(uids:to:)`/Gmail label add-remove) — a picker just needs to feed a
  user-chosen folder name into the existing per-sender override mechanism
  (`SenderRule`/`RuleStore`), the same mechanism that already overrides
  `disposition`/`autoUnsubscribe`. No new mutation verb, no delete/expunge path.
- **Contacts**: already a working, populated frequency table under the hood —
  `SyncEngine.learnContacts()` upserts `ContactedAddress` (address, count,
  last-contacted) from the last 2,000 Sent messages, but it's only ever
  consumed as a boolean signal (`everContacted`) for sweep-guarding/scoring.
  Never surfaced in any view. A contacts view is almost entirely new UI over
  data that already exists — no new model, no new sync work.
- **Notifications**: turned out to be a stale assumption, not a gap — Mac already
  has a working `NotificationService` (`UNUserNotificationCenter`), a settings
  toggle, and a permission-request call wired to it; it fires after every
  tidy-up run on both Mac and iOS builds (`AppState.swift` compiles into both
  targets). The only real gap is iOS's settings screen has no toggle to turn it
  on. Smallest of the five by far.

### Build order and why

**Notifications → Contacts → Search → Reader → Folder picker** — safest and
smallest first (notifications is a near-trivial toggle; contacts and search are
pure reads/client-side filtering with zero mutation risk), ending with folder
management deliberately last because it's the only one of the five that changes
behavior of the *mutating* sweep path (`PlanExecutor`) — doing it last means
nothing else in this batch has touched that code first. Each feature ships and
is verified (`swift test` + a manual check) before the next one starts, not as
one combined change.

### Full per-feature plan — files, reuse, tests, risk (ready to build)

1. **Notifications (iOS toggle).** Add a `Section("Keep it clean")` to
   `GrokboxiOS/PhoneSettingsView.swift` with `@AppStorage("grokbox.notify")` +
   `.onChange` calling `NotificationService.requestPermission()` — an exact
   copy of the working Mac toggle in `Grokbox/Views/SettingsView.swift`.
   `AppState.swift`'s `NotificationService`/`notifyIfWorthwhile` already
   compiles into both targets and already fires after every `Maintainer` run;
   nothing else changes. No `GrokboxCoreTests` coverage (this code is outside
   the SwiftPM target) — verify manually: one permission prompt on toggle-on,
   one notification after a tidy-up run that finds something. No risk — no
   mutation path touched.

2. **Contacts view.** New `GrokboxCore/Sources/GrokboxCore/Analysis/ContactDirectory.swift`:
   a `ContactSummary` struct + `ContactDirectory.summaries(contacts:profiles:)`
   joining `ContactedAddress` (address/count/last-contacted, already populated
   by `SyncEngine.learnContacts`) to `SenderProfile` by address, same
   `Dictionary(..., uniquingKeysWith:)` join already used in `BriefView.swift`.
   New `Grokbox/Views/ContactsView.swift` + iOS equivalent sheet, both reached
   via a new toolbar button on `SendersView.swift`/`PhoneSendersView.swift` (no
   navigation-enum changes needed). Tests: new `ContactDirectoryTests` suite in
   `GrokboxCore/Tests/GrokboxCoreTests/ProfileTests.swift` — sort order by
   `timesContacted`, no-profile-match falls back to raw address, no
   crash/duplication across accounts. Risk: none — read-only, no new IMAP calls.

3. **Search.** Client-side `.localizedCaseInsensitiveContains` filtering over
   subject/sender/summary, matching the existing `SendersView.swift` sender-search
   pattern exactly — no server SEARCH, no new indexes (subject/senderName/summary
   stay unindexed; full scan is fine at current volumes per existing code
   comments). `Grokbox/Views/BriefView.swift` and `GrokboxiOS/PhoneBriefView.swift`
   get `@State searchText` + a filtered computed property + `.searchable(text:)`.
   `Grokbox/Views/SenderMessagesSheet.swift` gets a plain `TextField` instead of
   `.searchable`, since that view has no `NavigationStack` wrapper when presented
   as a sheet and `.searchable` isn't guaranteed to render there — a deliberate,
   documented deviation, not a new abstraction. No new tests required (pure
   view-layer filtering over already-tested data). Risk: none.

4. **On-demand message reader.** New `GrokboxCore/Sources/GrokboxCore/Mail/MessageBodyReader.swift`
   wraps the same three calls `SyncEngine.runRead` already makes
   (`MailProviderFactory.connect` → `openReadOnly` (`EXAMINE`) → `bodyExcerpt(uid:)`
   (`BODY.PEEK`) → `BodyExtractor.plainText`), but on its **own independent
   connection** — never `state.engine.activeProvider`/`state.executor.activeProvider`,
   so an unrelated Stop action can't tear it down and it never fights the sync
   engine for ownership of the account's connection. Nothing is written back to
   `MessageHeader` — display-only, discarded on sheet close. New
   `Grokbox/Views/MessageReaderSheet.swift` (loading/body/error states), wired
   from a new "Read" button in `SenderMessagesSheet.messageRow` next to the
   existing "Open" (webmail link) button. Tests: extend
   `GrokboxCore/Tests/GrokboxCoreTests/IMAPClientTests.swift` (same fake-server
   pattern as `fetchesBodyExcerpt`/`indexingIsStructurallyReadOnly`) — correct
   body returned; command trace contains `EXAMINE`/`BODY.PEEK`, never
   `SELECT`/`STORE`/`\Seen`/`EXPUNGE`; empty body throws a dedicated error
   instead of showing blank text. Risk: this is the one feature introducing new
   network code — mitigated by using `EXAMINE` (protocol-guaranteed read-only,
   a second line of defense beyond `BODY.PEEK`), its own connection, no writes,
   and a capped excerpt length.

5. **Folder picker (last — the only mutating-path change).** Extends the
   existing per-sender override mechanism (`SenderRule`/`RuleStore`/`SenderOverride`
   in `GrokboxCore/Sources/GrokboxCore/Models/SenderRule.swift`) — the same one
   that already overrides `disposition`/`autoUnsubscribe` — rather than inventing
   a new model or plan-building path. Add `customFolder: String?` to
   `SenderRule`/`SenderOverride`; add `RuleStore.setCustomFolder(_:for:in:)`,
   which **forces `disposition = .fileIntoFolders`** whenever a folder is set,
   so a folder pick can never be silently discarded by a trash/archive-only
   disposition. In `Sync/CleanupPlan.swift`, `Item.folder` becomes a stored
   property (`override?.customFolder ?? cluster.category.folderName`), and
   `byFolder` regroups by the resolved folder string instead of category — a
   display-only change; double-check `SweepView.swift`'s consumer still renders
   correctly after this edit. `PlanExecutor.swift` needs **no change** — it
   already consumes `item.folder` generically for both the Gmail-label and
   `ensureMailbox`/`move` branches. New `Grokbox/Views/FolderPickerSheet.swift`
   lists live mailboxes via `discoverMailboxes()` (same live-connect pattern as
   `AddAccountSheet.swift`/`AccountOnboarding.swift`) plus a free-text
   "new folder" field; wired into the existing "Where this sender's mail goes"
   menu section in `SendersView.swift`/`PhoneSendersView.swift`. Tests: extend
   `GrokboxCore/Tests/GrokboxCoreTests/SenderOverrideTests.swift` — custom
   folder beats category default; setting one forces `.fileIntoFolders`;
   `byFolder` groups two different-category senders under one custom-folder
   group; clearing the override returns to the category default. **Risk
   (read carefully — this is the only feature touching the mutating sweep
   path):** no new `MailProvider` method, no new `ActionKind` — it can only
   ever *create* (`ensureMailbox`) and *move* (`move`/`setGmailLabels`), never
   delete; free-typed folder names still go through the existing
   `serverName(forLogical:)` UTF-7/namespace encoding, so no injection surface
   beyond what category folders already have; the `disposition = .fileIntoFolders`
   coupling above is the key safety property protecting against a silently
   discarded folder choice.

### Sources

github.com/Foundry376/Mailspring (README), getmailspring.com/pro,
foundry376.zendesk.com (scheduled-send, open-tracking, and data-collection
help-center articles), github.com/Foundry376/Mailspring/issues/25 (PGP feature
request, never merged), github.com/dinoboy197/mailspring-openpgp,
foundry376.github.io/Mailspring/guides/Architecture.html (plugin SDK),
github.com/Foundry376/Mailspring-Theme-Starter — plus this session's own
two-pass read of the Grokbox codebase (file/function references above).

---

## Thread 4 — DejaLu comparison + 5-item scoped implementation plan (2026-09-22)

A third angle: compare against `github.com/dinhvh/dejalu` specifically (the user's
named reference), independently re-confirm Thread 1's "triage tool, not a full
client" framing, then go a step further than Thread 1's open-ended list —
turn the "additive, no ADR conflict" candidates into a concrete, already-approved
implementation plan with exact files and code shapes.

### DejaLu (github.com/dinhvh/dejalu) — not a moving target

- Native **macOS-only**, built on the same author's (Hoa Dinh's) MailCore2/libetpan
  stack — spiritual successor to his earlier app Sparrow (acquired by Google, 2012).
- **Dead**: last commit 2019-01-08, 48 open issues, several literally titled
  "is this dead?". Google Sign-In has been broken for years (issue #72, unresolved) —
  the app likely can't add Gmail accounts anymore.
- No PGP/S-MIME (issue #47, never built), no Exchange (issue #68, never built), no
  Windows/iOS/Android. Shipped Google Analytics + HockeyApp crash reporting with no
  opt-out, flagged for GDPR non-compliance in its own issue tracker (#57).
- **Verdict**: useful only as a cautionary reference (what an unmaintained client
  with undisclosed telemetry looks like from the outside), not a feature bar to
  chase. Complements Thread 1's ElectronMail comparison as a second "here's an
  existing client" data point — the two land on the same conclusion via different
  examples.

### Independent confirmation of Thread 1's core finding

Re-derived the same conclusion Thread 1 reaches (Grokbox is a deliberately-scoped
triage tool, not a general client) from a fresh read of the ADRs/roadmap/threat
model, without reference to Thread 1's work. Worth noting as two independent
passes landing on the same read of the architecture — see Thread 1's ADR table
above for the full list; not repeated here.

### Differentiator angle not yet covered by Thread 1: on-device AI vs. the field

| | On-device AI (categorization/summarization) |
|---|---|
| Apple Mail | Yes — Apple Intelligence, fully on-device (iOS 18+) |
| Gmail | No — Gemini-powered, cloud |
| Spark | No — cloud (Plus/Pro tiers) |
| Outlook | No — Copilot, cloud (M365) |
| **Grokbox** | **Yes** — `LocalModel`/`FoundationModelsProvider`/`OllamaProvider`, already shipped |

Apple Mail is the only major competitor doing on-device AI for mail today; Gmail,
Outlook, and Spark all route mail content through cloud AI to power the same
features. This validates Grokbox's existing local-AI angle as a genuine,
still-open differentiator — worth sharpening (the roadmap's v0.6 embedding-cluster
and v0.7 NL-rules items both already point this direction), not diluting with
send/search/sync bolted on to chase "fully featured."

### Full table-stakes checklist (Apple Mail, Gmail, Spark, Outlook, Edison, Airmail, Newton)

A second, independent checklist from a different app set/source list than
Thread 1's (which cites Superhuman/Mailbird/spaceship.com); the two overlap
heavily but cross-checking both is more evidence than either alone. "Table-stakes"
= nearly every reference app has it; "Differentiator" = a real split exists.
Newton relaunched June 2026 (desktop-first, Gmail/Outlook/M365 only, mobile
still catching up) — treated as volatile/niche, not a strong signal either way.

| Category | Table-stakes | Real differentiators |
|---|---|---|
| Account/protocol | OAuth2 multi-account, unified inbox | Exchange ActiveSync (OL native; SP/NT weaker) |
| Sync/offline | Offline read, offline compose+outbox | Push via IMAP IDLE (non-Gmail apps); cross-device app-state sync is strongest in apps that proxy mail through their own servers (SP, ED) vs. pure-IMAP apps (AM) relying on IMAP flag propagation |
| Organization | Threading, folders/labels | Smart tabs/categories (now mainstream: GM native, AM iOS 18.2+ Primary/Transactions/Updates/Promotions+Digest, SP Personal/Notifications/Newsletters); VIP/priority senders; saved/smart mailboxes |
| Actions | Swipe actions, signatures, mail rules | Snooze, scheduled send, undo send, templates (all now table-stakes-trending but still absent in laggards); one-tap unsubscribe (GM/AM/ED/SP have it, still a real differentiator vs. laggards); mute thread |
| Composition | Rich text, inline images, drafts autosave | Cloud attach (Drive/OneDrive/iCloud); cross-device drafts sync reliability |
| Notifications/system | Share extension | Actionable push, widgets (now table-stakes on iOS), Siri/App Intents/Shortcuts, multi-window/iPad split view, Watch app (many apps have dropped it), Spotlight (AM/system-only) |
| **Privacy/security** | Biometric app lock (now table-stakes: GM/OL/SP/ED/AIR have it, **AM notably does not** — relies on device lock) | PGP/S-MIME (niche: AM/OL/AIR only); **tracking-pixel/read-receipt blocking** (AM's Mail Privacy Protection is the standout; GM/OL/SP do not block by default); remote-image proxying; **local-only processing, no server relay of mail content** (AM + local-only apps only — this is the axis Grokbox already sits on) |
| **AI/smart** | Smart categorization, AI summarization (both now shipping free in GM/AM/OL/SP in 2026) | Smart/AI-drafted replies (premium-tier in most); priority-inbox scoring; **on-device vs. cloud AI processing** (see differentiator table above — AM is the only major competitor matching Grokbox here); agent/automation features acting on your behalf (SP Pro, Spark CLI/MCP, Newton's 2026 roadmap — bleeding-edge, worth tracking not chasing) |

Three items from this table directly shaped the 5-item plan below: biometric
lock (now table-stakes and absent in Grokbox — item 3), tracking-pixel/remote-
image blocking (a Grokbox already-wins-this differentiator that just wasn't
documented — item 2), and the on-device-AI axis (confirms nothing in the plan
should touch the model layer, since Grokbox already leads there).

### Two real bugs found in passing (not features — doc/code correctness issues)

1. **`docs/PRIVACY.md`'s outbound-connection table is incomplete.**
   `AutoconfigService.swift:8-11` calls itself "the fourth and last kind of
   outbound connection" (only the domain of the typed address is sent, during
   account setup, to the provider's own autoconfig host and to Mozilla's ISPDB
   at `autoconfig.thunderbird.net`) — but PRIVACY.md's table never lists it, and
   the doc's own verification recipe (`grep ... | grep -v "^.*//"`) accidentally
   filters out every line containing `https://`, hiding both autoconfig URLs from
   anyone who runs it to check. Independently corroborated by `audit/issues.md:2385-2388`.
2. **`LinkHygiene.swift` (the phishing-tell checker) has zero production call
   sites** — it's only exercised by `AutoconfigTests.swift`. Its domain-mismatch/
   IP-literal/phishing-phrase warnings never actually reach a user today. Adjacent
   to hygiene/privacy work but not part of the 5-item plan below; flagged for a
   future pass.

### Approved 5-item plan (user picked the scoped option for each; ready to build)

All five stay inside existing constraints: no third-party dependencies, no new
network destinations beyond what's already disclosed (items 3–5 add none at all),
App Sandbox preserved, GPL-3.0 untouched.

1. **Fix `docs/PRIVACY.md` — autoconfig gap.** Add a table row for the two
   autoconfig endpoints (between the IMAP row and the Ollama row); fix the "that
   is the complete list ... without turning anything on" sentence to account for
   the setup-time button press; fix the broken verification grep (drop the
   `grep -v "^.*//"` clause that's eating the `https://` lines it's supposed to
   surface). Docs only, no code.
2. **Fix `docs/PRIVACY.md` — tracking-pixel/remote-image claim.** Investigation:
   there is no HTML renderer anywhere in the app (exhaustive grep for `WKWebView`,
   `NSAttributedString(html:`, `loadHTMLString` — zero matches, across Grokbox/
   GrokboxiOS/GrokboxCore). Bodies go `BODY.PEEK[TEXT]` → `BodyExtractor.stripHTML`
   (naive tag-stripping) → plain text in an LLM prompt → discarded. A tracking
   pixel's `<img src=...>` becomes stripped text; no request is ever made. This is
   already stated in `LinkHygiene.swift:3-7` and `docs/LANDSCAPE.md:90-96`, but
   never in PRIVACY.md/THREAT-MODEL.md where a privacy-conscious reader would look
   for it. **Not a code feature** — there's no image-loading path to block, since
   one never existed. Docs only: add a line reusing the phrasing already drafted
   in LinkHygiene.swift.
3. **Biometric app lock** (Face ID/Touch ID on open). Net-new subsystem (zero
   prior `LocalAuthentication`/`LAContext` usage in the repo — confirmed via a
   full-repo grep). Two new files:
   `GrokboxCore/Sources/GrokboxCore/Services/BiometricLockSettings.swift`
   (copies `JevSettings.swift`'s exact shape — `Codable`/`Sendable`/`Equatable`
   struct, `public var enabled: Bool`, `UserDefaults`-backed `static var current`,
   key `grokbox.biometricLockSettings`) and
   `GrokboxCore/Sources/GrokboxCore/Security/BiometricAuthenticator.swift` (a
   thin wrapper exposing `async func unlock() -> Bool`, calling
   `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, ...)`
   with a fallback to `.deviceOwnerAuthentication` so a passcode/password still
   works if biometrics aren't enrolled). Wired into `AppState.swift` the same
   way as `jevSettings` (line 30-35: a `didSet` that persists on change), plus
   a new transient, **non-persisted** `var isUnlocked: Bool` that resets to
   `false` on cold launch whenever `biometricLockSettings.enabled` is true.
   Gates `RootView.swift`'s `body` (macOS, line 26) and `PhoneRootView.swift`'s
   `body` (iOS, line 22) with a new `LockView` shown instead of the normal
   content — reusing the app's existing empty-state visual language already in
   `RootView.swift` (`emptyState`/`getStarted`: centered `VStack`, SF Symbol
   icon, headline, one prominent button) rather than inventing new visual
   language, per the user's pick over a branded full-screen lock or a
   no-screen/system-prompt-only approach. Settings toggle
   (`Toggle("Require Face ID to open Grokbox", isOn: ...)`) follows the exact
   Jev-toggle pattern in `SettingsView.swift:169-186` /
   `PhoneSettingsView.swift:44-56`, in both app targets. iOS needs
   `INFOPLIST_KEY_NSFaceIDUsageDescription` added to the `GrokboxiOS` target's
   `settings.base` block in `project.yml` (missing today — required, or the
   app crashes on the first `LAContext.evaluatePolicy` call on iOS). No
   entitlement changes needed on either platform — `LocalAuthentication` needs
   no App Sandbox exception.
   **Two caveats surfaced by exploration, scoped out deliberately:**
   (a) `KeychainStore.swift` stores the IMAP passwords with
   `kSecAttrAccessibleWhenUnlocked` only — no `SecAccessControl`/
   `.biometryCurrentSet` today. Upgrading that is a Keychain-item-level,
   credential-storage change, a "stop and ask" category on its own; this plan
   only adds an app-open UI gate, not biometric-gated credential reads.
   (b) macOS's `MenuBarExtra` (`MenuBarView.swift`) renders independently of
   `RootView` and will keep showing live status even while the main window is
   locked — not a new gap, just the boundary of what "locked" covers, worth
   knowing before calling this "fully locked."
4. **Header-only search — sender + subject, macOS only.** Body search stays out
   of scope per the existing ADR ("headers answer every question the tool asks").
   Add `subject` to `MessageHeader`'s `#Index` (additive, no migration stage
   needed per `GrokboxStore.swift`'s own migration-plan comment). Add
   `.searchable(text:)` to the existing per-sender message list,
   `SenderMessagesSheet.swift` (macOS-only screen today), mirroring the exact
   `.searchable`/`localizedCaseInsensitiveContains` idiom `SendersView.swift`
   already uses for sender-name search. **User picked macOS-only for v1** over
   also building a net-new iOS equivalent screen (no iOS counterpart exists yet).
5. **Shortcuts `AppIntent` — "Tidy up now", in-app only.** Calls the existing
   canonical entry point, `AppState.tidyUp(_:)` (`AppState.swift:325-328` —
   already what every "Tidy up now" button calls: `MenuBarView.swift:54`,
   `BriefView.swift:154-158`, `SettingsView.swift:90-91`). New file
   `Grokbox/TidyUpIntent.swift` (shareable into the iOS target the same way
   `project.yml` already shares several `Grokbox/` files into `GrokboxiOS`,
   lines 49-59):
   ```swift
   import AppIntents

   struct TidyUpIntent: AppIntent {
       static var title: LocalizedStringResource = "Tidy Up Now"
       static var openAppWhenRun: Bool = true   // runs in-process; no App Group needed

       @MainActor
       func perform() async throws -> some IntentResult {
           let state = AppEnvironment.state
           let accounts = try state.context.fetch(FetchDescriptor<MailAccount>())
           await state.tidyUp(accounts)
           return .result()
       }
   }

   struct GrokboxShortcuts: AppShortcutsProvider {
       static var appShortcuts: [AppShortcut] {
           AppShortcut(intent: TidyUpIntent(), phrases: ["Tidy up \(.applicationName)"])
       }
   }
   ```
   (`AppState.context`/`ModelContext` access pattern to confirm exactly against
   `AppState.swift` during implementation; `AppEnvironment.state` is the
   existing singleton accessor both app entry points already use.)
   `openAppWhenRun = true` — runs in-process once Shortcuts/Siri launches the
   app, so **no App Group entitlement, no widget extension target, no
   `GrokboxStore` storage rework, no `project.yml` target changes needed**.
   User explicitly declined the fuller version (App Group + home-screen digest
   widget) — that would require reworking `GrokboxStore.storeURL` off
   `.applicationSupportDirectory` onto a shared App Group container
   (confirmed: no App Group exists anywhere in the repo today), a real
   sandbox-boundary change, not a small addition. No new outbound connection,
   no `docs/PRIVACY.md` change needed.

### Verification plan for the 5 items

- **Items 1–2 (docs):** re-run the fixed verification grep from
  `docs/PRIVACY.md` against `GrokboxCore/Sources` and confirm it now surfaces
  the autoconfig URLs; proofread the new table row/sentences for tone.
- **Item 3 (biometric lock):** build both targets; verify in Simulator (Face
  ID enrolled via Features > Face ID > Enrolled) and on macOS (Touch ID, or
  the password fallback) that enabling the setting locks the next cold
  launch and "Unlock Grokbox" reveals normal content; screenshot the lock
  screen on both platforms before calling it done.
- **Item 4 (search):** run `GrokboxCoreTests` to confirm the additive index
  change doesn't break opening an existing on-disk store; manually search a
  known subject substring in `SenderMessagesSheet` and confirm it filters;
  screenshot the result.
- **Item 5 (Shortcuts intent):** build, then add "Tidy up now" as a Shortcut
  action via the Shortcuts app and run it — confirm the app opens and a
  tidy-up actually executes (check the Activity view / `CleanupAction` log
  for a new entry). Test the Siri phrase if feasible in Simulator.
- Run `GrokboxCoreTests` and `GrokboxiOSUITests` after each item, not just at
  the end, per repo convention — ship one item at a time, verified, rather
  than as one combined change.

**Sources**: github.com/dinhvh/dejalu (repo, README, `.gitmodules`, issues,
dejalu.me), and this repo's own `AutoconfigService.swift`, `BodyExtractor.swift`,
`LinkHygiene.swift`, `MessageHeader.swift`, `RootView.swift`, `PhoneRootView.swift`,
`JevSettings.swift`, `AppState.swift`, `project.yml`, `docs/PRIVACY.md`,
`audit/issues.md`.

---

## Thread 5 — Full technical/UX/security/release audit (2026-09-05 → 2026-09-06)

Synthesized from `audit/` (README, executive-summary, application-understanding,
platform-and-stack, build-results, performance, issues.md — 112 findings) plus
`docs/AUDIT.md`, `docs/LANDSCAPE.md`, and `docs/PRIVACY-GUIDES-AUDIT.md`. Full
detail lives in those files; this section is the condensed cross-reference.

### Method

Three layers of evidence: runtime measurement on the real app (`ps`, `sample`,
screenshots, the app's own log), the engine test suite, and an 11-dimension
parallel code review where every finding was independently re-checked against
source with the aim of refuting it (27 of 139 raw findings were refuted and
dropped, leaving 112). Environment: Apple Silicon, macOS 27.0, Xcode 26.6,
Swift 6, Debug ad-hoc-signed build, Apple Foundation Models available.

**Never tested: a real IMAP server.** Every IMAP path ran only against a
hand-written fake and the demo mailboxes — the single largest risk called out
by every one of these audits.

### Verdict

**Not release-ready, but close — engineering is genuinely good.** Clean
app/engine split, 101–109 passing tests (including a loopback IMAP server, not
mocks-on-mocks), Swift 6 strict concurrency throughout, zero third-party
dependencies, a two-entitlement sandbox, and a privacy story that survived a
hostile read. What blocks shipping is a small number of specific defects, not
systemic rot.

### P0s — found and fixed during the audit

| Defect | Evidence |
|---|---|
| 100% of a CPU core burned permanently while idle, every screen | `MenuBarExtra(isInserted:)` bound to `@AppStorage` created an unbounded scene-invalidation loop (8.10 → 0.03 cpu-sec/8s once un-bound) |
| Main window never appeared at launch | `WindowGroup(id:)` not presented at launch on macOS 27 (ADR-0016) |

### ⚠️ Open contradiction — is the IMAP timeout actually fixed?

`docs/AUDIT.md`'s "P1 fixes — 6 September 2026" section claims the IMAP
connect/read timeout bug (`withTimeout` never firing) was fixed, with a
regression test (`IMAPDeadlineTests`) showing a 3 s deadline now firing in
2.1 s. **`audit/executive-summary.md`, dated the same day, says that claim is
false** — it independently reproduced the same 3-second timeout *not* firing
after 12 seconds, and states outright: "`docs/AUDIT.md:50` claims this class
of hang is fixed. That claim is false and should be corrected." Both documents
cite specific evidence; neither has been reconciled. **Before trusting either
one, re-run `IMAPDeadlineTests` and the manual repro
(`audit/evidence/imap-timeout-repro.txt`) against current `main` and see which
account matches reality now.**

### Findings register (`audit/issues.md`, 112 findings)

| Severity | Count | | Top areas | Count |
|---|---|---|---|---|
| P1 | 3 | | completeness | 12 |
| P2 | 31 | | product-alignment | 12 |
| P3 | 59 | | ux-hig | 12 |
| P4 | 19 | | imap-protocol | 10 |
| | | | accessibility | 10 |

The three P1s (GB-001–003) are one theme — failure handling: the UIDVALIDITY
guard protecting Undo is disarmed by the next index pass (data-integrity risk),
and the IMAP timeout issue above. Notable P2/P3 highlights worth knowing
without reading all 112:

- **GB-029** — attacker-controlled email body is concatenated into the triage
  prompt; a phishing mail could promote itself into "Needs you" with a
  Grokbox-authored summary (the Jev categorizer added since — Thread 1 — takes
  the same untrusted-input framing seriously, for what it's worth).
- **GB-030** — unsubscribe POST follows sender-controlled redirects
  unvalidated (could aim at loopback/LAN services).
- **GB-011 / GB-027** — no `VersionedSchema`; container-open failure is a bare
  `fatalError`. *(Per `docs/AUDIT.md`, this was fixed 6 Sep — `GrokboxSchemaV1`
  + `GrokboxMigrationPlan` — worth confirming it's still true, given the
  timeout contradiction above.)*
- **GB-042 / GB-043** — two separate cases of docs/comments citing things that
  don't exist (a "live" outbound connection that's dead code; an ADR number
  that was never written).
- Full list: `audit/issues.md`.

### Performance — measured, not estimated

| Metric | Result |
|---|---|
| Launch (cold → first window) | 0.83 s, then 0.26–0.27 s |
| 40,000 messages → 400 sender profiles | 1.45 s (was 365 s before an indexed `accountID` column replaced a to-many relationship) |
| UI-facing profile query | 0.039 s |
| Sweep of 3,742 messages / 47 senders | ~5 s, 0 errors |
| Idle RSS (3 demo accounts, ~5,000 messages) | settles ~124 MB |
| On-device model read, one message | ~2–10 s (structured schema costs the high end) |

**Remaining perf risk, not fixed:** the model-reading loop is strictly
sequential and uncapped — a real 40k-message backlog's first "catch-up" pass
is a multi-hour operation with no concurrency and no resumable checkpoint
beyond a progress label.

### Privacy Guides standards audit — verdict

**Meets minimum with notes** for *Email Clients*; **does not meet minimum**
for *AI Chat* (macOS-only fails that category's multi-platform row). No
telemetry, no account, no vendor server, sandboxed, Keychain-backed, TLS-only,
zero dependencies — all verified in code. Two open notes:
- **C2 (partial)** — mail content goes to Apple's on-device model (closed,
  unverifiable from outside) or loopback Ollama; the Ollama path is fully open.
- **D3 (highest-leverage fix)** — releases aren't signed yet. `scripts/release.sh`
  is written and works; blocked on a paid Developer ID Application certificate
  (same blocker as `docs/RESUMING.md`).

Every byte that leaves the device, per this audit: the user's own IMAP server
(TLS), `127.0.0.1:11434` Ollama if chosen, and a sender's own
`List-Unsubscribe` URL only on click. (Thread 1 above adds a fourth, newer
one: `api.typesafe.ai` for the opt-in Jev categorizer.)

### Landscape — what other open-source clients do (`docs/LANDSCAPE.md`)

Studied: Thunderbird, Betterbird, K-9/Thunderbird for Android, FairEmail,
Mailspring, Proton Mail, Tuta, Geary/Evolution. Grokbox is explicitly not
competing as a full client — the study's point was to borrow what serves
*triage* and name what's deliberately out of scope (compose/send, PGP,
calendars, POP3/Exchange, add-ons).

**Adopted from this study:** `AutoconfigService` (Thunderbird's discovery
ladder — config file → provider autoconfig XML → Mozilla ISPDB → guess →
manual — domain-only, never sends the address), `LinkHygiene` (phishing tells:
domain-mismatch link text, punycode look-alikes, bare-IP links).

**Roadmap ideas surfaced, not yet built:** condition rules (subject/list-id →
folder, ordered after the sweep guard), a local Bayesian junk tier trained by
sweeps/keeps, message search over the index, IMAP IDLE to trigger tidy-ups on
arrival, a verified OAuth2 client shipped in source (Thunderbird's own
precedent: it ships its Google client ID/secret in source — the blocker is
Google's *verification* of the project, not "open source can't ship OAuth
creds," which reframes ADR-0002).

### Recommended release plan (from `audit/executive-summary.md`)

1. **Before any use on a real mailbox** — fix `withTimeout`/cancellation (see
   the open contradiction above), fix the UIDVALIDITY/Undo interaction, add
   schema versioning with a recoverable fallback.
2. **Before giving it to anyone else** — accessibility pass (labels, contrast,
   don't rely on color alone), app icon + `PrivacyInfo.xcprivacy` + Developer
   ID signing/notarization, a real `Settings` scene (⌘, currently does
   nothing per this audit — confirm still true), a password-update flow that
   doesn't destroy history.
3. **Before calling it v1** — real-server test matrix (Gmail, Proton Bridge,
   Fastmail, Dovecot), bound or make resumable the first-run experience on a
   40k-message mailbox, CI running `swift test` + a UI smoke test.

Some of this list is very likely already done given the 16 days of work since
(Thread 1/6 note menu-bar commands, a real Settings scene reference, and CI
already exist) — **this audit is now over two weeks stale against a fast-moving
`main`.** Treat every unchecked item here as "verify current status," not
"still true."

---

## Thread 6 — Session status check, live sweep, and infrastructure findings (2026-09-22)

From a session that reviewed current git/CI state and attempted to run the
long-pending real-mailbox sweep. Operational/safety findings, not feature
research — complements the other threads (especially Thread 1 and Thread 5)
rather than overlapping.

### Where the project actually stands right now

- v0.4 is fully merged: `feature/cleanup-policy` → `develop` → `main`, all in
  sync with `origin`, CI green on all three branches (engine tests, Mac build,
  iOS build, iOS UI tests) as of 2026-09-08.
- **Nothing is tagged, nothing is released.** `scripts/release.sh 0.5.0` is
  written and tested as far as it can go; blocked on the same Developer ID
  Application certificate ($99/yr Apple Developer Program) noted in Thread 5's
  Privacy Guides audit (D3) and in `docs/RESUMING.md`.
- **The pending real-mailbox sweep has still never been run.** `docs/RESUMING.md`
  (written 2026-09-07) documented a plan for 85 messages / 6 senders. Re-opened
  live on 2026-09-22, the same plan now shows **161 messages / 6 senders**
  (Notifications 118, Promotions 41, Newsletters 2) — mail volume grew in the
  15 days between. Indexing/reading remain read-only by construction; nothing
  in the real Gmail account (keetchcode@gmail.com) has ever been modified by
  the app. Sender-level snapshot at the time of this check, for reference when
  someone next opens the tab (percentages will already be stale — the point is
  the shape, not the exact numbers): GitHub notifications 87 msgs/96% unread,
  Instagram 31/90%, Reddit 36/82%, Perplexity 3/100%, AppScreens 2/75%, GitHub
  Education 2/100%.
- **A stale local branch is waiting on cleanup.** `feature/cleanup-policy` is
  fully merged into `develop` → `main` (verified: zero commits ahead of either)
  and `docs/RESUMING.md` already calls it "safe to delete once you are happy."
  Not yet deleted as of this check — small, low-risk housekeeping item.

### Finding: an unattributed feature appeared mid-session

A new opt-in cloud sender-categorizer surfaced as uncommitted working-tree
changes with no attached authorship: `Security/JevKeyStore.swift`,
`Services/JevCategorizer.swift`, `Services/JevSettings.swift`, plus edits to
`PRIVACY.md`, `THREAT-MODEL.md`, `DECISIONS.md` (new ADR-0023), `ROADMAP.md`,
`AppState.swift`, `SettingsView.swift`, `LocalModel.swift`, `SyncEngine.swift`.
This is the same feature Thread 1 documents in detail ("New in progress").
It's carefully written — opt-in, off-by-default, own Keychain namespace, explicit
untrusted-input framing against prompt injection, sender address + subject
lines only, never a body — but it was **not reviewed or committed**, because it
sends real mail metadata to a third-party API (`api.typesafe.ai`) and touches
privacy documentation, which this project's own conventions (and the owner's
global instructions) require stopping to confirm before landing.

### Finding: this is not one session's work — it's several, concurrently

Five separate Claude Code processes were found running in this same repo
directory simultaneously, all in `bypassPermissions` mode. That's the actual
source of the Jev feature above, and confirmed live: a peer session
(`grokbox-a7`) reached out mid-task, independently doing the same "merge the
research threads into GROKBOX-UPGRADE.md" job this thread was asked to do —
its findings are the feature-comparison material; this thread's own contribution
is the operational/status material now in front of you. **Worth knowing if
you're not intentionally running a multi-session fleet against this repo:**
uncoordinated concurrent writers to the same working tree can produce exactly
this kind of unattributed, unreviewed change.

### Finding: app-identity confusion blocked driving the real Sweep UI

Attempting to bring the real `Grokbox.app` (mail triage) forward to press
"Archive" on the live sweep, both by process name and by bundle id
(`com.wesleykeetch.grokbox`), instead surfaced two unrelated apps on the same
Mac — a bot-scheduling tool and a multi-project coding-chat interface — despite
the real process (confirmed alive by PID) being the one targeted. This looks
like a Launch Services / bundle-ID collision rather than a bug in Grokbox
itself, but it meant the sweep **could not be safely verified and was not
run** — clicking blind on a real Gmail-connected app wasn't worth the risk.
Needs a human to bring the real window forward directly (Dock click or
Cmd+Tab) before anyone automates that button.

### Decisions still waiting on the owner

1. Approve the now-161-message sweep, or don't.
2. Review and decide on the Jev cloud-categorizer feature (keep/commit,
   change, or discard) — see Thread 1 for the full technical writeup.
3. Pay for the Apple Developer Program ($99/yr) to unblock signed releases.
4. Decide whether running multiple concurrent Claude sessions against this
   repo unsupervised is intentional — and if so, consider a lighter-weight
   coordination convention than discovering it via a stray peer message.

---

## Consolidated open questions for whoever picks this up

Combining all six threads' framing:

1. **Direction — largely answered already.** Thread 1 framed this as the open
   question; Threads 3 and 4 each independently re-derived the same
   triage-tool framing, and the user picked **"stay in-lane"** for both
   (Mailspring's option 1, DejaLu's scoped 5-item plan) rather than reversing
   any ADR. Nothing currently on record argues for the full-client direction.
   Treat "stay a triage tool" as decided unless the owner says otherwise, and
   route new proposals through the same "no ADR conflict" filter Thread 1 set up.
2. **Two approved, ready-to-build plans are sitting here unbuilt.** Thread 3's
   five features (notifications → contacts → search → reader → folder picker,
   in that order) and Thread 4's five items (PRIVACY.md fixes, biometric lock,
   header search, a Shortcuts intent) both have the user's sign-off and file-level
   detail already worked out. These are likely the actual next coding work,
   ahead of anything else in this file.
3. **Trust the current audits or re-verify?** Thread 5 is 16+ days stale
   against a fast-moving `main`, and contains at least one unresolved
   self-contradiction (the IMAP timeout fix — see Thread 5's callout). A fresh,
   smaller audit pass against current `main` may be worth more than reading the
   old one closely.
4. **Real-server verification** — still the single largest risk named
   independently by Thread 5 and Thread 6. The pending 161-message sweep
   (Thread 6) is the concrete next step, waiting on the owner's approval.
5. **Small doc/code correctness fixes surfaced in passing, not yet applied:**
   Thread 4's two `PRIVACY.md` gaps (missing autoconfig row, broken
   verification grep, missing tracking-pixel note) and its `LinkHygiene.swift`
   dead-code finding; Thread 2's two grammar fixes in `SweepGuard.swift`
   (lines 76/78). None are blocked on the direction question above.

## Thread 7 — Thunderbird study for a full, private, good-looking client (2026-09-23)

The owner asked what Grokbox can learn from Thunderbird (github.com/thunderbird)
to become "a fully functional but good looking and privacy adherent mail app."
That wording goes past the "stay a triage tool" direction recorded under
Consolidated open questions, item 1. Nothing below is approved; it is research
and a proposed order of work.

`docs/LANDSCAPE.md` (6 September) already covered Thunderbird's autoconfig
ladder, OAuth client IDs in source, filter actions, and junk learning, from the
triage angle. This pass read three more things: comm-central `master` (via the
`mozilla/releases-comm-central` mirror), `thunderbird/thunderbird-ios` at
`8fc45db` (22 September), and `thunderbird/thunderbird-android` at HEAD
(23 September). It also mapped what Grokbox's code does today.

### Where Grokbox stands against a full client (from the code, 23 September)

- No send path at all: no SMTP, no APPEND, no drafts (`SenderMessagesSheet.swift:172`).
- The reader shows the first 8 KB of `BODY.PEEK[TEXT]`, cut to 3,000
  characters, as plain text (`IMAPClient.swift:290-296`, `BodyExtractor.swift:10`).
  Body charsets are always decoded as UTF-8 (`BodyExtractor.swift:11,70,92`),
  multipart handling takes the first boundary line only, and attachments are
  never listed.
- Only INBOX, or All Mail on Gmail, is indexed (`SyncEngine.swift:155-160`).
  There is no folder tree and no chronological message list. Threads are
  sender plus normalized subject (`ThreadKey.swift`), not References or
  In-Reply-To, which are never fetched.
- Per-message actions are archive ("Done") and a local-only snooze. Read or
  unread, flag, move, trash and junk exist only inside bulk sweeps.
- IMAP has no STARTTLS, IDLE, CONDSTORE/QRESYNC, SEARCH, ID, APPEND or
  XOAUTH2. The timer loop is off by default, and iOS has no background refresh.
- `LinkHygiene` is dead code: only a test references it
  (`AutoconfigTests.swift:144`). PRIVACY.md and LANDSCAPE.md both say its
  warnings appear on the Brief row.
- The app lock runs once per launch; `isUnlocked` is never reset on
  background (`AppState.swift:50`).
- No design tokens. Both asset catalogs hold only the app icon; styling is
  system semantic colors plus inline literals (corner radius 8 and 10, font
  sizes 12, 44, 52).
- About 17 accessibility labels and 7 identifiers on macOS;
  `MessageReaderSheet`, `ActivityView` and `SettingsView` have none.

### What Thunderbird desktop teaches

Privacy defaults worth copying, with Thunderbird's own values:

- Remote content off (`mailnews.message_display.disable_remote_image` = true)
  with a precedence order: per-message override, then admin trusted domains,
  then a per-sender allow, then per-site allow or block, and a block wins even
  over a global allow (`nsMsgContentPolicy.cpp`). The bar offers "show for this
  message", "allow from this sender", "allow from this site".
- JavaScript off in message views, iframes fully sandboxed.
- A "simple HTML" sanitized mode, forced for junk
  (`mail.spam.display.sanitize` = true).
- Phishing detector (`PhishingDetector.sys.mjs`) is about 100 lines: compare the
  base domain (Public Suffix List) of link text and href, check obfuscated IP
  hosts only after a mismatch, warn on any `form[action]`, skip Sent and Drafts.
- MDN read receipts: never auto-send; the "ask me" defaults show why.

Places where Grokbox can beat Thunderbird's defaults when it sends mail:

- Thunderbird sends a User-Agent (`mailnews.headers.sendUserAgent` = true).
- It leaks the local time zone; `mail.sanitize_date_header` (UTC, rounded to
  the minute) is off by default.
- Its SMTP EHLO sends the LAN IP as a literal unless `hello_argument` is set
  (`SmtpClient.sys.mjs`).
- It sends IMAP `ID` with app name and version by default.
- Telemetry is opt-out, and account setup queries Mozilla's ISPDB.
- Message-ID is done right: `<UUID@domain-of-From>`, never the machine host
  (`nsMsgCompUtils.cpp`). Copy that.

Sync and storage, where Thunderbird is paying off early decisions:

- `use_condstore` ships false "in case client or server has bugs", and there
  is no QRESYNC code at all. IDLE and COMPRESS are on.
- Mork keeps one `.msf` index per folder, read wholly into RAM, and it became
  the source of truth instead of a cache. Mbox storage needs compaction, which
  was rewritten in 2024 after corruption reports. Gloda search is a second
  database their own docs call slow.
- Panorama, the replacement, is one global SQLite database:
  `folders`, `messages(id, folderId, threadId, threadParent, messageId, date,
  sender, recipients, ..., flags, tags)`, key/value property tables, and live
  query views in place of stored folder views. It is still nightly-only.
  A new client can start where they are heading: one database, one file per
  message body, full-text search in the same store, QRESYNC with a per-account
  off switch.

Design:

- Supernova (115) added Cards view, density (compact / normal / touch), font
  size in the app menu, and optional folder-pane modes. Cards is now the
  default (`mail.threadpane.listview` = 0, 3 rows per card).
- Users complained that Cards showed 17 rows where Table showed 37. Lesson: a
  dense mode from day one; never take the table away.
- Their designers counted 27 interaction states for one message-list row
  (hover, selection, focus, unread, across themes). Worth listing Grokbox's
  row states before styling rows.
- 128 added per-account colours and followed the system accent colour.
- Their 2025 accessibility study found shortcuts that did not follow platform
  norms, no screen-reader confirmation after a move, and confusing search.
  For Grokbox: Mail.app's shortcuts, native `Table`/`List` semantics,
  VoiceOver announcements after archive and move.

### What the Thunderbird mobile repos teach

thunderbird-ios is SwiftUI, Swift 6, iOS 18, and not usable yet ("Not yet
functional or ready for production use"; IMAP landed June 2026, target end of
2026). IMAP and SMTP sit on `apple/swift-nio-imap` and swift-nio, all pinned to
`branch: main`. Its `MIME` (about 1,265 lines), `EmailAddress` and `JMAP`
(about 1,926 lines) modules use Foundation only. OAuth2 uses PKCE S256 through
`webAuthenticationSession`, with a provider table matched on MX host.

Its HTML reader is not a model to copy: remote images and tracking pixels load.
It sets `allowsContentJavaScript = false`, but has no content rule list, no
sanitizer, no CSP, and a persistent data store. Remote feature flags are
fetched from GitHub Pages by default (`FeatureFlags.swift:25`).

thunderbird-android (K-9 lineage) is the mature reference:

- Remote images: `ShowPictures { NEVER, ALWAYS, ONLY_FROM_CONTACTS }`, default
  NEVER, enforced by blocking all network loads in the web view, not by the
  sanitizer. The sanitizer (jsoup `Safelist.relaxed()` plus mail tags) allows
  remote `src`; the network block also catches CSS `url()`.
- `cid:` images served from local parts with `Cache-Control: no-store`.
- Push (RFC 0005): IDLE on the inbox only by default, re-IDLE before RFC
  2177's 29 minutes, a folder cap, polling fallback. All-folder push was
  rejected because of server connection limits.
- Unified inbox is a saved search over a per-folder "include" flag, not a
  merged store.
- Autoconfig runs every source in parallel, highest priority wins, and marks
  each result `isTrusted` only if every hop was valid HTTPS or DNSSEC.
- Telemetry code exists but every build wires the no-op.
- `@PiiSafe` compiler plugin keeps personal data out of `toString()` and logs.
- Storage is moving to one global database (RFC 0007).

Licences: thunderbird-ios and the ISPDB are MPL-2.0, which allows copying into a
GPL-3.0 project if the copied files keep their MPL headers. thunderbird-android
is Apache-2.0, also one-way compatible with GPL-3.0 (keep notices and
`NOTICE`). The constraint is Grokbox's own "no third-party code" claim, not the
licences. Vendoring even Foundation-only MIME code would change that sentence
in the README and PRIVACY.md, so it needs a decision; porting ideas does not.

### A hardened HTML reader for Grokbox, built only from system APIs

Combines Thunderbird desktop's policy and Android's enforcement:

- `WKWebViewConfiguration`: `allowsContentJavaScript = false`, no user scripts,
  `WKWebsiteDataStore.nonPersistent()`.
- A `WKContentRuleList` that blocks every http(s) load by default. Lifting it
  for one message or one sender is the "load remote content" action.
- A `WKURLSchemeHandler` for `cid:` that serves parts from memory.
- An injected CSP (`default-src 'none'; img-src cid: data:; style-src
  'unsafe-inline'`); a sender's own CSP can only tighten it.
- Strip `meta http-equiv=refresh`, forms and scripts before loading.
- `decidePolicyFor` cancels every navigation; links open in the browser after
  a phishing check (the ported detector, reusing `LinkHygiene`).
- Junk and unknown senders always get the sanitized simple view.

This reverses PRIVACY.md's "Render HTML: never." Rendering with every network
load blocked keeps the tracking-pixel claim true, but the sentence and the
threat model change.

### Proposed order, if the owner chooses the full-client direction

Each phase names the ADR or doc it would reverse. None is approved.

0. **Live proof first.** The first real-mail sweep has still never run
   (RESUMING.md). A bigger client multiplies the untested IMAP surface.
1. **In-lane fixes, no ADR conflict:** wire `LinkHygiene` into the Brief and
   reader and add the Thunderbird checks (base-domain compare, form action);
   decode body charsets; parse multipart properly; re-lock on background;
   STARTTLS; IDLE on the inbox only; CONDSTORE/QRESYNC behind a per-account
   switch; add the `.well-known` and MX steps to autoconfig; bundle an ISPDB
   snapshot so the domain never leaves the Mac; accessibility batch C.
2. **Full reader** (reverses "headers only" in ROADMAP "Not planned" and
   PRIVACY.md "Render HTML"): real MIME tree via `BODYSTRUCTURE`, the hardened
   web view above, remote content off with per-sender and per-message allow,
   attachment list and save.
3. **Mailbox browsing** (no ADR conflict, but new screens): folder tree from
   `LIST` with SPECIAL-USE, chronological list with a dense and a card
   density, real threading from References and In-Reply-To, per-message read,
   flag, move, junk and trash (trash is allowed by ADR-0019).
4. **Local store for bodies** (persistence change; PRIVACY.md "never stored"):
   bodies cached as files, a full-text index in the same store, encryption at
   rest decided up front. Thunderbird's Panorama schema is a useful starting
   point.
5. **Compose and send** (reverses ROADMAP "Sending mail. Out of scope." and
   README "No SMTP"): SMTP over implicit TLS or STARTTLS, APPEND to Drafts and
   Sent, and private headers by default: no User-Agent, UTC date rounded to
   the minute, Message-ID from the From domain, a fixed EHLO literal, never an
   automatic read receipt.
6. **OAuth2 for Gmail and Outlook** (ADR-0002; auth): PKCE through
   `ASWebAuthenticationSession`, XOAUTH2 over IMAP and SMTP, Grokbox's own
   client IDs and Google verification. Reusing Thunderbird's IDs breaks
   provider terms.
7. **Design system** (owner directs visuals): semantic colour tokens with
   soft/default/hover/pressed steps (the idea behind thunderbird-ios
   `BoltUI`), a Dynamic Type scale, per-account colours, a listed set of row
   states. Needs two or three named directions with comps before any code.

Not recommended: OpenPGP (large, and RNP or GnuPG would be a dependency);
S/MIME through Security.framework is the realistic later option. CardDAV and
CalDAV: Contacts.framework and EventKit already cover the Mac.

### Owner's decision (23 September 2026)

Stay a triage tool. Build the in-lane fixes only; no ADR is reversed. Built the
same day (uncommitted at the time of writing, listed under Unreleased in
CHANGELOG.md): re-lock on background, phishing checks in the reader, MIME and
charset decoding, accessibility batch C (GB-006, 035, 036, 037, 040, 041, 091),
STARTTLS, and inbox push via IDLE. Not built from phase 1: CONDSTORE/QRESYNC,
the autoconfig `.well-known` and MX steps, and a bundled ISPDB snapshot.

### Sources

- comm-central: `mailnews/mailnews.js`, `mail/app/profile/all-thunderbird.js`,
  `mail/app/StaticPrefList.yaml`, `mailnews/base/src/nsMsgContentPolicy.cpp`,
  `mail/modules/PhishingDetector.sys.mjs`, `mailnews/compose/src/SmtpClient.sys.mjs`,
  `mailnews/compose/src/nsMsgCompUtils.cpp`, `mailnews/imap/src/nsImapProtocol.cpp`,
  `mailnews/db/panorama/src/DatabaseCore.cpp` (github.com/mozilla/releases-comm-central, master, 2026-09-23)
- source-docs.thunderbird.net: message_database, folder_storage, panorama
- blog.thunderbird.net: Supernova (2023-07), folder pane preview (2023-02),
  128 Nebula (2024-07), April 2024 digest, accessibility study (2025-09),
  conversation view (2025-10), 2025 review, mobile progress report (2026-07)
- roadmaps.thunderbird.net (desktop and iOS, updated 2026-07-23)
- github.com/thunderbird/thunderbird-ios (`Core/`, `Bolt/`, `Documentation.docc/`,
  `FeatureFlags.swift`, `EmailBodyView.swift`), github.com/thunderbird/swift-rich-html-editor
- github.com/thunderbird/thunderbird-android (`docs/architecture/`, `docs/engineering/adr/`,
  `docs/engineering/rfcs/` 0005 and 0007, `feature/autodiscovery/`, `library/html-cleaner/`,
  `library/pii-safe/`, `MessageWebView.kt`, `ShowPictures.kt`)
- Mozilla Connect Cards-view thread and support.mozilla.org pages were read via
  search excerpts only (direct fetch returned 403)

---

<!-- Next research thread: append a new "## Thread N — <angle> (<date>)" section above this line. -->
