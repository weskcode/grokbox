# Decisions

Short records of choices that were not obvious, and would otherwise get quietly
reversed by someone who did not know why.

---

## ADR-0001 — Native SwiftUI, not Electron

**Status:** accepted

Electron was the alternative. It is rejected because the entire value
proposition of Grokbox is "this is private," and a typical Electron app carries
several hundred transitive npm packages, every one of which would run in a
process with read access to the user's complete mail archive. That is not a
theoretical concern; it is the most actively exploited supply chain in software.

Native also gets Keychain, Network.framework TLS, and Apple's on-device
Foundation Models for free, and produces a ~5MB app instead of a ~150MB one.

**Cost accepted:** macOS only, and no off-the-shelf Swift IMAP library, so the
IMAP client is hand-written.

---

## ADR-0002 — IMAP first, Gmail API later, behind a protocol

**Status:** accepted

The Gmail API is a better backend for Gmail: `history.list` gives true
incremental sync, and `batchModify` relabels 1,000 messages in one call where
IMAP needs a slow walk.

It is not first, because it requires OAuth with **restricted scopes**, and
Google gates those behind app verification plus a paid annual third-party
security assessment. For an open-source tool with no company behind it that is
a genuine blocker, and the usual workaround — "each user creates their own
Google Cloud project" — is a brutal onboarding step.

IMAP with an App Password works today for both Gmail and Proton Bridge, on one
code path, with no gatekeeper.

**Verify before building the Gmail API path:** Google's policy here changes, and
App Password availability has been on and off deprecation watch. Confirm the
current state rather than trusting this document.

---

## ADR-0003 — Read-only until trust is earned

**Status:** accepted

v0.1 cannot modify mail, and this is enforced structurally rather than by
convention:

- Mailboxes are opened with `EXAMINE`, the read-only form of `SELECT`. The
  **server** rejects writes.
- `BODY.PEEK` is used rather than `BODY`, so indexing does not mark messages read.
- There is no `STORE`, `EXPUNGE`, `APPEND`, or `COPY` anywhere in the codebase.

The failure mode that matters for this tool is not "misfiled a newsletter." It
is "silently lost something important and did not find out for six months." An
app that cannot write cannot cause that, and a week of watching it be wrong for
free is worth more than any accuracy number.

When mutation arrives (v0.3) it inherits these rules:

1. **Never delete.** Archive and label only. Everything reversible.
2. **Propose, then apply.** The app produces a plan; the user approves it as a
   batch; only then does anything execute.
3. **Log every action** locally with a working undo.

---

## ADR-0004 — Sender is the unit of decision

**Status:** accepted

Per-message classification is the obvious design and the wrong one — it is
slow, it re-derives the same conclusion hundreds of times, and it presents the
user with a list as unmanageable as the inbox they were trying to escape.

Collapsing to senders turns 40,000 rows into ~600, which is a list a person can
actually read, and matches how the decision is really made.

---

## ADR-0005 — GPL-3.0-or-later

**Status:** accepted, low confidence — revisit

Chosen for consistency with the owner's other open-source project and because
copyleft suits a privacy tool: a closed fork that quietly adds telemetry would
defeat the point.

MIT would get wider adoption and easier contribution. This is a genuine
trade-off and the owner may want to overrule it.

---

## ADR-0006 — Engine as a Swift package, UI as a thin app

**Status:** accepted

Everything that touches mail or runs a model lives in `GrokboxCore`, a plain
Swift package. The app target holds SwiftUI and one `AppState`.

The reason is the test loop. The riskiest code in the project is the IMAP
client, and the only honest way to test it is end to end against a server.
A package can spin up a fake server on loopback and run the real client
against it in under a second with `swift test`; an app target would need a
test host, an entitlement for listening sockets, and a three-minute
`xcodebuild` cycle. The first run of that suite found four real bugs.

---

## ADR-0007 — Rules stick; maintenance never invents

**Status:** accepted

Approving a sender in Sweep writes a `sweep` rule. Tidy-up applies rules and
reads new mail, but **never** sweeps a sender the user has not ruled on — a
bulk verdict alone is not consent. `RuleTests.maintenancePlanOnlyContainsApprovedSenders`
pins this.

For an ADHD user the failure mode is not "the tool did too little", it is
"the tool did something I did not expect and now I do not trust it". One
explicit approval per sender, forever, is the trade.

---

## ADR-0008 — Deployment target macOS 26

**Status:** accepted

Apple's Foundation Models framework is the zero-setup reading path and it
does not exist below macOS 26. Supporting 15 would mean weak-linking, an
availability dance through the model layer, and a worse default experience
for everyone on a current Mac. Machines that cannot run 26 mostly cannot run
Apple Intelligence either, and Ollama works on 26 too.

---

## ADR-0009 — Per-sender rows are persisted, not computed in views

**Status:** accepted

`SenderProfile` is a SwiftData model rebuilt by the engine after every index
and adjusted in place on sweep/undo. Views query it. The alternative — cluster
`MessageHeader` rows inside SwiftUI on every render — is what v0.2 did, and it
does not survive a 40,000-message mailbox.

