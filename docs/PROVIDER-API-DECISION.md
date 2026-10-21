# Provider API decision

Status: decided 2026-10-21. Keep IMAP behind `MailProvider`. Do not build a
Gmail API or Microsoft Graph backend.

This record answers phase 4B of the inbox-zero update plan: does a measured
IMAP limitation justify a Gmail or Microsoft API backend? It separates what was
reproduced at `bae8b57` from what ADR-0002, the `MailProvider` doc comment and
the September audit asserted.

## Decision

No measured limitation needs a provider API. Two problems are real:

- Microsoft accounts cannot sign in at all. This is an authentication gap, not
  an IMAP gap. The fix is OAuth 2.0 over the existing IMAP code (`AUTHENTICATE
  XOAUTH2`), not Graph.
- Incremental sync misses changes made in other clients. This is a client gap.
  Plain IMAP commands that every server supports can close it.

Either fix keeps the single IMAP code path, adds no server, and adds no
restricted Google scope.

## What was measured

| Claim | Source of claim | Result at `bae8b57` | Evidence |
|---|---|---|---|
| Gmail API `batchModify` moves 1,000 messages where IMAP "needs a slow walk" | ADR-0002, `MailProvider.swift` doc comment, ROADMAP v0.8 | Out of date. `IMAPClient.uidChunks` sends 500 UIDs per `UID STORE` or `UID MOVE`, so 1,000 messages take 2 commands. `batchModify` takes 1 call of 1,000 ids. | Probe `roundTripCountsForBulkWork`; `IMAPClient.swift` `uidChunks` |
| Gmail API `history.list` gives true incremental sync | ADR-0002 | Reproduced as a gap in Grokbox's client, not in IMAP. See [Incremental sync](#incremental-sync). | Probe `changesElsewhereAfterIncrementalSync` |
| Incremental sync has no delete path | September audit GB-012 | Still true. A message deleted in another client stays indexed after an incremental pass. | Same probe |
| Microsoft is phasing out password IMAP | `SETUP-ACCOUNTS.md`, `CredentialGuide.swift` | Already complete. `outlook.office365.com` and `imap-mail.outlook.com` advertise `LOGINDISABLED` and only `AUTH=XOAUTH2`. Grokbox only sends `LOGIN`, which RFC 3501 forbids under `LOGINDISABLED`. No login was attempted. | Pre-login `CAPABILITY`, no credentials sent |
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

A full index converges. So IMAP already returns the right state; the client
does not ask for it often enough. Two standard commands cover the gap without
any extension:

- `UID SEARCH ALL` returns every UID in the mailbox. Comparing it with the
  stored UIDs finds removals.
- `UID FETCH 1:* (UID FLAGS)`, plus `X-GM-LABELS` on Gmail, returns flags for
  every message without headers. It is a few dozen bytes per message.

`CONDSTORE` (RFC 7162) would make the flags refresh cheaper still. Google's
[IMAP extensions page](https://developers.google.com/workspace/gmail/imap/imap-extensions)
does not list it, and capabilities after login were not checked, so treat it as
optional.

## Alternatives

| | IMAP, current | IMAP with OAuth (`XOAUTH2`) | Gmail API | Microsoft Graph |
|---|---|---|---|---|
| Providers | Any IMAP server, Proton via Bridge | Adds Outlook.com and Microsoft 365; optional for Gmail | Gmail only | Outlook.com and Microsoft 365 only |
| Scopes | None | Microsoft: `https://outlook.office.com/IMAP.AccessAsUser.All`, `offline_access`. Gmail: `https://mail.google.com/` | `gmail.modify` for labels and `batchModify`; `history.list` also needs a restricted scope | `Mail.ReadWrite` delegated, no admin consent required |
| Scope class | n/a | Gmail `https://mail.google.com/` is restricted. Microsoft IMAP scope has no Google-style assessment | Every Gmail read or sync scope is restricted | Not restricted |
| Verification | None | Microsoft: publisher verification, free, needs a Microsoft AI Cloud Partner Program account and a work or school tenant | Restricted-scope verification. CASA security assessment only if data is stored on or passes through servers; Google does not state an exemption for on-device apps. Unverified apps stop at 100 users for the life of the project | Publisher verification, as for XOAUTH2 |
| Recurring cost | None | None | If assessed: every 12 months, paid by the developer to the assessor | None documented |
| Hosting | None | None; a native public client needs no secret | None | None |
| New code | None | SASL `AUTHENTICATE`, token refresh, Keychain token storage, sign-in sheet | A second provider: REST client, label model, history sync, quota handling | A second provider: REST client, folder model, delta sync, throttling |
| Initial index, 5,000 messages | 20 header `FETCH` commands | Same | About 100,000 quota units (`messages.get` at 20 units each). At 6,000 units per user per minute that is about 17 minutes | `messages/delta` pages; 10,000 requests per 10 minutes per mailbox |

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

The Gmail API is slower than IMAP for Grokbox's main read path. Header
indexing costs one `messages.get` per message under a per-user quota, while
IMAP fetches 250 headers per command. Its one clear advantage, `history.list`,
needs a restricted scope and may need a recurring paid assessment. The
standard IMAP commands above get the same convergence.

Graph has no Google-style assessment, but it reaches only Microsoft accounts,
which `XOAUTH2` over IMAP also reaches. A second backend would double the
mutation, undo and Stop paths that `PlanExecutor` and the safety suites cover
today.

## Follow-ups

None of these is started. Each needs its own task.

1. **Incremental reconciliation over IMAP.** Add a removal check and a
   whole-mailbox flags refresh to `SyncEngine.indexIncrementally`. No auth,
   schema or dependency change. Cost per pass on a 40,000-message mailbox
   needs measuring before choosing how often to run it.
2. **Microsoft sign-in through `XOAUTH2`.** Needs named approval for auth, an
   Entra app registration and publisher, a new outbound host
   (`login.microsoftonline.com`) in `PRIVACY.md`, token storage in the
   Keychain, and a sign-in UI design. Choose between `ASWebAuthenticationSession`
   (no dependency) and MSAL (a dependency) before design.
3. **Correct the Outlook guidance.** `SETUP-ACCOUNTS.md` and the Outlook entry
   in `CredentialGuide.swift` say an app password still works. Microsoft's
   servers refuse `LOGIN`, so the guidance should say Outlook cannot be added
   until follow-up 2 ships.
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
