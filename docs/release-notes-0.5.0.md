# Grokbox 0.5.0

Multi-account triage gets contacts, search, a message reader, per-sender folder routing, an optional cloud categorizer, an app lock, and a Shortcuts action.

## New

- Opt-in Jev cloud categorizer as a fallback when the local model is unsure (ADR-0023). Off by default; only sender address and subject leave the device when enabled.
- Contacts view listing everyone you've actually exchanged mail with, deduplicated across accounts.
- Search across subject, sender name, sender address, and summary in the Brief and in a sender's message list.
- An on-demand message reader on macOS. It opens a read-only connection, fetches the body, and discards it when the sheet closes.
- Folder picker for routing one sender's mail to a specific mailbox instead of the category default.
- Unsubscribe checklist: review and export senders Grokbox recommends unsubscribing from (ADR-0024).
- Face ID/Touch ID app lock, off by default. A session that's already unlocked stays unlocked even if you turn the setting on mid-session; the lock only takes effect from the next cold launch.
- A "Tidy up Grokbox" Shortcuts action and Siri phrase. It runs in-process; nothing executes while the app isn't open.
- iOS: the "notify on tidy-up" toggle that was already on macOS.

## Fixed

- PRIVACY.md's autoconfig gap and a broken verification grep.

## Under the hood

- MessageHeader.subject is now indexed, so subject search doesn't scan every row.
- Toolchain pinned to Xcode 27.

Signed with a Developer ID Application certificate and notarized by Apple.

SHA-256: `d4cece1fe1d8d14341450ca16cfaab0fe9b5ae3e243989b368fd74882b1da07a`