The cost is a second source of truth that must be kept consistent.
`SenderProfileTests.profilesMatchTheInMemoryClustering` pins the two together,
and the rebuild is idempotent so a stale row is one index away from correct.

---

## ADR-0010 — Messages reference accounts by id, not by relationship

**Status:** accepted

SwiftData relationships with a to-many inverse update the inverse array on
every insert. With 40,000 messages that is quadratic: measured at 365 s to
insert the fixture, versus 5 s with a plain indexed `accountID: UUID` column.

What is given up: automatic cascade delete. `AppState.remove(_:)` deletes an
account's messages, profiles, snapshots, and actions by predicate instead.
That is four lines, and they are tested by the lifecycle test indirectly
(a reset between runs) — worth a dedicated test when the next model lands.

---

## ADR-0011 — Categories are deterministic first, model second, and always explained

**Status:** accepted

Every sender gets a `SenderCategory` (person / receipts & records /
notifications / newsletters / promotions / unsorted). `SenderCategorizer`
decides from headers and subjects and records its evidence in one sentence.
Only senders it cannot place go to the local model, capped at 40 per pass,
and a model-placed category is marked as such in the UI.

The alternative — asking the model about every sender — would be slower,
opaque, and, for the obvious cases, no more accurate than "has an unsubscribe
link and says 50% off". Explainability is the feature: a category the user
cannot see the reason for is one they will not trust the folder of.

Folders follow categories one-to-one. There is no generic "Swept" bin any more.

---

## ADR-0012 — Every sender gets a recommendation with its evidence

**Status:** accepted

`Recommender` turns category + behaviour into one of five answers — get rid
of it, keep but out of the inbox, silence it, leave it, look first — and a
reason built from the numbers ("You have never opened any of 87 messages").
People, flagged senders, and receipt senders are always "keep".

This exists because "bulk / keep / review" is a *verdict*, not advice. The
question a tired reader has is "what do I do about this one?" and the app
should answer it in their words, with the evidence, and stop.

---

## ADR-0013 — Priority is a named sum, and the Brief is bounded

**Status:** accepted

`PriorityScorer` adds importance, deadline proximity, action type, flag,
relationship strength, unanswered age (capped), and quickness — each with a
label, so a row can say "Why here: due tomorrow · money · someone you talk
to often". Due dates come from phrases the model quotes verbatim and
`DueDateParser` refuses to guess: an unparseable hint is no deadline, never
an invented one.

The Brief shows **Now** (at most three), **Quick wins**, **Then**, and
collapses **Worth knowing**. "Later" hides a row until a chosen time. A list
that can be finished gets finished; an unbounded one gets closed.

---

## ADR-0014 — The sweep guard holds messages, not senders

**Status:** accepted

Before archiving, `SweepGuard` checks each message and holds back anything
flagged, anything the model marked as needing you, and — by default, with a
toggle — anything whose subject looks transactional (receipt, order, ticket,
verification code, appointment, …). Held UIDs and a summary are written on
the action, shown in Activity, and counted on the Brief.

Sender verdicts are right most of the time; the mail people regret losing is
the exception inside a bulk sender. The single-message "Done" on the Brief
bypasses the guard because the user chose that message themselves.

---

## ADR-0015 — The inbox summary is computed, not generated

**Status:** accepted

"Where things stand" (Brief, ⌘⇧S) is an `InboxDigest`: a headline, a short
narrative, and the top five items with their reasons — every sentence built
from counts and the priority scorer, no model call. It is stored with a
timestamp; the last thirty per scope are kept as history; Copy puts it on the
clipboard as plain text.

Deterministic was chosen over model-written because the value of this
feature is that pressing it is *instant* and the answer is *trustworthy*.
A 10-second wait for a paragraph that might round the numbers is the wrong
trade for the moment someone opens the app to ask "how bad is it?". The
per-message summaries it quotes were already written by the model.

---

## ADR-0016 — The main window scene carries no id; shared state is a lazy global

**Status:** accepted (corrected)

**What actually broke:** giving the main scene an identifier —
`WindowGroup(id: "main")` — stops SwiftUI on macOS 27 from presenting it at
launch, and so does `Window("Grokbox", id: "main")`. An identified scene is
treated as something to open on demand with `openWindow(id:)`. Reproduced with
and without the `MenuBarExtra`, with `.defaultLaunchBehavior(.presented)`, and
after wiping saved state; removing the id opens the window every time, menu
bar on or off.

Consequence: the menu bar's "Open Grokbox" cannot use `openWindow(id:)`. It
activates the app, fronts an existing main window, and otherwise asks AppKit
to reopen (`applicationShouldHandleReopen`, the Dock-click path) with
File ▸ New Window as a fallback — see `MainWindow.show()`.

**What was wrongly blamed first:** the same refactor also gave `GrokboxApp` a
custom `init` and an App-level `@State`. Reverting both at once fixed the
window, and this record originally credited the `init`. A later bisect showed
the id alone was sufficient. Kept here because the wrong lead cost an hour and
the next person should not repeat it.

