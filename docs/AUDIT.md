# Audit — 2026-09-05

What was tested, how, what broke, what was fixed, and what is still open.

## How the app was exercised

The owner declined desktop-automation access, so this audit did not click
through the UI. It used three layers instead, which together cover more than
clicking would have:

1. **Engine tests** (`GrokboxCore/Tests`, 45 tests, ~17 s). Includes an IMAP
   server on loopback that the real client talks to, and `DemoFlowTests`,
   which runs index → assess → plan → apply → undo → incremental sync →
   maintenance through the exact engines the buttons call. One test reads demo
   mail with Apple's real on-device model when the Mac supports it.
2. **Full in-app runs** via launch flags (`--reset --demo --run-all
   --demo-sweep`) against three generated mailboxes — Personal (~1,100
   messages), Work (~1,600), and a neglected Old Gmail (~2,300) — verified by
   reading the app's own SwiftData store with `sqlite3`.
3. **Screenshots** of every section via `screencapture` once the screen was
   available.

Nothing here touched a real mail server. That remains the single largest
unverified surface — see *Open* below.

## What the in-app runs showed

| | Personal | Work | Old Gmail |
|---|---|---|---|
| Indexed | 1,088 | 1,573 | 2,289 |
| In inbox before sweep | 930 | 1,339 | 1,931 |
| Swept by the suggested plan | 818 | 1,065 | 1,817 |
| Left in inbox | 113 | 306 | 114 |
| Read by Apple's model | 15 | 15 | 10 |
| …of which "needs you" / "worth knowing" | 8 / 5 | 12 / 3 | 6 / 4 |
| Sweep actions / errors | 42 / 0 | 57 / 0 | 33 / 0 |

Every action was undoable. 19 sender rules were written. Reading ran at
roughly 2–3 seconds per message on-device. A full tidy-up of all three
accounts, including reading, took about six minutes; subsequent tidy-ups are
incremental and take seconds.

## Bugs found and fixed during the audit

Ordered by how bad they would have been in the wild.

| # | Severity | Bug | Found by |
|---|---|---|---|
| 1 | **Would corrupt data** | No UIDVALIDITY check. If a server renumbers a mailbox, stored UIDs point at the wrong messages and a sweep archives the wrong mail. Now: snapshot per mailbox; `PlanExecutor` refuses to write on mismatch. | design review |
| 2 | **Would hang** | No connect or read timeouts. Now: 20 s connect, 90 s read, fail-fast on no route. **This entry was wrong when written** — the deadlines existed but could never fire (see the P1 below); they were only made real on 6 Sep. | design review |
| 3 | **Blocked the whole app** | Header folding never split `\r\n` — Swift treats CRLF as one `Character`. Every subject, sender, and unsubscribe header was wrong. | first fake-server test run |
| 4 | **Sandbox** | The in-process demo tried to open a listening socket; the sandbox (correctly) refused. Moved the demo to a socket-free `MailProvider`. The shipped app has no listener and no `network.server` entitlement. | first in-app run |
| 5 | **Silent failure** | Keychain writes used `try?`; a sandbox refusal would have produced an account that could never sign in. Now: writes are verified by reading back, and errors surface in Add Account. | first in-app run |
| 6 | **Misleading counts** | Gmail messages already archived were counted as sweep candidates. Now: `X-GM-LABELS` is fetched and `\Inbox` membership drives the counts. | design review |
| 7 | Auth bypass (demo only) | Demo LOGIN matched the password as a substring of the line — the username contained it. | test |
| 8 | Model quality | Over-called "needs you" (13 of 15). Prompt rewritten with examples and a stricter definition; now ~6 of 15 on the personal inbox. | in-app run |
| 9 | Model quality | Enum names and schema words leaked into summaries ("… Must review. NeedsYou"). Sanitizer added; prompt forbids labels. | in-app run |
| 10 | Model quality | Summaries said "Someone asks…". Prompt now requires the sender's name. | in-app run |
| 11 | Parser | Bare mailbox names in `LIST` responses (`INBOX` unquoted) parsed as `/`. | test |
| 12 | Parser | Multipart bodies: same CRLF bug as #3. | test |
| 13 | Compile | An app-level `enum Section` shadowed SwiftUI's `Section`. | build |

