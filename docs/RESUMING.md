# Picking this back up

Last updated 23 September 2026, the day after 0.5.0 shipped, once the first
two batches of hardening work were merged into `develop`. Everything below was
checked against the repository on that date.

## Where the code is

| Branch | What it is |
|---|---|
| `main` | Released. Tagged `v0.5.0` at `34a97d1` (SSH-signed tag). Ahead of `develop` only by merge commits and `docs/release-notes-0.5.0.md`; no code differs. |
| `develop` | Integration branch. Has 0.5.0 plus hardening batches A and B (PRs #1 and #2), which are not released yet. **Start new work here.** |
| `feature/hardening` | Batch A, sweep safety (PR #1). Merged into `develop`. Safe to delete. |
| `feature/brief-accuracy` | Batch B, Brief accuracy (PR #2). Merged into `develop`. Safe to delete. |
| `feature/cleanup-policy` | Fully merged into `develop` and `main`. The local copy (`ebef28e`) is 15 commits ahead of its stale `origin` copy (`b963a61`); both are merged. Safe to delete locally and on `origin`. |
| `feature/sender-overrides` | Fully merged into `develop`. Safe to delete locally and on `origin`. |

All commits are SSH-signed. CI runs on `main`, `develop` and feature branches
and covers engine tests, the Mac build, the iOS build, and the iOS UI tests.
CI was green on both PRs before they were merged.

## What shipped in 0.5.0

Published at <https://github.com/weskcode/grokbox/releases/tag/v0.5.0>, signed
with the Developer ID Application certificate and notarized. Notes are in
`docs/release-notes-0.5.0.md`.

Two approved plans from `GROKBOX-UPGRADE.md` landed in this release:

- **Thread 3:** the iOS notifications toggle, the contacts view, search, the
  on-demand message reader (macOS only), and the folder picker.
- **Thread 4:** the `PRIVACY.md` fixes, the biometric app lock, the subject
  index, and the "Tidy up now" Shortcuts intent.

Also in the release: the opt-in Jev cloud categorizer (ADR-0023) and the
unsubscribe checklist export (ADR-0024).

Release signing works on this Mac. The Apple Developer Program membership is
paid (team `HD39MR492X`), the certificate is in the keychain, and the
`grokbox` notarytool profile is stored. `scripts/release.sh <version>` does
the whole thing. See `docs/RELEASING.md`.

The built archive and checksum sit in `dist/`, which is untracked and not in
`.gitignore`.

## Does it work?

Yes, on real mail. On 7 September it indexed a live Gmail account: 402
messages, 49 senders, 11 contacts learned from Sent, and per-sender advice that
held up.

**The copy in `/Applications/Grokbox.app` is an old 0.4.0 build, ad-hoc
signed**, not the 0.5.0 release. It is sandboxed and still has that account
set up, so anything you test through it is 0.4.0 behavior.

**A sweep on real mail has still never run.** On 22 September the pending
plan was 161 messages from 6 senders (it was 85 on 7 September). The owner
is clicking through it by hand. Indexing and reading are read-only by
construction, so nothing in that mailbox has been modified by the app yet.
The sweep-safety fixes in batch A (Stop that really stops, rules written only
after success, failures reported as failures) are on `develop` only. Neither
the installed 0.4.0 build nor the 0.5.0 release has them.

## What's waiting on you

1. **The real-mail sweep.** Pressing the button archives those messages into
   `Grokbox/` folders and can be undone from Activity. Until it runs, the
   product's core claim is unproven on a real server.
2. **Whether to cut 0.5.1** with batches A and B, so the sweep fixes reach
   the app. `scripts/release.sh 0.5.1` does it once `develop` is merged into
   `main`.
3. **The rest of the hardening plan** (next section).
4. **Housekeeping.** Delete the four merged branches above. Delete the stray
   empty "New Shortcut 2" in the Shortcuts app, left over from testing the
   intent.

## The hardening plan

On 23 September all 112 findings in `audit/issues.md` were re-checked against
`main`: 16 were fixed, 24 partly fixed, 72 still open. Thread 5's IMAP timeout
contradiction is settled; `IMAPDeadlineTests` passes. The open ones were
grouped into batches:

- **A, sweep safety.** Done (PR #1): GB-028, 032, 058, 075, 076, 078, 079,
  081, 106, plus an unsubscribe that could follow a failed archive. Left
  over from its review: partial archives are not counted in "swept today";
  Stop while connecting shows "Connecting…" until the connect times out; the
  "Tidy up now" Shortcut returns quietly if a pass is already running.
- **B, Brief accuracy and copy.** Done (PR #2): GB-008, 021, 023, 024, 025,
  029, 033, 034, 067, 072, and Thread 2's copy fixes.
- **C, accessibility.** Not started: GB-006, 035, 036, 037, 040, 041, 091,
  then Thread 2's `--demo` pass with `macos-jev-tester`. The contrast items
  (GB-005, 022, 038) change colours, so they need the owner's pick between
  options first.
- **Needs sign-off, item by item:** privacy docs that describe an autoconfig
  button the app does not have (GB-042, 073, 110, plus 071, 109); deleting
  user data (GB-010, 031, 045, 053, 094, and GB-016, whose fix would orphan
  local rows); notifications (GB-007, 048); schema (GB-047, 054); auth and
  Keychain (GB-009, 100, 107, 108); THREAT-MODEL.md's wording on GB-029.
- **Deferred:** about 25 performance, IMAP-parsing and UX items. See
  `audit/issues.md` for any ID not listed above.

## If you want to keep building

In rough order of value:

1. **The unread mail the model hasn't read.** Catch-up deliberately skips bulk
   senders in old mail, which may be wrong for a genuine backlog.
2. **OAuth for Gmail and Outlook.** Google is phasing out App Passwords and
   Microsoft has nearly finished doing so. This is the medium-term risk to
   "works with Gmail" and the largest single piece of remaining work.
3. **Accessibility.** VoiceOver labels exist on the Brief, Senders and
   Activity. Nothing has been tested with VoiceOver actually running.
4. **The app on a real iPhone.** Builds and passes UI tests on the simulator.
   Needs your signing to install on hardware.

## Things that will bite you

Written down because each one cost hours.

- **Never `codesign --force --deep --sign -` after copying the app.** It strips
  the App Sandbox entitlement and the app silently runs unsandboxed, writing
  its database outside its container. Always pass
  `--entitlements Grokbox/Grokbox.entitlements`.
- **Two `VersionedSchema`s pointing at the same model types crash at launch**
  with "Duplicate version checksums detected". Additive changes need no
  migration stage at all. See ADR-0021.
- **`WindowGroup(id:)` is not presented at launch on macOS 26.** ADR-0016.
- **Never bind `MenuBarExtra(isInserted:)` to `@AppStorage`.** It spins a core
  forever. ADR-0017.
- **Build with a derived-data path outside the synced Developer folder.**
  iCloud extended attributes break code signing.
- **Apple's on-device model fails inside the iOS 26.5 simulator.** Use
  `--stub-model` for demos and tests; it works on the Mac and on real hardware.
- **Automation can't reliably bring Grokbox to the front.** On 22 September,
  activating it by name or by bundle ID (`com.wesleykeetch.grokbox`) raised
  two unrelated apps instead. Bring the window forward by hand before
  automating anything that touches real mail.
- **`git tag -v` says "No principal matched"** even though the signature is
  good. This clone's `gpg.ssh.allowedSignersFile` still points at an old
  `~/Documents/Developer/grokbox/.allowed_signers` path. Point it at the
  repo's `.allowed_signers` to fix it.
- **Several Claude sessions have run in this directory at once before.** One
  of them left the Jev categorizer as uncommitted, unreviewed changes. Check
  `git status` before starting and don't assume you're the only writer.

## Useful commands

```bash
cd GrokboxCore && swift test                 # 213 tests, ~50s
scripts/release.sh 0.5.1                     # full release, refuses if unsafe
open /Applications/Grokbox.app               # the installed (0.4.0) build
```

Read-only flags for exercising a real mailbox with no path that can modify it:

```bash
/Applications/Grokbox.app/Contents/MacOS/Grokbox --index 25000
/Applications/Grokbox.app/Contents/MacOS/Grokbox --read 400
```

The app's log, which never contains message content:

```
~/Library/Containers/com.wesleykeetch.grokbox/Data/Library/Logs/grokbox.log
```
