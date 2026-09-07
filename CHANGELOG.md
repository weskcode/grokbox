# Changelog

All notable changes to Grokbox are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Setup runs the moment an account is added: it confirms the password was
  accepted, says what it found on the server, asks how much mail to look at
  and how tidy you want things, then indexes and reads while showing progress
  — and ends with what it found. Re-runnable from the account's context menu.
- An account that has never synced now says so in the sidebar and offers to
  get started, instead of showing an empty screen.
- In-app instructions for every provider's app password, with a button that
  opens the right page. Gmail, iCloud, Yahoo, Fastmail, Outlook and Proton,
  matched by provider or by server name.
- Per-sender overrides: tell Grokbox where one sender's mail goes regardless of
  your policy ("always bin this shop"), and whether it may ever be
  unsubscribed from automatically — in both directions, so a sender can be
  exempt under Thorough or opted in under Gentle.
- Cleanup settings: three named approaches (Gentle, Balanced, Thorough) plus
  individual dials. Choose where swept mail goes — filed into folders,
  archived, or moved to the provider's Trash — separately for promotions;
  protect recent mail and the newest few from each sender; and let Grokbox
  unsubscribe automatically from senders that clearly qualify. Every policy
  states in a sentence what it will do, above the Sweep button.
- UI tests for the phone app (tabs, swipe to Done, Undo, search, Sweep,
  Settings), run in CI on a simulator.
- A rules-only demo reader (`--stub-model`) so demos, screenshots and tests
  behave identically on machines where the on-device model cannot run.
- An iPhone and iPad app, sharing the same engine and store layout: the Brief
  with swipe-to-Done and swipe-to-Later, Senders with rules and unsubscribe,
  Sweep with per-sender toggles, Activity with Undo, Settings with export.
  Reads with Apple's on-device model; Ollama is a Mac-only option.
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
- The section switcher no longer draws a highlighted rectangle under the
  pointer. It was a segmented picker, whose segments light up individually on
  hover; it is now labelled buttons inside the toolbar's own glass capsule,
  so the only thing that moves under the pointer is the pointer.
- Mail whose value expires — verification codes, password resets, security
  alerts, delivery notices — no longer climbs the Brief as it ages. A
  three-month-old one-time code was ranking above a live question, because
  unanswered mail is scored as more pressing over time and nobody had told the
  scorer that some mail is worth nothing after a day. Found on a real mailbox.
- Removing an account left its sweep rules behind, so rules from a deleted
  demo mailbox could still apply to a real one.
- The Sweep button promised a message count that ignored the policy's own
  guards. It now previews them, so the number shown is the number that moves,
  and says how many are being held back.
- The phone's Sweep screen kept a plan built before indexing finished, so a
  full mailbox could read as "nothing to sweep".
- "Erase everything Grokbox knows" left the settings behind, including the
  cleanup policy.
- A model that failed on every message was reported as "nothing new to
  read". The tidy-up now says reading failed, and why, in plain words.
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
