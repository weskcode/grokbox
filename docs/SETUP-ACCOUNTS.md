# Setting up accounts

## Gmail

Gmail will not accept your normal Google password over IMAP. You need an
**App Password**.

1. Turn on 2-Step Verification for the Google account (required — App Passwords
   do not exist without it).
2. Go to your Google Account → Security → App passwords.
3. Generate one. You get 16 characters, usually shown in four groups.
4. In Grokbox: Add Account → Gmail, enter the address, paste the App Password.
   Spaces are fine.

Settings are filled in automatically: `imap.gmail.com`, port 993, TLS.

Repeat per inbox — each Gmail account is a separate Grokbox account.

**A note on longevity:** Google has periodically signalled it wants to retire
App Passwords in favour of OAuth. If yours stops working, that is why, and
ADR-0002 covers the alternative.

### If it fails to connect

Gmail can require that IMAP be enabled: Gmail → Settings → Forwarding and
POP/IMAP → Enable IMAP.

## iCloud Mail

1. Turn on two-factor authentication for the Apple Account.
2. Go to account.apple.com → Sign-In and Security → App-Specific Passwords → generate one.
3. In Grokbox: Add Account → Other IMAP. Server `imap.mail.me.com`, port 993, TLS.
   Username is the full iCloud address; password is the app-specific password.

## Outlook.com / Microsoft 365

Microsoft is phasing out password sign-in for IMAP in favour of OAuth, which
Grokbox does not implement yet. If your account still allows an app password
(Security → Advanced security options → App passwords), use: server
`outlook.office365.com`, port 993, TLS, Other IMAP.

## Yahoo Mail

Account Security → Generate app password. Server `imap.mail.yahoo.com`, port
993, TLS, Other IMAP.

## Fastmail

Settings → Privacy & Security → Third-party apps → New app password, scoped to
Mail. Server `imap.fastmail.com`, port 993, TLS, Other IMAP.

## Any other IMAP server

Add Account → Other IMAP and enter the server and port from your provider.
Grokbox tries the provider's published autoconfig first and fills the fields
when it finds one. On a plain server (no Gmail labels) Grokbox files mail by
**moving** it into folders it creates under `Grokbox/`, spelled with whatever
hierarchy delimiter and namespace prefix the server uses (`INBOX.Grokbox.Newsletters`
on a Courier-style server, for instance). Moves are undoable when the server
reports the new message IDs (UIDPLUS), which every major provider does.

## Proton Mail

Proton does not offer IMAP directly. You need **Proton Mail Bridge**, which
decrypts locally and exposes a normal IMAP server on your machine.

1. Bridge requires a **paid** Proton plan. Free accounts cannot use it.
2. Install Bridge from proton.me and sign in.
3. Bridge shows a per-account username and a **Bridge-specific password** — this
   is not your Proton password. Copy it.
4. In Bridge → Settings → Advanced, set **Connection mode** to **SSL**. Grokbox does not
   speak STARTTLS.
5. In Grokbox: Add Account → Proton Mail (via Bridge), paste both.
5. Bridge must be running whenever Grokbox syncs.

Defaults are `127.0.0.1`, port 1143.

**Known limitation:** Grokbox v0.1 speaks implicit TLS or cleartext, not
STARTTLS. Bridge often expects STARTTLS on 1143. If the connection fails, that
is the likely cause — STARTTLS is on the v0.2 roadmap. The cleartext option is
offered because Bridge is loopback-only, so those bytes never leave the machine,
but it will only work if your Bridge is configured to allow it.

Of the two providers, **Gmail is the verified path in v0.1.** Proton is wired up
but less tested.

## Other IMAP servers

Choose "Other IMAP" and fill in host, port, and security yourself. Anything
speaking IMAP4rev1 should work; Fastmail, iCloud, and self-hosted Dovecot are
the expected cases.

## What Grokbox does with the credentials

The password goes into the macOS Keychain under service
`com.wesleykeetch.grokbox.imap`. The SwiftData record stores only a lookup key,
never the password. Removing an account deletes the Keychain item.
