# Architecture

## The shape of the problem

The naive design is "run every email through an LLM and ask what to do with it."
This does not work. At 300ms per message, 40,000 messages is over three hours of
a hot laptop, and the model is being asked to re-derive the same conclusion about
the same newsletter 200 times.

Grokbox inverts it. **The unit of decision is the sender, not the message.**
40,000 messages is typically 400–800 senders, and almost every real decision
("do I want mail from this company at all?") is made once per sender.

## Three tiers of analysis

| Tier | Method | Cost | Covers |
|------|--------|------|--------|
| 1 | Header heuristics | milliseconds | the large majority |
| 2 | Local embeddings, sender clustering | seconds | near-duplicate senders |
| 3 | Local LLM over the ambiguous remainder | ~50 calls | the tail, and natural-language rules |

Tier 1 is `Analysis/HeuristicAnalyzer.swift`: no model, no network, no GPU.

Tier 3 is the **reader pass** (`SyncEngine.read`): `ImportanceScorer` picks
the recent, unread, not-obviously-bulk messages — capped — and a `TextModel`
reads each one. Two backends, both local: `FoundationModelsProvider` (Apple's
on-device model, `@Generable` structured output) and `OllamaProvider`
(loopback HTTP, JSON mode). Bodies are fetched with `BODY.PEEK[TEXT]<0.8000>`,
reduced to text by `BodyExtractor`, handed to the model, and dropped.

Tier 2 (embeddings) is not built.

The signals tier 1 uses, in rough order of strength:

1. **Have you ever written to this address?** Learned by scanning your Sent
   mailbox. This is the strongest signal in an inbox and it is a set membership
   test, not inference.
2. **Does this sender set `List-Unsubscribe`?** RFC 2369. A machine-sent marker
   the sender volunteers.
3. **Unread ratio.** 95% unread across 40 messages is an answer.
4. **Flagged count**, **volume**, **dormancy**.

## Layers

```
Grokbox/ (app)
  Views/                SwiftUI. No business logic.
  AppState              owns the three engines below, resolves the model

GrokboxCore/ (package, `swift test`)
  Sync/SyncEngine       index + read passes. Read-only IMAP.
  Sync/PlanExecutor     the ONLY writer. CleanupAction before every command.
  Sync/Maintainer       index → rules → read, on demand or timer
  Sync/CleanupPlan      proposal struct; rules-aware
  Mail/MailProvider     protocol seam — IMAP today, Gmail API later
  Mail/IMAP/IMAPClient  actor. EXAMINE for reads, SELECT only via executor.
  Mail/IMAP/IMAPConnection  actor. TLS socket, line/literal reader.
  Analysis/             heuristics, importance scoring, TextModel backends
  Models/               SwiftData. Headers, sender profiles, summaries, rules, action log.
  Analysis/SenderProfileBuilder   one pass headers → per-sender rows, after each index
  Security/             Keychain.
  Services/             RFC 8058 unsubscribe.

GrokboxCore/Tests/      FakeIMAPServer + 32 tests
```

### Why views never touch MessageHeader in bulk

`MessageHeader` is the big table — tens of thousands of rows. Nothing in the
UI iterates it. Senders and Sweep read `SenderProfile` (one row per sender).
Brief reads only rows with `briefRank > 0` through an indexed predicate and
counts the rest with `fetchCount`. The drill-down sheet queries one sender's
messages by the compound `(accountID, senderAddress)` index. See ADR-0009 and
ADR-0010 for the numbers.

### Why the executor is the only writer

`IMAPClient` exposes `select`/`store`/`move`, but nothing calls them except
`PlanExecutor`. Indexing and reading go through `examine`, which the server
enforces as read-only. So "can this code path modify mail?" is answered by
one grep for `openReadWrite`.

### Why an actor for the connection

IMAP is a strictly ordered request/response protocol over one socket. Two
concurrent reads would interleave and corrupt the parse. Actor isolation makes
that a compile-time impossibility rather than a race to debug at 2am.

### Why headers only

A leak of the Grokbox index should be materially less bad than a leak of the
mailbox. Headers are enough for every decision the tool makes. Bodies are not
needed, so they are not stored.

### Why no dependencies

The pitch is "your mail never leaves this machine." An npm- or SPM-shaped
dependency tree with read access to every message you own undercuts that claim
in a way no amount of documentation repairs. The IMAP client is ~400 lines
against a protocol that has been stable since 1996.

## Concurrency model

Swift 6 strict concurrency, complete checking.

- `IMAPConnection` and `IMAPClient` are actors.
- Data crosses actor boundaries only as `Sendable` value types (`FetchedHeader`,
  `IMAPMailbox`, `IMAPLine`).
- SwiftData `@Model` types are **not** `Sendable` and never leave `@MainActor`.
- `SyncEngine` is `@MainActor` and is the only place wire data becomes model
  objects.
