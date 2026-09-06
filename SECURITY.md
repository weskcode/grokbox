# Security

## Reporting a vulnerability

Email **wesleyk@duck.com** with "Grokbox security" in the subject. You will get
an acknowledgement within 72 hours. Please do not open a public issue for
anything that could be exploited before it is fixed.

There is no bug bounty. Credit is given in the release notes unless you ask
otherwise.

## What Grokbox does

- **Transport.** IMAP over TLS (`Network.framework`, system trust store). A
  plaintext or self-signed connection is accepted only for `127.0.0.1`,
  `localhost` and `::1`; any other host is refused before a socket is opened
  (`IMAPConnection.swift`). No App Transport Security exceptions.
- **Credentials.** Mail passwords are stored in the macOS Keychain under
  service `com.wesleykeetch.grokbox.imap` and never written to the database,
  logs, or disk (`KeychainStore.swift`).
- **Sandbox.** `com.apple.security.app-sandbox` with one entitlement,
  `network.client`. No `network.server`, no file-system entitlements beyond
  the container.
- **Read-only by default.** Indexing uses IMAP `EXAMINE` and `BODY.PEEK`; the
  server is never told you looked. Writes happen only in Sweep and Undo, are
  logged, and are reversible from Activity. Grokbox has no code path that
  deletes a message.
- **Local model.** Summaries are produced by Apple's on-device model or a
  loopback-only Ollama. Model output is displayed, never executed or acted on.
- **Unsubscribe policy.** The RFC 8058 POST goes only to an HTTPS URL on a
  public host — never loopback, private, link-local or `.local` — and follows
  at most one redirect under the same rule (`PublicHostPolicy.swift`).
- **Link hygiene.** Bodies are scanned for domain-mismatched anchors,
  IP-literal hosts, and account-confirmation phrasing; warnings are shown, links
  are never opened automatically.
- **Dependencies.** None outside Apple's SDK.

## Known limitations (open)

- **No release signing yet.** Until the first tagged release, build from
  source. Signed tags, SHA-256 checksums and Developer ID notarisation are on
  the roadmap below.
- **No automatic updates.** Grokbox does not phone home, so it cannot tell you
  about a new version. Watch the repository's releases.

## Roadmap

1. Signed git tags (commits are SSH-signed; `.allowed_signers` is in the repo).
2. Release artefacts with published SHA-256 and a notarised, Developer ID-signed
   build.
3. Reproducible build notes: exact Xcode version, `xcodegen` version, and a
   script that produces a byte-identical `.app` from a tag.

## Third-party audit

None has been performed or requested. This is stated so nobody has to guess.
