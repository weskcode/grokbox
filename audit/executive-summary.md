# Executive summary

**Audited:** Grokbox 0.2.0 (docs say v0.4), macOS 26+ target, running macOS 27, Apple Silicon.
**Date:** 2026-09-06.

## Verdict

**Not release-ready — but much closer than the finding count suggests.**

The engineering underneath this app is genuinely good: a clean app/engine split, 101 passing
tests including a loopback IMAP server and a full lifecycle test, Swift 6 strict concurrency
throughout, zero third-party dependencies, a sandbox with exactly two entitlements, and a
privacy story that survived a hostile read of the code. Nothing in the audit contradicted the
core claim that mail stays on the machine.

What stops it shipping is a small number of specific defects — not systemic rot. Two P0-class
bugs were found **and fixed during this audit**; three P1s remain, all in the same area
(what happens when the network or the server misbehaves), and all fixable in days rather than
weeks.

The honest headline: **the app has never spoken to a real mail server**, and the three P1s are
precisely the failures a real server would trigger first.

## Fixed during this audit

| | Defect | Evidence |
|---|---|---|
| **P0** | **100% of a CPU core consumed permanently while idle**, on every screen. `MenuBarExtra(isInserted:)` bound to `@AppStorage` created an unbounded scene-invalidation loop. | Bisected against controls; 8.10 → 0.03 cpu-sec/8 s by swapping only the binding. Now 0.00–0.01 idle everywhere. |
| **P0** | Main window did not appear at launch — the app looked dead. `WindowGroup(id:)` is not presented at launch on macOS 27. | Reproduced and reverted; ADR-0016. |
| **P1** | Startup deadlock: `SystemLanguageModel.availability` blocks on an XPC reply delivered via the main run loop. | App hung at "probing Apple on-device model"; now `Task.detached` + 8 s bound. |

## Findings

| Severity | Count |
|---|---|
| P0 | 0 (2 found and fixed) |
| **P1** | **3** |
| P2 | 31 |
| P3 | 59 |
| P4 | 19 |

100 findings survived adversarial verification; **27 were refuted and dropped**. 12 further
items came from a completeness critic and are flagged as unverified.

## The three P1s — all one theme: failure handling

1. **`withTimeout` cannot time out.** (GB-002/GB-003) The IMAP connect and read deadlines are
   inert. A throwing task group awaits every child before propagating, and the wrapped
   `withCheckedThrowingContinuation` around `NWConnection.receive` is not cancellation-aware —
   so the deadline task wins the race but cannot leave the scope. **Independently reproduced:**
   a 3-second timeout did not fire after 12 seconds against a server that accepts TCP and then
   goes silent. Because every entry point is guarded by `!phase.isRunning`, one wedged socket
   stops *all* mail work for the rest of the session, with no in-app recovery on the sweep and
   tidy-up paths (neither `PlanExecutor` nor `Maintainer` has a `cancel()`). `docs/AUDIT.md:50`
   claims this class of hang is fixed. **That claim is false and should be corrected.**

2. **UIDVALIDITY guard is disarmed by the next index pass.** (GB-001) The check that stops
   Undo from acting on renumbered mailboxes is invalidated by a subsequent index, so Undo can
   mutate unrelated messages. Data-integrity risk on the one operation whose entire purpose is
   to be safe.

3. Both of the above are latent on the demo mailbox and would surface on first contact with a
   real server.

## Top five strengths

1. **Privacy claims hold up.** A hostile read found exactly four outbound connection kinds, all
   user-initiated or loopback, and confirmed message bodies are never persisted.
2. **Structural safety.** No delete path exists anywhere; indexing uses `EXAMINE` so the *server*
   refuses writes; every mutation is logged before it runs.
3. **The test suite is real.** 101 tests including an in-process IMAP server the real client
   talks to — not mocks asserting on mocks.
4. **Performance work is done and measured.** 40 000 messages → 400 sender profiles in 1.45 s;
   UI query 0.039 s; launch 0.26 s.
5. **Explainability is designed in.** Every verdict, recommendation and Brief row carries its
   evidence. This is the hardest part of the product brief and it is the part most clearly met.

## Top five risks

1. **Never tested against a real IMAP server.** Ten protocol findings (UTF-7 mailbox names,
   hierarchy delimiters, `\All` on non-Gmail servers, English-only Sent discovery) are exactly
   the things a fake server cannot surface.
2. **Failure handling is the weakest subsystem** — timeouts, cancellation, and stop controls.
3. **No schema versioning.** 8 `@Model` types, no `VersionedSchema`, and container failure is a
   `fatalError`. The first schema-breaking update bricks existing installs at launch.
4. **Accessibility is effectively absent.** Zero accessibility labels; colour used alone to carry
   meaning; the app's own explainability line measured at 2.27:1 contrast.
5. **Nothing exists to ship it.** No icon, no privacy manifest, no signing identity, no
   notarization, no installer, no updater, no CI.

## Recommended release plan

**Before any use on a real mailbox**
- Fix `withTimeout` (make the continuations cancellation-aware, or cancel the `NWConnection`
  from the deadline branch), add `cancel()` to `PlanExecutor` and `Maintainer`, correct
  `docs/AUDIT.md:50`.
- Fix the UIDVALIDITY/Undo interaction.
- Add `VersionedSchema` + a migration plan, and replace the `fatalError` with a recoverable path.

**Before giving it to anyone else**
- Accessibility pass: labels on every control, stop using colour alone, fix contrast.
- App icon, `PrivacyInfo.xcprivacy`, version alignment, Developer ID signing + notarization.
- Menu-bar commands and a `Settings` scene (⌘, currently does nothing).
- Password update flow — today a rotated credential can only be fixed by removing the account,
  which destroys its history.

**Before calling it v1**
- Real-server test matrix: Gmail, Proton Bridge, Fastmail, Dovecot.
- Bound the first-run experience on a 40 000-message mailbox, or make it resumable.
- CI running `swift test` plus a UI smoke test.

## Testing limitations

Everything in `README.md` § "What could NOT be tested". The material ones: no live IMAP account,
single display, dark mode only (light mode verified statically, not visually), no interactive
VoiceOver, and no installer/updater to exercise because none exists.
