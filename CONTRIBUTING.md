# Contributing

## Build

Requirements: macOS 26 or later, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project Grokbox.xcodeproj -scheme Grokbox -configuration Debug -derivedDataPath /tmp/grokbox-dd build
```

For the iPhone/iPad app:

```bash
xcodebuild -project Grokbox.xcodeproj -scheme GrokboxiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/grokbox-dd-ios CODE_SIGNING_ALLOWED=NO build
```

Build with a derived-data path outside any iCloud-synced folder; synced
extended attributes break code signing.

## Test

```bash
cd GrokboxCore && swift test
```

UI tests for the phone app: add `-only-testing:GrokboxiOSUITests` to an `xcodebuild test` on the `GrokboxiOS` scheme. They launch with `--stub-model`, a rules-only reader, so they never depend on the on-device model.

Around 130 tests in 40 suites, including an in-process IMAP server and a real
TLS handshake with `imap.gmail.com` (no credentials are sent).

## Rules that are not negotiable

- **Nothing leaves the machine that is not in `docs/PRIVACY.md`.** A pull
  request that adds an outbound request must add the row first.
- **No third-party dependencies.** The engine builds with stock Xcode.
- **No message is ever destroyed.** There is no code path that sets `\Deleted`
  and none that issues `EXPUNGE`. Moving to the provider's own Trash is allowed
  when the user has chosen it, because they can take it back until the provider
  empties it; see ADR-0019.
- **No telemetry, ever.** Not opt-in, not anonymised, not "just crash reports".
- **Every action is undoable** from Activity, and every automatic action must
  explain itself in one line a tired person can read.

## Decisions

Architectural decisions are recorded in `docs/DECISIONS.md` as ADRs. If a
change contradicts one, add a new ADR that supersedes it rather than editing
history.

## Branching

Three kinds of branch, and no others:

- **`main`** is released. Every commit on it is a version someone could be
  running. It only ever moves by a merge from `develop`.
- **`develop`** is where finished work integrates and waits for a release. Cut
  every branch from here, and merge every branch back here.
- **`feature/<short-name>`** is where work happens — one branch per change,
  named for the change (`feature/cleanup-policy`), deleted once merged.

```bash
git checkout develop && git pull
git checkout -b feature/my-change
# ... work, commit ...
git push -u origin feature/my-change
```

Rebase a feature branch on `develop` to pick up other people's work; do not
rebase anything that has been merged, and never force-push a shared branch.

Sign every commit, on every branch (`git commit -S`, with
`commit.gpgsign true` set). Unsigned commits are not merged.

## Licence

Contributions are accepted under GPL-3.0-or-later. Sign your commits
(`git config commit.gpgsign true`; SSH signatures are fine).