## Features added because the audit needed them

- Three demo mailboxes with distinct personalities (in-process, no network)
- Connection test before an account is saved; Gmail App Password spaces
  stripped; duplicate accounts refused; friendlier auth errors
- Incremental sync (UID watermark + flags refresh) so tidy-ups are fast
- Sender drill-down (the messages behind a row) from Senders and Sweep
- Sortable Senders table; Inbox column; All / None in Sweep
- Cross-account Brief
- Rules list and removal in Settings; erase-everything with confirmation
- Local notification after a timed tidy-up finds something (opt-in)
- Proton Bridge over TLS with its self-signed loopback certificate
- Launch flags for scripted states

## Open

### Must do before real use
- **Run against a real Gmail account.** Every IMAP path is verified against a
  Gmail-shaped fake and the demo. Real servers fold headers differently, send
  `LIST` shapes the fixture does not, and have 40,000-message mailboxes.

### Fixed after the audit: performance at 40k messages
Two problems, both measured with a 40,000-message / 400-sender fixture
(`ProfileTests.fortyThousandMessagesRebuildQuickly`):

1. Views loaded every `MessageHeader` and re-clustered per render. Now the
   engine builds one `SenderProfile` row per sender after each index — a
   single pass, fetching only the columns it needs — and views query those.
   **Rebuild: 1.4 s. UI query: 0.04 s.**
2. `MessageHeader.account` was a relationship with a to-many inverse; every
   insert touched the account's growing array. Inserting 40k took **365 s**.
   Replaced with an indexed `accountID` column (cascade done by hand in
   `AppState.remove`): **5 s.** Account-scoped predicates are now column
   matches, not joins.

The Brief also moved off "load then filter" onto an indexed `briefRank`
column and `fetchCount`, so it never loads more than the classified rows.

### Should do
- **Old-but-important mail never surfaces.** The reader only considers the
  last 30 days. A one-time "catch-up" read over older unread mail from
  contacts would matter for an inbox that has been ignored for a year.
- **Categories.** Everything swept gets one label. Newsletters / Notifications
  / Promotions would make the archive navigable.
- **Menu bar presence** so tidy-up runs without the window open.
- **STARTTLS** for Proton Bridge's default mode.
- **XCUITest smoke suite** driving the demo flow through the real UI, for CI.
- **Accessibility pass.** Identifiers exist on a handful of controls; VoiceOver
  labels and Dynamic Type have not been audited.
- **Model choice per account.** Ollama users may want a bigger model for work
  mail and a faster one for personal.

### Design
- The UI is deliberately unstyled. The owner directs the design pass.

## Addendum — prioritisation and meaningful organising (same day)

Added after the owner asked for a mindful prioritisation process and for
cleaning that "makes sense and is not AI slop". See ADR-0011 … ADR-0014.

- **Structured signals from the model**: action type, verbatim due phrase,
  "quick". Parsed by `DueDateParser` (16 tests; refuses to guess).
- **`PriorityScorer`**: explainable score; every Brief row shows "Why here".
- **Bounded Brief**: Now (3) · Quick wins · Then · Worth knowing (collapsed);
  **Later** snoozes a row to a chosen time.
- **Categories → folders**: Promotions / Newsletters / Notifications /
  Receipts / People / Unsorted. Deterministic with evidence; model for the
  unsorted remainder (capped, marked with ✦ in the table).
- **Recommendations**: one of five plain answers per sender, with the numbers.
- **Sweep guard**: message-level hold for flagged / needs-you / transactional.
  The lifecycle test now asserts the guard held at least one receipt-looking
  message inside a bulk sender, and the inbox shrank by plan-minus-held.

Bug found while building: the categoriser ranked "newsletter" above
"notification", so a task tracker's "Weekly digest: 14 updates" put it in
Newsletters. Fixed: the strongest signal wins.

