# Landscape — what the open-source mail clients do, and what Grokbox takes from them

Written 2026-09-06 from the projects' own sources and documentation. Where a
claim could be read from a repository or an official page it is marked
**(source)**; where it comes from long familiarity with the product and was
not re-verified today it is marked *(from memory)*. Grokbox is a triage tool,
not a mail client; the point of this study is to borrow what serves triage,
name what is out of scope, and not reinvent conventions the whole ecosystem
already shares.

## The clients

| Client | License | Platforms | Character |
|---|---|---|---|
| **Thunderbird** (mozilla/releases-comm-central) | MPL 2.0 | macOS, Windows, Linux | The reference open-source client since 2003; adaptive junk filter, message filters, autoconfig, OAuth2 for major providers, OpenPGP built in. **(source)** |
| **Betterbird** | MPL 2.0 | same | Thunderbird plus decades of unlanded fixes: regex search, diacritic-insensitive search, search inside encrypted mail, multi-line list, account colours. **(source)** |
| **Thunderbird for Android / K-9 Mail** (thunderbird/thunderbird-android) | Apache 2.0 | Android | Autodiscovery, IMAP IDLE push, unified inbox, OpenPGP via plugin, clear ADR/RFC engineering process worth imitating. **(source)** |
| **FairEmail** (M66B/FairEmail) | GPL 3 | Android | The privacy maximalist: confirms before showing images or opening links, recognises tracking images, strips tracking parameters, reformats messages to defeat phishing, no third-party servers, no FCM. Rules engine and snooze. **(source)** |
| **Mailspring** (Foundry376/Mailspring) | GPL 3 | macOS, Windows, Linux | Electron UI over a C++ sync engine; unified inbox, snooze, send later, mail rules, templates, Gmail-style search; Pro adds read receipts and link tracking (of *your* sent mail). Credentials stay local. **(source)** |
| **Proton Mail** (ProtonMail/WebClients, proton-bridge) | GPL 3 | web, desktop, mobile; IMAP via Bridge | End-to-end encrypted service; open-source clients; Bridge exposes local IMAP/SMTP and verifies its own updates by signature. Filters, labels, folders, tracker protection are service features. **(source: repos)** *(features: from memory)* |
| **Tuta** (tutao/tutanota) | GPL 3 | web, desktop, mobile | End-to-end encrypted; no IMAP by design; notably refuses LLM-assisted contributions. **(source)** |
| Geary, Evolution (GNOME) | LGPL/GPL | Linux | Conversation-first (Geary) and groupware (Evolution). *(from memory; not studied in depth — Linux-only and not where the owner's mail lives)* |

## What they all share, and Grokbox now does too

### 1. Account setup by discovery, in the same order
Thunderbird's sequence **(source: wiki)**: a config file on disk → the provider's
`autoconfig.<domain>/mail/config-v1.1.xml` → Mozilla's ISPDB
(`autoconfig.thunderbird.net/v1.1/<domain>`) → guessing `imap.<domain>` and
probing → manual. K-9 and FairEmail follow the same ladder. The XML format
**(source: wiki)** carries `hostname`, `port`, `socketType` (plain / SSL /
STARTTLS), `username` with `%EMAILADDRESS%` / `%EMAILLOCALPART%` placeholders,
and one or more `authentication` values (`OAuth2`, `password-cleartext`, …).
The real ISPDB answer for gmail.com **(source: fetched)** offers IMAP
`imap.gmail.com:993 SSL` with `OAuth2` and `password-cleartext`.

**Grokbox:** `AutoconfigService` implements the ladder minus the on-disk file,
speaks the same XML, resolves the placeholders, refuses `plain`, and reports
STARTTLS-only providers rather than downgrading. It sends **only the domain**,
never the address, and only when the user presses *Look up settings*. A
loopback test asserts the address never appears in any request. This is the
fourth and final kind of outbound connection in the app (PRIVACY.md).

### 2. OAuth2 for the big providers — and how open source ships it
Thunderbird's `OAuth2Providers.sys.mjs` **(source: fetched)** lists Google,
Microsoft, Yahoo, AOL, Fastmail, Yandex, Mail.ru, Comcast, and its own
`auth.tb.pro`, requests `https://mail.google.com/` for Gmail, and **embeds its
Google client ID and secret in the source**, with the comment that dynamic
client registration is not yet supported. So "an open-source app cannot ship
OAuth credentials" — the premise behind ADR-0002's caution — is not the
ecosystem's practice. What it cannot avoid is Google's *verification* of the
project that owns the client ID.

**Grokbox:** ADR-0002 stands for now (App Passwords work, no gatekeeper), but
the path forward is clarified: register a Grokbox client, get it verified,
ship the ID in source like Thunderbird does. Autoconfig already records
whether a provider offers OAuth2 so the UI can say so.

### 3. Filters and rules
Thunderbird's filter actions **(source: `nsMsgFilterCore.idl`)**: move, copy,
change priority, delete, mark read/unread, flag, kill/watch thread, reply,
forward, stop, junk score, add tag, custom. Triggers: manual, incoming,
*after* junk classification, before archiving, periodic. FairEmail and
Mailspring have comparable rule engines; Proton has a filter builder over
Sieve *(from memory)*.

**Grokbox:** deliberately sender-level rules plus category folders, because the
owner's problem is volume, not routing. The one Thunderbird idea worth
stealing is *ordering*: junk classification runs **before** filters. Grokbox's
sweep guard already runs before archiving; a future "condition rules" layer
(subject contains → folder) belongs on the roadmap, not in v0.4.

### 4. Junk learning
Thunderbird's adaptive junk filter is a token-based Bayesian classifier trained
by the user marking Junk / Not Junk, with address books as an allow-list and
optional deference to server-side spam headers *(from memory; the support
page would not render today)*.

**Grokbox:** the same shape exists at the sender level — approve a sweep and
it sticks — but no per-message learner. A local Bayesian tier between the
heuristics and the model is a natural v0.6: private, instant, and it would
absorb the "Review" bucket over time.

### 5. Privacy defaults around content
FairEmail **(source: README)**: confirm before images, confirm before links,
recognise tracking images, safe view that strips styling/scripting/unsafe
HTML, reformat to prevent phishing. Thunderbird blocks remote content by
default with a per-sender allow-list *(from memory)*. Proton removes trackers
*(from memory)*.

**Grokbox:** stronger by construction — it **never renders HTML**, so pixels
and scripts cannot run — and now also does the one thing rendering-free
clients can still do: `LinkHygiene` inspects the body excerpt the reader
already fetches and flags the classic tells: link text that shows one domain
but goes to another, punycode look-alike hosts, bare-IP links, and
"act now" mail that never links back to the sender's own domain. Warnings
appear on the Brief row.

### 6. Snooze, unified inbox, search
Mailspring, FairEmail, and Proton snooze **(source)**; every client has a
unified inbox; Betterbird adds regex and diacritic-insensitive search
**(source)**. Grokbox has Later (snooze), the cross-account Brief, and a
sender filter. A message search over indexed subjects/senders is cheap and
on the roadmap.

### 7. Engineering practice worth copying
K-9's repository keeps ADRs and RFCs in-tree **(source)** — Grokbox already
does (docs/DECISIONS.md). Tuta's refusal of LLM-assisted contributions is a
policy stance, not a technical one; noted, not adopted.

## Out of scope, on purpose
Composing and sending, OpenPGP/S-MIME, calendars and contacts, POP3, Exchange,
tabs and layouts, add-ons. Grokbox reads, sorts, and files; it is meant to sit
beside a client, not replace one.

## Adopted in this pass
- `AutoconfigService` (Thunderbird ladder, ISPDB, domain-only)
- `LinkHygiene` (phishing tells on the Brief)
- ADR-0002 annotated with the OAuth finding

## Roadmap additions from this study
- Condition rules (subject / list-id → folder), ordered after the guard
- Local Bayesian junk tier trained by sweeps and keeps
- Message search over the index; diacritic-insensitive like Betterbird
- IMAP IDLE to trigger tidy-ups on arrival
- A verified OAuth2 client, shipped in source
