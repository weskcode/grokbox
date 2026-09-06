# Privacy

"Private" is a claim. This document is the inventory that lets you check it.

## Every byte that leaves this Mac

| Destination | When | What | Can you turn it off? |
|---|---|---|---|
| **Your IMAP server** (e.g. `imap.gmail.com:993`) | Index, Read, Sweep, Tidy-up | IMAP commands. Credentials over TLS. Header and body reads are `PEEK`, so nothing is marked read by looking. | It is the product; remove the account. |
| **`127.0.0.1:11434`** (Ollama) | Read, if you chose Ollama | Subject, sender, and up to 3,000 characters of body text per message | Choose Apple's model instead, or none. Loopback only — the code refuses any other host. |
| **A sender's unsubscribe URL** | Only when *you* click Unsubscribe on that sender | An RFC 8058 POST to the HTTPS URL the sender put in their own `List-Unsubscribe` header | Do not click it. |

That is the complete list. The demo mailboxes run entirely inside the app's
process — there is no listening socket anywhere in the shipped app, and the
sandbox has no `network.server` entitlement to allow one. There is no telemetry, no crash reporter, no update
check, no analytics, no "anonymous usage statistics", no account with us. The
app has one network entitlement, `network.client`, and the sandbox refuses
anything else.

**Apple's on-device model** (Foundation Models framework) runs on the Neural
Engine and, per Apple, does not send data off-device. Grokbox cannot verify
that beyond Apple's documentation; if that is not good enough for you, use
Ollama, where the whole stack is open source.

## What is stored on this Mac

In the app's sandboxed container (`~/Library/Containers/com.wesleykeetch.grokbox/`):

- **Message headers**: sender, subject, date, flags, Message-ID, list headers.
- **Summaries**: the model's one-sentence summary and importance call, for
  messages the reader has processed.
- **Contacted addresses**: addresses you have sent to, learned from your Sent
  folder.
- **Rules and the action log**: your decisions and what Grokbox did with them.

In the macOS Keychain: your mail passwords, under service
`com.wesleykeetch.grokbox.imap`.

## What is never stored

- **Message bodies.** They are fetched for the reader pass (up to 8 KB each),
  turned into plain text in memory, handed to the model, and dropped. They do
  not touch disk. Search the codebase for `bodyExcerpt` — it is never assigned
  to a SwiftData property.
- **Attachments.** Never fetched at all.
- **Your password in the database.** Only a Keychain lookup key.

## What Grokbox will not do to your mail

- **Delete.** There is no code path that sets `\Deleted` or sends `EXPUNGE`.
  A test (`archiveSendsGmailLabelRemoval`) fails the build if one appears.
- **Send.** No SMTP anywhere.
- **Act without approval.** Sweeps run only on senders you approved in the
  Sweep screen. Tidy-up applies existing rules and never creates new ones.

## Verifying this yourself

```bash
# Every outbound host the app can name:
grep -rn "URL(string\|NWEndpoint.Host\|https://" GrokboxCore/Sources | grep -v "^.*//"

# Prove there is no delete path:
grep -rni "deleted\|expunge" GrokboxCore/Sources ; echo "(should print nothing)"

# Watch it on the wire:
sudo tcpdump -i any -n "not port 993 and not host 127.0.0.1" &
```
