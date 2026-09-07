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

Around 110 tests in 30 suites, including an in-process IMAP server and a real
TLS handshake with `imap.gmail.com` (no credentials are sent).

## Rules that are not negotiable

- **Nothing leaves the machine that is not in `docs/PRIVACY.md`.** A pull
  request that adds an outbound request must add the row first.
- **No third-party dependencies.** The engine builds with stock Xcode.
- **No message is ever deleted.** "Get rid of it" means unsubscribe, file, and
  write a rule.
- **No telemetry, ever.** Not opt-in, not anonymised, not "just crash reports".
- **Every action is undoable** from Activity, and every automatic action must
  explain itself in one line a tired person can read.

## Decisions

Architectural decisions are recorded in `docs/DECISIONS.md` as ADRs. If a
change contradicts one, add a new ADR that supersedes it rather than editing
history.

## Licence

Contributions are accepted under GPL-3.0-or-later. Sign your commits
(`git config commit.gpgsign true`; SSH signatures are fine).
