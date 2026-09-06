# Grokbox — Privacy Guides standards audit

**Date:** 2026-09-06 · **Revision audited:** working tree, pre-first-commit · **Auditor:** the maintainer (self-audit; affiliation disclosed)
**Categories applied:** *Email Clients* (primary), *AI Chat* (the on-device summariser), plus General, Self-submission, Data-handling and Security rows from the skill checklist
**Criteria revision:** privacyguides.org @ 95f8513 (2026-09-03)

## Verdict

**Meets minimum with notes** for *Email Clients*. **Does not meet minimum** for
*AI Chat* on one row: it is macOS-only and that category requires multi-platform.

No telemetry, no account, no vendor server, open source, sandboxed, Keychain,
TLS-only to remote hosts, zero dependencies — all evidenced in code, not just
claimed. The notes are: Apple's on-device model is a closed platform dependency with an
open-source alternative (C2 PARTIAL), and releases are not yet signed (D3,
pre-release). The single highest-leverage fix is **D3**: a signed, checksummed
first release.

## Threat model

Stated by the project in `docs/THREAT-MODEL.md` in Privacy Guides' taxonomy; checked here.

| Threat | Project claims | Auditor finds |
|---|---|---|
| Service providers | Protected: no vendor service exists | Confirmed. No outbound host in the code other than user-configured IMAP, loopback Ollama, and user-clicked unsubscribe URLs. |
| Surveillance capitalism | Protected | Confirmed. No analytics/telemetry SDK (grep: none); entitlements are sandbox + `network.client` only. |
| Passive attacks | Protected to the extent of TLS | Confirmed. `IMAPConnection.swift:48,86` refuses plaintext/self-signed for any non-loopback host. No ATS exceptions in `Info.plist`. |
| Mass surveillance | Partly; provider is the lever | Accurate and honest. |
| Targeted attacks | Partly; sandbox + Keychain + link hygiene | Confirmed. `KeychainStore.swift`; `LinkHygiene.swift` flags domain mismatch, IP-literal hosts, account-mail phrasing. |
| Supply chain | Partly; zero deps, no signing yet | Confirmed. `Package.swift` has no external dependencies. No signed tags or checksums exist yet. |
| Public exposure | N/A | Agreed. |
| Anonymity | Not provided | Correctly disclaimed. |
| Censorship | N/A | Agreed. |

## Findings

