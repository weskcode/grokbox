# Picking this back up

Last updated 23 September 2026, after 0.5.1 shipped with the first two
batches of hardening work. Everything below was checked against the
repository on that date.

## Where the code is

| Branch | What it is |
|---|---|
| `main` | Released. Tagged `v0.5.1` at `5a80395` (SSH-signed tag). |
| `develop` | Integration branch, the same code as `main`. **Start new work here.** |

The four merged feature branches (`feature/hardening`, `feature/brief-accuracy`,
`feature/cleanup-policy`, `feature/sender-overrides`) were deleted locally and
on `origin` on 23 September. Every commit on them is in `develop`.

All commits are SSH-signed. CI now runs on Xcode Cloud (it was GitHub Actions
through 0.5.1), on pull requests and pushes to `main` and `develop`, and covers
engine tests, the Mac build, the iOS build, and the iOS UI tests.
CI was green on both PRs before they were merged, and on `main` before 0.5.1
was tagged.

## What shipped in 0.5.1

Published at <https://github.com/weskcode/grokbox/releases/tag/v0.5.1>,
signed and notarized. Hardening batches A (sweep safety, PR #1) and B (Brief
accuracy and copy, PR #2). Notes are in `docs/release-notes-0.5.1.md`.

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

The built archives and checksums sit in `dist/`, which is in `.gitignore`.

## Does it work?

Yes, on real mail. On 7 September it indexed a live Gmail account: 402
messages, 49 senders, 11 contacts learned from Sent, and per-sender advice that
held up.

**`/Applications/Grokbox.app` is the notarized 0.5.1 release**, installed
on 23 September. The ad-hoc 0.4.0 build it replaced, and a copy of its store,
are in `~/Grokbox-backup-2026-09-23`.

**The real Gmail account is no longer set up.** On 22 September at 11:30 a
session launched the installed app with `--reset --demo`, which erased all
local data, including that account and its Keychain password, and added the
three demo mailboxes. The Gmail mailbox itself was not touched.

**A sweep on real mail has still never run.** Before the reset, the pending
plan was 161 messages from 6 senders (85 on 7 September). Indexing and
reading are read-only by construction, so nothing in that mailbox has been
modified by the app yet. The sweep-safety fixes from batch A are in 0.5.1.

## What's waiting on you

1. **Re-add the Gmail account, then the real-mail sweep.** Add Account needs
   a new App Password. After the first index, pressing Sweep archives the
   planned messages into `Grokbox/` folders and can be undone from Activity.
   Until it runs, the product's core claim is unproven on a real server.
2. **The rest of the hardening plan** (next section).
3. **Housekeeping.** Delete the stray empty "New Shortcut 2" in the Shortcuts
   app, left over from testing the intent.

## The hardening plan

On 23 September all 112 findings in `audit/issues.md` were re-checked against
`main`: 16 were fixed, 24 partly fixed, 72 still open. Thread 5's IMAP timeout
contradiction is settled; `IMAPDeadlineTests` passes. The open ones were
grouped into batches:

- **A, sweep safety.** Shipped in 0.5.1 (PR #1): GB-028, 032, 058, 075, 076, 078, 079,
  081, 106, plus an unsubscribe that could follow a failed archive. Left
  over from its review: partial archives are not counted in "swept today";
  Stop while connecting shows "Connecting…" until the connect times out; the
  "Tidy up now" Shortcut returns quietly if a pass is already running;
  `PlanExecutor.undo` has a compiler warning about a `where` clause that
  only guards `.archive` (harmless today, since trash actions always record
  their target folder).
- **B, Brief accuracy and copy.** Shipped in 0.5.1 (PR #2): GB-008, 021, 023, 024, 025,
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
- **`--reset` erases every account, its index and its Keychain password**,
  which is how the real Gmail account was lost on 22 September. Every build
  with the `com.wesleykeetch.grokbox` bundle ID, Debug builds included, shares
  one sandbox container, so don't pass `--reset` while a real account is set
  up.
- **Several Claude sessions have run in this directory at once before.** One
  of them left the Jev categorizer as uncommitted, unreviewed changes. Check
  `git status` before starting and don't assume you're the only writer.

## Useful commands

```bash
cd GrokboxCore && swift test                 # 213 tests, ~50s
scripts/release.sh 0.5.2                     # full release, refuses if unsafe
open /Applications/Grokbox.app               # the installed 0.5.1 release
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
