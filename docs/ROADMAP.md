# Roadmap

## v0.1 — Index and understand (built)

Read-only. Connect, index headers, learn contacts, show the sender table with
heuristic verdicts and unsubscribe links.

## v0.2 — Act, read, keep clean (built)

- `GrokboxCore` package with a fake IMAP server; 32 tests, `swift test` in seconds
- Plan → review → apply, archive + label only, action log with undo
- Reader pass: Apple on-device model or Ollama; bodies transient, summaries kept
- Brief screen: Needs you / Worth knowing
- Sender rules (always sweep / always keep) so decisions stick
- Tidy-up: index → apply rules → read, on demand or on a timer
- RFC 8058 one-click unsubscribe
- `docs/PRIVACY.md` — the complete outbound inventory

**Not yet verified against a real server.** Every IMAP path is tested against
a Gmail-shaped fake; the first live run will find edge cases the fixture does
not model (odd `LIST` shapes, servers that fold differently, huge mailboxes).

## v0.3 — Harden (built)

- Three in-process demo mailboxes (personal / work / neglected) so the whole
  app can be exercised with nothing real attached
- Incremental sync: UIDVALIDITY + highest-UID watermark; a sweep refuses to
  run if the server renumbered the mailbox
- Gmail inbox membership via `X-GM-LABELS`, so Sweep counts are honest
- Connect and read timeouts; offline fails fast
- Connection tested before an account is saved; App Password spaces stripped;
  duplicates refused
- Per-sender drill-down, sortable Senders table, select-all in Sweep
- Cross-account Brief, rules list, erase-everything, local notifications
- Proton Bridge over TLS with its self-signed loopback certificate
- Launch flags for scripted states and screenshots

## v0.4 — Prioritise and organise meaningfully (built)

- Structured signals from the model (action, due phrase, quick); `DueDateParser`
- `PriorityScorer` with named reasons; bounded Brief (Now / Quick wins / Then);
  Later (snooze)
- Categories → folders (Promotions / Newsletters / Notifications / Receipts /
  People); deterministic with evidence, model for the unsorted remainder
- One plain recommendation per sender with its numbers
- Sweep guard: flagged / needs-you / transactional held at message level
- "Where things stand": instant, dated, copyable inbox digest with history
- Catch-up read over older mail from people and record-keepers
- Menu-bar presence; tidy-up runs with the window closed
- Persisted `SenderProfile` and `accountID` column: 40k messages in seconds

## v0.5 — Next

- **Live run on a real Gmail account.** Everything above is verified against
  the demo mailboxes and a fake server; a real server will find edge cases.
- STARTTLS (Bridge's default mode); today Bridge must be set to SSL mode
- Design pass — the UI is deliberately unstyled; the owner directs that
- XCUITest smoke suite driving the demo flow through the real UI
- Faster reads: the structured schema costs ~10 s/message on-device; try a
  two-step read (summary first, signals only for needs-you)

## v0.6 — Tier 2: embeddings

Cluster near-duplicate senders (`noreply@`, `news@`, `updates@` at the same
company) so decisions apply to a brand rather than an address. Local embedding
model, no network.

## v0.7 — Natural-language rules

"Keep anything about the mortgage, sweep shipping notifications older than 30
days." The local model turns that into a filter that runs in tier 1.

## v0.8 — Gmail API backend

See ADR-0002. Requires resolving the OAuth verification question first. Real
payoff: `history.list` incremental sync and `batchModify`.

## Not planned

- **Sending mail.** Out of scope. Grokbox is a triage tool.
- **Reading message bodies.** Headers answer every question the tool asks.
- **A hosted or sync service.** There is no server, and adding one would end the
  privacy claim.