| ID | Check | Result | Evidence | Remediation |
|---|---|---|---|---|
| A1 | Open source, recognised licence | PASS | `LICENSE` GPL-3.0 | — |
| A2 | Actively developed | PASS | daily commits Sep 2026; single maintainer (risk noted) | — |
| A3 | Cross-platform or gap stated | PARTIAL | macOS-only; stated in README | Not planned; native SwiftUI/SwiftData/Foundation Models are the point. |
| A4 | Usable without technical background | PARTIAL | Requires building from source until first release | First tagged release with a notarised `.app`. |
| A5 | Documentation | PASS | README, ARCHITECTURE, PRIVACY, THREAT-MODEL, SECURITY, DECISIONS (18 ADRs), SETUP-ACCOUNTS | — |
| A7 | No financial conflict | PASS | No funding, no sponsors, no affiliate links | — |
| B1 | Affiliation disclosed | PASS | README "built by one person (Wesley Keetch)" | — |
| B2 | Security white paper | PASS | `SECURITY.md` + `docs/PRIVACY.md` byte inventory | — |
| B3 | Audit status stated | PASS | `SECURITY.md`: "None has been performed or requested." | — |
| B4 | Privacy benefit vs alternatives | PASS | README; `docs/LANDSCAPE.md` compares Thunderbird and others | — |
| B5 | Exact threat model in PG vocabulary | PASS | `docs/THREAT-MODEL.md` | — |
| C1 | No telemetry | PASS | grep for analytics/telemetry/crash/sparkle SDKs: none; entitlements; `docs/PRIVACY.md` states none | — |
| C2 | Does not transmit personal data | PARTIAL | Mail content goes to Apple Foundation Models (closed, on-device per Apple) or loopback Ollama (`OllamaProvider.swift:22` refuses non-loopback). Cannot verify Apple's claim from outside. | Keep Ollama path first-class; state the caveat (done in THREAT-MODEL). |
| C3 | No developer account required | PASS | first-run adds an IMAP account only | — |
| C4 | Works offline | PARTIAL | Brief, Senders, Activity, Digest work offline on the local index; Index/Sweep need the mail server by nature | Category-appropriate; note only. |
| C5 | No unencrypted data outside device | PASS | No sync, no cloud | — |
| C6 | Local data protected | PASS | Keychain for passwords; sandbox container for the index; Erase Everything in Settings | Index is not encrypted at rest beyond FileVault — state it (done in PRIVACY). |
| C7 | Easy export of user data | PASS | Settings → Your data → Export: accounts (no passwords), rules, action log, digests as JSON; rules re-importable (`DataExport.swift`) | — |
| C8 | Privacy policy accurate and complete | PASS | `docs/PRIVACY.md` lists every endpoint found in C2 | Re-check on every PR that adds a request (CONTRIBUTING rule). |
| D1 | TLS with validation, no remote downgrade | PASS | `IMAPConnection.swift` loopback-only exception | — |
| D2 | Updates | PARTIAL | None; stated in SECURITY.md | Acceptable for a no-phone-home tool; consider a manual "check GitHub" link. |
| D3 | Release verification | **FAIL** (pre-release) | No tags, checksums, signing | Roadmap in SECURITY.md items 2–4. |
| D4 | Signed commits/tags | PASS | SSH-signed commits from the second commit on; `.allowed_signers` in repo | — |
| D5 | Minimal, pinned dependencies | PASS | zero third-party | — |
| D6 | Security contact | PASS | `SECURITY.md` | — |
| D7 | Network input untrusted | PASS | Link hygiene; prompt injection bounded (model has no tools); unsubscribe POST refuses non-HTTPS, loopback, private and link-local targets and follows at most one redirect under the same rule (`PublicHostPolicy.swift`, tested) | — |
| D8 | Least privilege | PASS | sandbox + `network.client` only | — |
| E-EC1 | Email Clients: open source on open-source OS | N/A | macOS | — |
| E-EC2 | Email Clients: no telemetry / disable-able | PASS | see C1 | — |
| E-EC3 | Email Clients: OpenPGP support | N/A with note | Grokbox does not compose or display mail bodies as a client; PGP-encrypted messages are opaque to the summariser and are surfaced by subject/sender only. | State in README (done in THREAT-MODEL). |
| E-EC-best | cross-platform / native PGP / local encrypted store | FAIL / N/A / N/A | | Ranking only. |
| E-AI1 | AI Chat: open source | PASS (app) / PARTIAL (Apple model) | | Ollama path is fully open. |
| E-AI2 | AI Chat: no personal data transmitted | PASS | loopback-only | — |
| E-AI3 | AI Chat: multi-platform | **FAIL** | macOS-only | Not planned. |
| E-AI4 | AI Chat: no GPU required | PASS | Apple model on Neural Engine; Ollama CPU-capable | — |
| E-AI5 | AI Chat: no internet required | PASS | | — |
| E-AI-best | model downloader / adjustable params | FAIL / FAIL | | Ranking only. |

## Every byte that leaves the device

| Destination | Trigger | Payload | User control |
|---|---|---|---|
| User's IMAP server (TLS) | Index, Read, Sweep, Tidy-up | IMAP commands; `EXAMINE`/`BODY.PEEK` reads; `STORE`/labels only in Sweep and Undo | Remove the account |
| `127.0.0.1:11434` (Ollama) | Read, if chosen | subject, sender, ≤3,000 chars of body | Choose Apple's model or none |
| Sender's own `List-Unsubscribe` URL (HTTPS) | Only on clicking Unsubscribe | RFC 8058 POST, `List-Unsubscribe=One-Click` | Don't click |

## Unverified

- Apple Foundation Models' on-device claim (platform assertion; not testable from userland).
- CI workflow (`.github/workflows/ci.yml`) has not run; the runner image name is a best guess.
- Behaviour against a live IMAP server (Gmail, Proton Bridge) — never exercised.

## Attribution

Criteria © Privacy Guides contributors, CC BY-SA 4.0. This report is not affiliated with or endorsed by Privacy Guides.
