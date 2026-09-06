# Performance — measured

All numbers below were measured on the real app on this machine. CPU figures are
**CPU-seconds consumed in a fixed wall-clock window**, not `ps`'s decaying average, because
the average is misleading for a freshly launched process.

## Headline: a 100%-CPU idle spin, found and fixed

The most serious defect in this audit. The app burned **a full CPU core, permanently,
while completely idle**, on every screen — including a build whose entire window content
was the literal `Text("bare")`.

### How it was isolated

| Test | CPU-seconds per 8–10 s idle |
|---|---|
| Plain SwiftUI hello-world (control) | ~0.0 |
| Hello-world **with** `MenuBarExtra(.window)` (control) | 0.0 |
| Grokbox, `--ui bare` (window shows one `Text`) | **9.90 / 10 s** |
| Grokbox launched directly rather than via `open` | 0.03 / 10 s |

The controls proved SwiftUI and `MenuBarExtra` were not at fault, and that the spin was
specific to Grokbox and required the app to be activated. Substituting the
`MenuBarExtra(isInserted:)` binding then isolated it exactly:

| `isInserted:` binding | CPU-seconds per 8 s |
|---|---|
| `.constant(false)` — no status item | 0.01 |
| `.constant(true)` | 0.03 |
| `@State` binding | 0.05 |
| **`@AppStorage` binding** | **8.10** |

### Root cause

`MenuBarExtra` echoes its insertion state back through the `isInserted:` binding on every
scene update. When that binding is `@AppStorage`, the echo writes `UserDefaults`, which
invalidates the App body, which rebuilds the scene, which echoes again — an unbounded
invalidation loop. A `sample` of the hot thread showed
`NSHostingView.beginTransaction → GraphHost.flushTransactions → AG::Graph::UpdateStack::update`
with `MenuBarView` on the stack, i.e. the menu-bar content being rebuilt continuously
while closed.

### Fix and verification

The preference now lives on `AppState` (`@Observable`) and the App binds through a
`Binding` whose setter drops no-op writes; `AppState.showMenuBar`'s `didSet` likewise
ignores unchanged values. Either guard alone breaks the cycle; both are present.

| After the fix | CPU-seconds per 10 s idle |
|---|---|
| `--ui bare` | 0.00 |
| Brief, all accounts | 0.01 |
| Senders | 0.01 |
| Sweep | 0.00 |

Functional regression check: the preference still persists and is honoured in both
states, with no spin either way.

## Launch

| Run | Time to first window |
|---|---|
| 1 (cold) | 0.83 s |
| 2 | 0.26 s |
| 3 | 0.27 s |

Well inside the "feels instant" band. Nothing blocking on the main thread at startup —
model probing was deliberately moved off the launch path and bounded (see below).

## Memory

RSS over 60 s idle with three demo accounts (~5 000 indexed messages):

| t | RSS |
|---|---|
| 0 s | 101 MB |
| 20 s | 200 MB |
| 40 s | 123 MB |
| 60 s | 124 MB |

The spike-then-settle is the model probe and initial SwiftData load; it returns and stays
flat, so there is no evident leak over this window. 124 MB idle is unremarkable for a
SwiftData + SwiftUI app but is not small; a long-running menu-bar app should be watched
over hours, which this audit did not do.

## Throughput (from instrumented runs)

| Operation | Measured |
|---|---|
| `SenderProfileBuilder` rebuild, 40 000 messages → 400 profiles | **1.45 s** |
| Same rebuild, repeated (idempotency check) | 1.39 s |
| UI-facing profile query | **0.039 s** |
| Seeding 40 000 messages into SwiftData | 5.1 s |
| On-device model, one message read | ~2–10 s |
| Full 3-account tidy-up incl. reading | 4–10 min |
| Sweep of 3 742 messages across 47 senders | ~5 s, 0 errors |
| App bundle | 6.6 MB |

The 40 000-message figures are the ones that matter: they are why per-sender aggregates
are persisted rather than recomputed in the view. Before that change, inserting 40 000
messages through a SwiftData relationship took **365 s**; replacing the relationship with
an indexed `accountID` column brought it to **5 s**.

## Model probe deadlock (previously found and fixed)

`SystemLanguageModel.availability` blocks its calling thread on an XPC reply delivered via
the main run loop. Called on the main actor inside a GUI app it deadlocks outright — the
app started, logged `probing Apple on-device model`, and never progressed. It is now
called from `Task.detached` and raced against an 8-second timeout, and startup no longer
awaits it. Verified: startup completes, and the same call from a standalone process
returns in under a second.

## Remaining performance risk (not fixed)

The model reading loop is strictly sequential and uncapped in wall-clock terms. On a real
40 000-message backlog the first "catch up" pass is a multi-hour operation with no
concurrency and no resumable checkpoint visible to the user beyond a progress label. This
is the largest remaining performance question and it has not been measured against a real
mailbox.
