# Application understanding

## What it is

**Grokbox** is a local-first email *triage* tool for macOS. It is explicitly not a mail
client: it does not compose, send, or render messages, and it never deletes.

It connects to IMAP mailboxes, indexes **headers only**, collapses them into per-sender
profiles, classifies each sender into a category (People / Receipts / Notifications /
Newsletters / Promotions), recommends what to do about each one, files bulk mail into
category folders on the server, and uses an **on-device** language model to summarise
recent mail and say what actually needs the user's attention.

## Who it is for

One user with ADHD and a large email backlog spread over Proton and several Gmail accounts.
The design brief, stated by the owner and visible throughout the code, is:

- 100% private — nothing leaves the machine except IMAP to the user's own server
- Organising must be **meaningful and explainable**, "not AI slop"
- **Never delete.** "Get rid of it" means unsubscribe + file + a rule
- Bounded, finishable lists rather than an infinite feed

## Primary user goals

1. *"How bad is it, right now?"* → the **Where things stand** digest (⌘⇧S), computed
   deterministically from counts, kept with a timestamp, copyable.
2. *"What do I have to do?"* → the **Brief**: **Now** (three items, then stop),
   **Quick wins**, **Then**, with *Worth knowing* collapsed. Every row explains why it
   is ranked where it is.
3. *"Make the noise go away."* → **Senders** (one row per sender with a plain
   recommendation and its evidence) and **Sweep** (a reviewable plan grouped by
   destination folder, applied in one action, with a guard that holds back flagged,
   needs-you and receipt-like messages).
4. *"Undo what it did."* → **Activity**, every action with Undo.
5. *"Keep it clean."* → **Tidy up**, on demand or on a timer, which applies only rules
   the user has already approved.

## What successful usage looks like

A first run indexes the mailbox, files a few thousand bulk messages into named folders,
leaves a two-figure inbox, and presents at most three things to do. A week later the user
opens the menu bar, reads one sentence, and closes it again.

## Assumptions that require verification

- That the hand-written IMAP client survives contact with a real Gmail/Proton/Dovecot
  server. **Unverified — no live account was connected.**
- That on-device reading is fast enough to be usable on a 40 000-message backlog.
  **Partially verified: ~2–10 s per message, capped per pass; a 3-account run with reading
  took 4–10 minutes.**
- That the user trusts it enough to let it write to a real mailbox. Every mutation is
  reversible and logged, which is the right structural answer, but trust is earned in use.
