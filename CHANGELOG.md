# Changelog

All notable changes to Grokbox are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Mailbox menu with keyboard shortcuts: Add Account ⌘N, Read New Mail ⌘R,
  Index ⌘I, Tidy Up Now ⌘T, Where Things Stand ⌘⇧S, Stop ⌘., Settings ⌘,.
  Help menu links to the privacy inventory, threat model and issue tracker.
- Update Password on an account (sidebar context menu, or the button that
  appears when a sync fails on sign-in) — no need to remove the account and
  lose its history.
- The Brief shows one row per conversation; Done and Later act on the whole
  thread.
- VoiceOver: rows in the Brief, Senders and Activity read as sentences; every
  icon-only control has a label; the "why here" line meets contrast.
- Plain IMAP servers are first-class: folders are created with the server's
  own hierarchy delimiter and namespace prefix, mailbox names in modified
  UTF-7 are decoded and encoded, the Sent folder is found by special-use flag
  or by its name in twenty languages, and archives done by MOVE are undoable
  when the server reports the new message IDs (COPYUID).
- A generic-server flavour of the demo mailbox, and end-to-end tests of every
  feature against it and a Courier-style `INBOX.`-prefixed server.
- Transport handshake tests against Gmail, iCloud, Outlook, Yahoo and Fastmail.
- Settings → Your data: export accounts (without passwords), rules, the action
  log and saved digests as JSON; import rules from an export.
- Unsubscribe requests are refused unless the target is an HTTPS URL on a
  public host, and follow at most one redirect under the same rule.
- Versioned SwiftData schema with a migration plan; the store now recovers
  from an unreadable database instead of failing to launch.
- Threat model, security policy, contributing guide, and an audit against the
  Privacy Guides criteria.
- Continuous integration on GitHub Actions (macOS 26).

### Fixed
- IMAP deadlines now tear the connection down, so a silent server can no
  longer stall the engine for the rest of the session.
- Stop now cancels indexing, reading, sweeping and tidy-up, including a
  command parked on an unresponsive server.
- Undo compares the mailbox's UIDVALIDITY recorded at sweep time against the
  live value, so a renumbered mailbox can no longer be undone against the
  wrong messages.
- Idle CPU usage: a menu-bar binding loop that kept one core busy.
- Main window not appearing at launch on macOS 26.

## [0.4.0] — 2026-09-06

First public source release.
