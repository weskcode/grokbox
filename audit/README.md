# Grokbox desktop audit — 2026-09-06

Full technical, functional, UX, accessibility, performance, security and release audit.

## Method

Three layers of evidence, in decreasing order of confidence:

1. **Runtime measurement on the real app.** Built, launched, and measured with `ps` CPU-time
   deltas, `sample`, `screencapture`, and the app's own file log. Every performance and
   CPU number in this report was measured, not estimated.
2. **The engine test suite.** 101 tests in 27 suites, all passing (~103 s). Log in
   `logs/swift-test.log`.
3. **An 11-dimension code review**, where every finding was then independently
   re-checked against the source with the aim of refuting it. Findings that
   could not be confirmed against real code were dropped.

## Environment actually tested

| | |
|---|---|
| Machine | Apple Silicon (Mac14,2), macOS 27.0 (26A5425a) |
| Toolchain | Xcode 26.6, Swift 6, XcodeGen |
| Build | Debug, ad-hoc signed, sandboxed |
| Display | Single built-in Retina, 2× scale, dark mode |
| Model backend | Apple Foundation Models — available on this machine |
| Mail backend | In-process demo mailboxes + loopback fake IMAP server |

## What could NOT be tested, and why

These are honest gaps, not passes:

- **A real IMAP server.** No live account was connected. Every IMAP path is verified only
  against a hand-written fake and the demo mailbox. This remains the single largest risk.
- **Windows and Linux.** The app is macOS-only by construction (SwiftUI + SwiftData +
  Foundation Models). Not a gap — a scope boundary.
- **Installer, updater, uninstaller, notarization, CI.** None exist to test.
- **Light mode, visually.** Three capture attempts returned wallpaper rather than the
  window. Verified statically instead (see `appearance` in issues.md).
- **VoiceOver, Voice Control, Switch Control, Full Keyboard Access interactively.**
  Assessed by source inspection only.
- **Multi-monitor, fractional scaling, external display, sleep/wake, network loss.**
  Single-display machine, no second display available.
- **Window resize / minimum size.** `System Events` could not address the window
  (accessibility permission not granted to the shell), so resize behaviour is unverified.
- **Migration from a previous version.** No previous released version exists.

## Files

| File | Contents |
|---|---|
| `executive-summary.md` | Verdict, top risks, release plan |
| `application-understanding.md` | What the product is and who it is for |
| `platform-and-stack.md` | Stack, targets, dependencies, entitlements |
| `build-results.md` | Build and test commands and results |
| `performance.md` | Measured launch, CPU, memory, throughput |
| `issues.md` | Every finding, with severity and evidence |
| `screenshots/` | Every screen as rendered |
| `logs/` | Test output |
