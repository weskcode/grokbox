# Picking this back up

Paused 7 September 2026. Everything below was true when work stopped.

## Where the code is

| Branch | What it is |
|---|---|
| `feature/cleanup-policy` | Everything from this stretch of work. Fully merged into `develop`. Safe to delete once you are happy. |
| `develop` | Integration branch. Has all the work. **Start here.** |
| `main` | Twelve commits behind `develop`, on purpose: nothing has been released yet, so `main` still points at the last stable point. Merge `develop` into it when you cut 0.5.0. |

All commits are SSH-signed and show `G`. CI runs on all three branches and
covers engine tests, the Mac build, the iOS build, and the iOS UI tests.

## Does it work?

Yes, on real mail. On 7 September it indexed a live Gmail account: 402
messages, 49 senders, 11 contacts learned from Sent, and per-sender advice that
held up — "you read about 100% of these" for a newsletter actually read, "82%
unopened across 41 messages" for one that is not.

The Mac app is installed at `/Applications/Grokbox.app`, sandboxed, with that
account still set up.

**One thing has never run: a sweep on real mail.** A plan for 85 messages from
6 senders is waiting in the Sweep tab. Indexing and reading are read-only by
construction, so nothing in that mailbox has ever been modified by this app.

## The two decisions waiting on you

### 1. Approve a sweep, or don't

The Sweep tab has a plan. Pressing the button archives those messages into
`Grokbox/` folders and is undoable from Activity. Until someone does that, the
product's whole point is unproven.

### 2. Pay for the Apple Developer Program, or don't

`scripts/release.sh 0.5.0` does the entire release and is tested as far as it
can be. It is blocked on a **Developer ID Application** certificate, which
needs Developer Program membership at $99/year. The machine has only an "Apple
Development" certificate, which cannot distribute to other people.

Without it: build from source, or accept the "unidentified developer" warning.
With it: one command produces a signed, notarised, checksummed release.

See `docs/RELEASING.md`.

## If you want to keep building

In rough order of value:

1. **The 138 unread the model has not read.** Catch-up deliberately skips bulk
   senders in old mail, which may be wrong for a genuine backlog. Worth
   revisiting if the pile-up is the thing you want solved.
2. **OAuth for Gmail and Outlook.** Google is phasing out App Passwords and
   Microsoft has nearly finished doing so. This is the medium-term risk to
   "works with Gmail" — the largest single piece of remaining work.
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

## Useful commands

```bash
cd GrokboxCore && swift test                 # 172 tests, ~40s
scripts/release.sh 0.5.0                     # full release, refuses if unsafe
open /Applications/Grokbox.app               # the installed build
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