### Later the same day: "Where things stand"
A refreshable, dated inbox summary at the top of the Brief (ADR-0015). Built
from the store, never from the model, so Refresh is instant. Verified by
`DigestTests`: reflects sweeps, keeps history, orders items by priority.
Second-round categoriser fixes: a `no-reply@` address alone no longer makes a
notification (Streamflix's receipts), soft-sell vocabulary ("3 months free",
"upgrade") is promotion, and unsubscribe-only fallbacks are offered to the
model. Read budget default lowered to 25: structured output costs ~10 s per
message on-device.

### Catch-up, menu bar, and digest fixes
- `SyncEngine.ReadScope.catchUp(days:)` reads older unread mail from People
  and Receipts senders (or flagged) only; `CatchUpTests` pins both the sender
  restriction and that it reaches past the 30-day window.
- `MenuBarExtra` scene with the latest cross-account digest and Tidy up now.
  `AppState` is now owned by the App and shared with both scenes.
- Digest defects found in the in-app run: it was written before the sweep
  finished (now refreshes on executor completion too) and repeated one thread
  three times (now one line per sender+subject; tested).
- Test infrastructure: loopback listeners in parallel suites occasionally hit
  EADDRINUSE; the fake server now binds 127.0.0.1 explicitly and the client
  helper retries once. Not a product bug.

## Verification round — 86 tests

Added to close the gaps the earlier audit listed as unexercised:

| Path | How it is now verified |
|---|---|
| **TLS to a real IMAP server** | `RealServerTLSTests.gmailGreetsOverTLS`: connects to `imap.gmail.com:993`, reads the greeting, runs pre-login `CAPABILITY`, parses it, logs out. No credentials. Skips silently when offline. |
| **One-click unsubscribe POST** | `UnsubscribeHTTPTests` against a loopback HTTP server: method, path, `Content-Type`, exact RFC 8058 body, no cookies; non-2xx falls back to the browser; plain `http://` is never POSTed to. |
| **Ollama backend** | `OllamaProviderTests` against a loopback fake: `/api/tags` availability, the missing-model message, remote hosts refused, and the full `/api/generate` JSON contract including the new action/due/quick fields. |
| **Snooze** | `SnoozeTests`: a snoozed message leaves the Brief and the digest until its time and returns after. |
| **Catch-up** | `CatchUpTests`: reads only People/Receipts senders and reaches past the 30-day window. |
| **Digest** | `DigestTests`: reflects sweeps, orders by priority, no repeated threads, keeps history. |
| **In-app, inside the sandbox** | `--selftest` launch flag: Keychain save→read→delete round trip and a TLS connection to Gmail from the sandboxed process; `--demo-undo` and `--catch-up` exercise undo and catch-up through the app. |

Process lesson recorded: rebuilding the `.app` while a scripted run is in
progress corrupts that run (the running process keeps the old binary but
loses its resources). Runs and builds are now strictly sequential.

Test-infrastructure bugs fixed along the way, none in the product: parallel
loopback listeners occasionally collided on a port (bind loopback explicitly,
retry connect once); the fake HTTP recorder split headers on `"\n"` and
so never saw `Content-Length` — the same CRLF-is-one-Character trap the
product hit on day one.

### Comprehensive in-app run (all flags, one clean build)

`--reset --demo --run-all --demo-sweep --demo-undo --catch-up --selftest`,
three demo accounts, verified from the store. Four minutes end to end.

| Step | Evidence |
|---|---|
| Index + read + categorise | 3 accounts synced and read; 85 messages summarised |
| Sweep by category folder | 3,742 filed; 3 held by the guard (Streamflix receipts); pending bulk senders 47 → 3 |
| Digest refresh | new snapshot after sweep, after undo, and after catch-up |
| Undo | 3 archive actions undone; inbox membership restored (Swift Weekly 26 of 31 — the rest were held or already out) |
| Catch-up | 17 older messages read: 4 from people, 13 transactional, none bulk |
| Self-test in the sandbox | Keychain save→read→delete OK; TLS to `imap.gmail.com` OK, 15 capabilities, IMAP4rev1 |
| Digest top items | distinct threads, priority-ordered, each with its reasons |

