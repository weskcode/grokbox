# Provider API decision

Status: decided 2026-10-21. Keep IMAP behind `MailProvider`. Do not build a
Gmail API or Microsoft Graph backend.

This record answers phase 4B of the inbox-zero update plan: does a measured
IMAP limitation justify a Gmail or Microsoft API backend? It separates what was
reproduced at `bae8b57` from what ADR-0002, the `MailProvider` doc comment and
the September audit asserted.

## Decision

No measured limitation needs a provider API. Two problems are real:

- Grokbox cannot sign in to Outlook.com or Exchange Online. Its only sign-in
  method, IMAP `LOGIN`, is turned off there. This is an authentication gap, not
  an IMAP gap. The fix is OAuth 2.0 over the existing IMAP code (`AUTHENTICATE
  XOAUTH2`), not Graph.
- Incremental sync misses changes made in other clients. This is a client gap.
  Plain IMAP commands that every server supports can close it.

Either fix keeps the single IMAP code path, adds no server, and adds no
restricted Google scope.

## What was measured

| Claim | Source of claim | Result at `bae8b57` | Evidence |
|---|---|---|---|
| Gmail API `batchModify` moves 1,000 messages where IMAP "needs a slow walk" | ADR-0002, `MailProvider.swift` doc comment, ROADMAP v0.8 | Out of date. `IMAPClient.uidChunks` sends 500 UIDs per `UID STORE` or `UID MOVE`. Archiving 1,000 Gmail messages takes 2 commands. Filing them into a label takes 4, because `PlanExecutor` adds the label and removes `\Inbox` in separate steps. `batchModify` does either in 1 call. These are calculated command counts, not timings. | Probe `roundTripCountsForBulkWork`; `IMAPClient.swift` `uidChunks`; `PlanExecutor.swift` `.fileIntoFolders` |
| Gmail API `history.list` gives true incremental sync | ADR-0002 | Reproduced as a gap in Grokbox's client, not in IMAP. See [Incremental sync](#incremental-sync). | Probe `changesElsewhereAfterIncrementalSync` |
| Incremental sync has no delete path | September audit GB-012 | Still true. A message deleted in another client stays indexed after an incremental pass. | Same probe |
| Microsoft is phasing out password IMAP | `SETUP-ACCOUNTS.md`, `CredentialGuide.swift` | Already complete. `outlook.office365.com` and `imap-mail.outlook.com` advertise `LOGINDISABLED` and only `AUTH=XOAUTH2`. Grokbox only sends `LOGIN`, which RFC 3501 forbids under `LOGINDISABLED`. Microsoft's published policy says the same. No login was attempted, and on-premises Exchange servers were not checked. | Pre-login `CAPABILITY`, no credentials sent; [Exchange Online basic auth deprecation](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-basic-authentication-exchange-online); [Outlook.com modern auth](https://support.microsoft.com/en-us/support/known-issues/modern-authentication-methods-now-needed-to-continue-syncing-outlook-email-in-non-microsoft-email-ap) |
| Gmail App Passwords may be withdrawn | ADR-0002, `SETUP-ACCOUNTS.md` | Still available. `imap.gmail.com` advertises `AUTH=PLAIN`. Google still documents App Passwords for accounts with 2-Step Verification, as "not recommended". | Pre-login `CAPABILITY`; [Google: Sign in with app passwords](https://support.google.com/accounts/answer/185833) |

The probe and capability logs live in the unit 12 result directory of the
inbox-zero orchestration run, not in the repo. The probe is a temporary Swift
Testing suite run against the in-process `DemoMailbox` (Gmail flavor, the
`neglected` persona). It sends no network traffic.

### Incremental sync

`SyncEngine.indexIncrementally` fetches new UIDs above the stored high-water
mark, then refreshes flags for the newest 300 messages by sequence number
(`flagRefreshWindow`). Anything older is not checked until the next full index.

The probe indexed 2,289 messages, then changed four of them the way another
client would, and ran an incremental pass:

| Change made elsewhere | After incremental pass | After full index |
|---|---|---|
| Archived an old inbox message (removed `\Inbox`) | Still shown in the inbox | Corrected |
| Read an old unread message | Still unread | Corrected |
| Deleted an old message (moved to Trash) | Still indexed | Removed |
| Read the newest unread message | Corrected | Corrected |

The full index corrected all three stale records in this run. That shows IMAP
already returns the right state and the client does not ask for it often
enough. It does not show that a full index always converges. `indexFully`
returns early for an empty mailbox, keeps rows below the lowest UID it saw, and
leaves rows older than its walk limit alone. Two standard commands cover the gap without
any extension:

- `UID SEARCH ALL` returns every UID in the mailbox. Comparing it with the
  stored UIDs finds removals.
- `UID FETCH 1:* (UID FLAGS)`, plus `X-GM-LABELS` on Gmail, returns flags for
  every message without headers. It is a few dozen bytes per message.

`CONDSTORE` (RFC 7162) would make the flags refresh cheaper still. Google's
[IMAP extensions page](https://developers.google.com/workspace/gmail/imap/imap-extensions)
does not list it, and capabilities after login were not checked, so treat it as
optional.

## What `MailProvider` assumes today

`MailProvider` is the only seam, and `IMAPMailProvider` is its only production
implementation. `DemoMailProvider` backs demo accounts. The protocol covers
mailbox discovery, read-only and read-write open, header fetch by sequence
range or from a UID, flag fetch by sequence range, a body excerpt, IMAP `IDLE`,
flag and Gmail label stores, move, mailbox creation, `finish` and `abort`.

Its types are IMAP types, not neutral ones:

- `capabilities` returns `IMAPCapabilities`.
- Messages are addressed by `UInt32` UID and by sequence number.
- `move` returns a `MoveResult` built from `COPYUID`, which undo relies on.
- `setFlags` and `setGmailLabels` take `IMAPClient.FlagChange`.
- `SyncEngine` stores `UIDVALIDITY` and a highest-UID watermark per mailbox
  in `MailboxSnapshot`, and `PlanExecutor` stores UIDs on `CleanupAction`.

A REST backend would need its own message identity (Gmail and Graph use string
ids), its own sync cursor (`historyId` or a delta link) and its own undo
mapping. That changes the protocol, `MailboxSnapshot` and `CleanupAction`, so it
is an API and persistence change, not a swap behind the seam.

## Alternatives

| | IMAP, current | IMAP with OAuth (`XOAUTH2`) | Gmail API | Microsoft Graph |
|---|---|---|---|---|
| Providers | Any IMAP server, Proton via Bridge | Adds Outlook.com and Microsoft 365; optional for Gmail | Gmail only | Outlook.com and Microsoft 365 only |
| Scopes | None | Microsoft: `https://outlook.office.com/IMAP.AccessAsUser.All`, `offline_access`. Gmail: `https://mail.google.com/` | `gmail.modify` for labels and `batchModify`; `history.list` also needs a restricted scope | `Mail.ReadWrite` delegated, no admin consent required |
| Scope class | n/a | Gmail `https://mail.google.com/` is restricted. Microsoft IMAP scope has no Google-style assessment | Every Gmail read or sync scope is restricted | Not restricted |
| Verification | None | Microsoft: an Entra app registration. Publisher verification is optional but needed where a tenant only allows consent to verified publishers. It is free and needs a Microsoft AI Cloud Partner Program account | Restricted-scope verification for any public release. A CASA security assessment applies if restricted data is stored on or sent through a server, which includes a third-party server. Unverified apps stop at 100 users for the life of the project | As for XOAUTH2 |
| Recurring cost | None | None | If assessed: every 12 months, paid by the developer to the assessor. Projects created on or after May 1, 2026 also face an 80,000,000-unit daily project threshold, with billing details not yet published | None documented |
| Hosting | None | None; a native public client needs no secret | None | None |
| New code | None | SASL `AUTHENTICATE`, token refresh, Keychain token storage, sign-in sheet | A second provider: REST client, label model, history sync, quota handling | A second provider: REST client, folder model, delta sync, throttling |
| Initial index, 5,000 messages | 20 header `FETCH` commands | Same | About 100,000 quota units (`messages.get` at 20 units each). Under the quota for projects created on or after May 1, 2026, 6,000 units per user per minute, that is at least 17 minutes | `messages/delta` pages; 10,000 requests per 10 minutes per mailbox |

Sources:

- [Choose Gmail API scopes](https://developers.google.com/workspace/gmail/api/auth/scopes)
- [Restricted scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification)
- [Gmail API usage limits](https://developers.google.com/workspace/gmail/api/reference/quota)
- [`users.history.list`](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.history/list)
- [Authenticate an IMAP, POP or SMTP connection by using OAuth](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth)
- [Deprecation of Basic authentication in Exchange Online](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-basic-authentication-exchange-online)
- [Modern authentication now needed for Outlook.com in other apps](https://support.microsoft.com/en-us/support/known-issues/modern-authentication-methods-now-needed-to-continue-syncing-outlook-email-in-non-microsoft-email-ap)
- [Microsoft Graph permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference)
- [Microsoft Graph throttling limits](https://learn.microsoft.com/en-us/graph/throttling-limits)
- [Publisher verification](https://learn.microsoft.com/en-us/entra/identity-platform/publisher-verification-overview)

For Grokbox's main read path, the Gmail API looks worse on paper. Header
indexing costs one `messages.get` per message under a per-user quota, while
IMAP fetches 250 headers per command. This is a quota estimate; no real-account
timing was taken. The API's one clear advantage, `history.list`, needs a
restricted scope. The standard IMAP commands above should reach the same state
without one.

The Gmail API also collides with an existing feature. The opt-in Jev fallback
(ADR-0023, `PRIVACY.md`) sends a sender's address and subject lines to
`api.typesafe.ai`. If those came from a restricted Gmail scope, restricted data
would pass through a third-party server, which is the case Google's security
assessment covers. Having no Grokbox server is not enough to avoid it.

Graph has no Google-style assessment, but it reaches only Microsoft accounts,
which `XOAUTH2` over IMAP also reaches. A second backend would double the
mutation, undo and Stop paths that `PlanExecutor` and the safety suites cover
today.

## Follow-ups

None of these is started. Each needs its own task.

1. **Incremental reconciliation over IMAP.** Add a removal check and a
   whole-mailbox flags refresh to `SyncEngine.indexIncrementally`, and cover
   the empty-mailbox and lowest-UID cases in `indexFully`. No auth, schema or
   dependency change. Cost per pass on a 40,000-message mailbox
   needs measuring before choosing how often to run it.
2. **Microsoft sign-in through `XOAUTH2`.** Needs named approval for auth, an
   Entra app registration, a publisher verification decision, a new outbound host
   (`login.microsoftonline.com`) in `PRIVACY.md`, token storage in the
   Keychain, and a sign-in UI design. Choose between `ASWebAuthenticationSession`
   (no dependency) and MSAL (a dependency) before design.
3. **Correct the Outlook guidance.** `SETUP-ACCOUNTS.md` and the Outlook entry
   in `CredentialGuide.swift` say an app password still works. Microsoft's
   servers advertise `LOGINDISABLED` and Microsoft documents password access as
   retired, so the guidance should say Outlook cannot be added until follow-up
   2 ships.
4. **Mark ADR-0002's `batchModify` comparison as out of date** when ADR-0002 is
   next revised.

## What would change this decision

- Google withdraws App Passwords for consumer Gmail and `AUTH=PLAIN` stops
  working. Then Gmail needs OAuth over IMAP, which uses the restricted
  `https://mail.google.com/` scope and faces the same verification question as
  the Gmail API.
- A measured workload where whole-mailbox reconciliation over IMAP is too slow
  or is throttled on a real account.
- A product decision to process mail while the app is closed. That needs a
  server, which no option here provides.