**What stays:** the container and `AppState` are `@MainActor` static lets in
`AppEnvironment`, created lazily, attached to both scenes with
`.environment(_:)`. Startup (`AppState.startIfNeeded`) is idempotent and is
kicked from whichever scene appears first, including the menu-bar label, which
is built at launch even when no window is. A `MenuBarExtra` *label* cannot use
`@Environment(AppState.self)` — the lookup runs before the environment is
attached and crashes — so the label reads `AppEnvironment.state` directly.

---

## ADR-0017 — `MenuBarExtra(isInserted:)` must not be bound to `@AppStorage`

**Status:** accepted

`MenuBarExtra` echoes its insertion state back through the `isInserted:` binding
on every scene update. When that binding writes `UserDefaults`, `@AppStorage`
invalidates the App body, the scene is rebuilt, and it echoes again — an
unbounded loop that consumed a full CPU core permanently while the app sat idle,
on every screen, including one whose entire content was a `Text`.

Measured: `.constant(true)` 0.03 cpu-seconds per 8 s; a `@State` binding 0.05;
`@AppStorage` **8.10**. The preference now lives on `AppState` and the App binds
through a `Binding` whose setter drops no-op writes. Either guard alone breaks
the cycle; both are present because the cost of getting this wrong is a battery
complaint nobody can diagnose.

---

## ADR-0018 — A deadline that cannot end the race is not a deadline

**Status:** accepted

Racing an operation against `Task.sleep` inside a throwing task group only works
if the operation is cancellable. `withCheckedThrowingContinuation` around an
`NWConnection` callback is not: the group awaits every child before propagating,
so the sleeper wins and then waits forever.

Every deadline in the IMAP layer therefore **tears the resource down** before it
throws, and every continuation is wrapped in `withTaskCancellationHandler` that
does the same. The rule for anything added later: if a deadline cannot free what
it is racing, it is decoration.

The corollary applies to Stop. `Task.checkCancellation()` between units of work
is only reachable if the current unit returns; when it cannot, cancellation must
disconnect. `SyncEngine`, `PlanExecutor` and `Maintainer` all cancel by
disconnecting, not merely by cancelling a task.

---

## ADR-0019 — "Move to Trash" is allowed; deleting is still not

**Status:** accepted. Amends ADR-0003, which said Grokbox never deletes.

ADR-0003 is right about the thing that matters — an automated tool that
destroys mail is a tool nobody can trust — but it was written as "never
delete", and people legitimately want promotions *gone*, not filed. Refusing
that outright pushes them back to selecting a thousand messages by hand in
Gmail, which is the problem this app exists to solve.

So the rule is now stated where the boundary actually is:

**Grokbox never destroys a message.** It has no code path that sets `\Deleted`
and no code path that issues `EXPUNGE`. It cannot empty a Trash and does not
offer to.

**Grokbox may move a message to the provider's own Trash**, when the user has
chosen that in Settings, per category. That is a `MOVE`, recorded like any
other action, and undoable by moving it back for as long as the provider keeps
it — typically thirty days. The provider deletes it in the end, on their own
schedule, under their own policy, exactly as it would if the user had pressed
Delete themselves.

Three things make this honest rather than a loophole:

1. **It is never the default.** The default policy is Gentle, which files into
   folders and touches nothing recent. Trash must be chosen.
2. **The consequence is written where the choice is made** — `Disposition.warning`
   is shown next to the picker, and the Sweep screen states the policy in full
   before the button is pressed.
3. **A server with no Trash refuses the sweep** rather than archiving and
   calling it deletion (`PlanExecutor` resolves the Trash mailbox before it
   runs anything).

The corresponding line in CONTRIBUTING.md has been amended from "no message is
ever deleted" to the accurate rule: no message is ever destroyed by Grokbox.

---

## ADR-0020 — Cleanup behaviour is a policy the user owns, not a heuristic

**Status:** accepted

Aggressiveness is not a thing software can infer. The same inbox wants
different treatment depending on whether its owner is anxious about losing mail
or drowning in it, and that changes over time.

`CleanupPolicy` therefore holds every such decision in one place — disposition
per category, unsubscribe automation and its conditions, how much recent mail is
protected, how many of each sender's newest messages are kept, which guards are
on — with three named presets (Gentle, Balanced, Thorough) as starting points
rather than a wall of switches.

Two rules keep it from becoming the "shiny dashboard of choices" that Privacy
Guides rightly criticises:

- **Every policy renders itself as a sentence** (`CleanupPolicy.summary`), shown
  above the Sweep button. Nobody has to infer what their settings do.
- **The safe end is the default.** A person who never opens Settings gets
  Gentle: files into folders, keeps the last week and the newest two from every
  sender, never unsubscribes on their behalf.

Automatic unsubscribe is the one irreversible action, so it is gated hardest: a
real RFC 8058 one-click endpoint, a bulk category, a minimum message count, a
minimum unread ratio, and by default no evidence the user ever wrote back. It
runs last, after the sweep succeeded, and is recorded as non-undoable with a
plain sentence saying so.