Startup no longer depends on a window appearing (`AppState.startIfNeeded`
runs from the App), so headless and menu-bar-only use both work. App
milestones now go through `os.Logger` (subsystem `com.wesleykeetch.grokbox`)
*and* a plain file in the app container, `Library/Logs/grokbox.log`. The
file exists because `log show` turned out to be unreliable from a scripted
shell on this machine (it returned nothing at all for a stretch); a file the
app owns is the dependable channel for scripted runs and for bug reports.

Still unverified: the screens themselves, pending an unlocked display, and a
live non-demo account.

### Regression found by verification: main window did not open

After the menu-bar refactor the main window stopped appearing at launch —
nothing crashed, the menu-bar item was there, and every scripted run silently
did nothing. Caught because the file log had no "root view appeared" line.
Bisected by rebuilding without the MenuBarExtra (still missing), wiping saved
state (still missing), reverting the whole App shape (opens), then re-adding
pieces one at a time: the cause is `WindowGroup(id:)`; the custom `init`
blamed at first was innocent. See ADR-0016, corrected. This is exactly the class
of bug that a locked screen hides and a test suite cannot see; the file log is
now the first thing a scripted run checks.

## P1 fixes — 6 September 2026

The three release blockers from the audit are closed. Each has a regression test
that was checked to fail against the old code.

### 1. IMAP deadlines could never fire  *(was P1)*

`withTimeout` raced a sleeper against a `withCheckedThrowingContinuation` parked
on an `NWConnection` callback, inside a throwing task group. A task group awaits
**every** child before it propagates, so the deadline won the race and then
waited forever for the loser. Any server that accepted TCP and went silent
wedged the engine for the rest of the session, and because every entry point is
guarded by `!phase.isRunning`, all mail work stopped with it.

Fixed by making the deadline tear the socket down before it throws — cancelling
the connection fires the pending completion handler, which resumes the parked
continuation, which lets the group unwind. Reads and writes are additionally
wrapped in `withTaskCancellationHandler` so external cancellation works, and the
TCP options now set `connectionTimeout` and keepalive as an OS-level backstop.

`PlanExecutor` and `Maintainer` gained the `cancel()` they never had, and
`SyncEngine.indexNow`/`readNow` now register their task so Stop can reach them —
previously `cancel()` was a no-op on exactly the paths a user would want to stop.

Evidence: `IMAPDeadlineTests`. Before, a 3-second deadline had not fired after
12 s (`audit/evidence/imap-timeout-repro.txt`). Now it fires in 2.1 s, and a
parked read is freed by `disconnect()` in 0.4 s.

### 2. Undo could act on a renumbered mailbox  *(was P1)*

The guard compared the server's UIDVALIDITY against `MailboxSnapshot` — but an
index pass overwrites that snapshot with whatever the server currently reports.
After a renumber followed by an index, the snapshot agreed with the server, the
guard passed, and Undo pushed stale UIDs at whatever messages now held those
numbers.

Fixed by stamping the validity onto the `CleanupAction` when it runs and
comparing *that* against the live value. Actions written before the stamp
existed (`uidValidity == 0`) fall back to the old snapshot check, which is no
weaker than before.

Evidence: `UndoSafetyTests.undoRefusesAfterTheMailboxIsRenumbered`, verified to
fail against the previous guard.

### 3. No schema versioning; container failure was fatal  *(was P1/P2)*

Eight `@Model` types were handed to `ModelContainer` as a bare list, and any
open failure was a `fatalError` — turning a recoverable problem into an app that
could not launch and therefore could not be reset from inside itself.

Now `GrokboxSchemaV1: VersionedSchema` plus `GrokboxMigrationPlan`, opened
through `GrokboxStore.open()`, which tries the store, then moves an unreadable
store aside (keeping it) and starts fresh, then falls back to memory-only. Any
recovery is surfaced as a banner rather than swallowed.

Verified in place: the existing 141-action store migrated to the versioned
schema with no recovery triggered and `ZUIDVALIDITY` added to `ZCLEANUPACTION`.

Suite after these changes: **109 tests in 30 suites, all passing.**
