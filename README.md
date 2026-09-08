# Grokbox

A local-first mail triage tool for macOS. It indexes your mailboxes, collapses
them into senders, and tells you what is actually filling your inbox — without
any of it leaving your machine.

Built for the specific problem of the **email pile-up**: tens of thousands of
messages, most of them machine-sent, and no viable path through them one at a
time.

## In one paragraph

Grokbox is a **macOS** app, **GPL-3.0**, with **no third-party code**, **no
telemetry**, **no account**, and **no server of its own**. It talks to exactly
three things: the IMAP servers you add, a language model running on this Mac,
and — only when you click it — a sender's own unsubscribe URL. The full list is
in [docs/PRIVACY.md](docs/PRIVACY.md); what that protects and does not protect
is in [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md); how to report a problem is
in [SECURITY.md](SECURITY.md). It is built by one person (Wesley Keetch) for
their own inboxes, and audited against the
[Privacy Guides criteria](docs/PRIVACY-GUIDES-AUDIT.md) so you can check the
claims rather than take them.

## What it does (v0.4)

- **Where things stand** — one button (⌘⇧S) at the top of the Brief: a
  plain-language summary of the inbox right now — what needs you, what is
  due, what was filed, what is waiting for a decision — plus the five things
  to start with and why. Instant, kept with a timestamp, copyable.
- **Brief** — the landing screen. **Now** (three things, then stop), **Quick
  wins**, **Then**, and *Worth knowing* folded away. Each row says why it is
  where it is — "due tomorrow · money · someone you talk to often" — with a
  one-sentence summary written by a model running on this Mac. **Later**
  defers a row to a time you choose.
- **Senders** — every sender as one row with its **type** (promotion,
  newsletter, notification, receipts, person) and a plain **recommendation**
  with the evidence: *get rid of it* / *keep but out of the inbox* / *silence
  it* / *leave it* / *look first*. One-click unsubscribe. Rules.
- **Sweep** — the proposed plan grouped by destination folder — Promotions,
  Newsletters, Notifications — never a generic bin. A **guard** holds back
  flagged mail, mail that needs you, and receipts, and says so.
- **Activity** — every change Grokbox made, newest first, with Undo.
- **Catch up on older mail** — the reader normally looks back 30 days. Catch-up
  reads the last three months or year, but only from people and
  record-keeping senders (or flagged) — the things an ignored inbox hides.
- **Menu bar** — the latest summary and the top three items, glanceable
  without opening the window, plus Tidy up now. Tidy-ups keep running with
  the window closed.
- **Tidy-up** — on demand or on a timer: index new mail, apply your rules, read
  what matters. Never sweeps a sender you have not approved.

Reading uses **Apple's on-device model** (macOS 26+, no setup) or **Ollama**
(open source, `brew install ollama`). Bodies are fetched, read, and discarded;
only the summary is kept.

## What it will not do

- **Delete.** No code path sets `\Deleted` or sends `EXPUNGE`; a test enforces it.
- **Send mail.** No SMTP.
- **Act on a sender you have not approved.**
- **Talk to anything but your mail server, Ollama on loopback, and — when you
  click it — a sender's own unsubscribe URL.** Full inventory in
  [docs/PRIVACY.md](docs/PRIVACY.md).

## Privacy

- No network traffic except IMAP to your own mail server
- No telemetry, no analytics, no crash reporting, no accounts
- No third-party dependencies — the IMAP client is written from scratch
- Passwords live in the macOS Keychain
- The local index holds headers, not message contents
- Sandboxed, with `network.client` as its only entitlement

## Requirements

- macOS 26 or later (Apple Intelligence-capable Mac for the built-in model;
  any Apple Silicon Mac with Ollama otherwise)
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

```bash
xcodegen generate
open Grokbox.xcodeproj
```

Then Cmd+R.

The engine is a Swift package with its own fast test loop. 45 tests, including
an IMAP server on loopback that exercises the real client end to end, and a
lifecycle test that runs index → sweep → undo → incremental sync → maintenance
through the same engines the buttons call. When this Mac can run Apple's
on-device model, one test reads real (demo) mail with it:

```bash
cd GrokboxCore && swift test
```

### If codesign fails with "resource fork, Finder information, or similar detritus"

This repo lives under a synced folder (iCloud Drive / a file provider), which
stamps extended attributes onto build products faster than they can be stripped,
and `codesign` refuses to sign a bundle carrying them. Build to derived data
outside the synced tree:

```bash
xcodebuild -project Grokbox.xcodeproj -scheme Grokbox -derivedDataPath ~/Library/Developer/Xcode/DerivedData/Grokbox build
```

Xcode's own default derived-data location is already outside the synced folder,
so building from the IDE does not hit this.

## Try it before trusting it

**Add Account → Add demo mailboxes** creates three sample inboxes — *Personal*,
*Work*, and a neglected *Old Gmail* — generated on this Mac and served from
inside the app's own process. No socket, no network, nothing real. Index them,
read them with the on-device model, sweep, undo, and watch every screen work
before you connect anything you care about.

For scripting and screenshots the app also takes launch flags:

```bash
Grokbox.app/Contents/MacOS/Grokbox --reset --demo --run-all --demo-sweep --section brief --account all
```

`--demo-sweep` and `--demo-undo` only ever apply to demo accounts. The app
writes its milestones (counts and phases only, never message contents) to a
plain file you can watch or attach to a bug report:

```bash
tail -f ~/Library/Containers/com.wesleykeetch.grokbox/Data/Library/Logs/grokbox.log
```

## Setting up accounts

See [docs/SETUP-ACCOUNTS.md](docs/SETUP-ACCOUNTS.md). Short version: Gmail needs
an **App Password**, not your Google password. Proton Mail needs **Proton Mail
Bridge** running, which requires a paid Proton plan.

## Design notes

- [Architecture](docs/ARCHITECTURE.md)
- [Decisions and their reasoning](docs/DECISIONS.md)
- [Roadmap](docs/ROADMAP.md)

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).


## On iPhone and iPad

The same engine, the same store, the same rules. The phone is the Brief in
your pocket: see what needs you, swipe it Done or Later, unsubscribe from the
sender. Heavy work — deep indexing, thousand-message sweeps — is still a Mac
job; iOS suspends apps in the background, so tidy-up runs while Grokbox is
open. Summaries come from Apple's on-device model (Ollama is Mac-only).
Build the `GrokboxiOS` scheme.

## You decide how aggressive it is

Three starting points — **Gentle**, **Balanced**, **Thorough** — and every dial
behind them. Where swept mail goes (filed into folders, archived, or moved to
your provider's Trash, separately for promotions), how much recent mail is
protected, how many of each sender's newest messages are kept, and whether
Grokbox may press a sender's own one-click unsubscribe for you. Every policy
states in one sentence what it will do, above the button that does it. The
default is Gentle, and Grokbox never destroys a message: it has no code path
that deletes or expunges. See [ADR-0019](docs/DECISIONS.md).

## Works with any IMAP server

Gmail is handled natively (labels, All Mail). Everything else — iCloud,
Fastmail, Outlook, Yahoo, Proton via Bridge, your own Dovecot — goes through
plain IMAP: mail is filed by moving it into folders Grokbox creates, spelled the
way that server spells folders, and moves are undoable wherever the server
supports UIDPLUS. Setup notes per provider are in
[docs/SETUP-ACCOUNTS.md](docs/SETUP-ACCOUNTS.md).

## Build from source

See [CONTRIBUTING.md](CONTRIBUTING.md). Two commands: `xcodegen generate`, then
`xcodebuild`. Tests: `cd GrokboxCore && swift test`.

## Status

Paused September 2026 — see [docs/RESUMING.md](docs/RESUMING.md) for where things
stand and what to do next.

Verified against three in-process demo mailboxes (personal, work, neglected —
about 40,000 messages). **Not yet run against a live IMAP server.** Treat it as
pre-release until that line changes.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md). Changes are listed in
[CHANGELOG.md](CHANGELOG.md).

## Licence

GPL-3.0-or-later. This rules out the Mac App Store, which is fine: Grokbox is
distributed from this repository only.
