# Threat model

Privacy Guides asks every project to say exactly what it protects against and
what it does not, in their vocabulary. This is that statement for Grokbox. It is
written from the code, and `docs/PRIVACY.md` is the byte-level inventory behind it.

## The three words

Privacy Guides separates **privacy**, **security**, and **anonymity**. Grokbox
provides the first two and does not attempt the third.

- **Privacy** — your mail is seen only by you and the mail server you already
  trust with it. Grokbox adds no third party by default, and has no server of
  its own. The one exception is opt-in: a Jev cloud fallback for sender
  categorization, off unless you turn it on and supply your own API key — see
  docs/PRIVACY.md and ADR-0023.
- **Security** — TLS with certificate validation to every remote host, passwords
  in the macOS Keychain, an App Sandbox with a single entitlement
  (`network.client`), no third-party code, no HTML rendering — tracking
  pixels and remote images never load, because nothing ever parses a
  message body as HTML.
- **Anonymity** — not provided. Your IMAP server sees your IP address exactly as
  it does with any mail client. Grokbox does not route through Tor or a VPN and
  does not claim to.

## Threats, in Privacy Guides' taxonomy

| Threat | Protected? | How, or why not |
|---|---|---|
| **Service providers** — the app's own vendor seeing your data | **Yes, by default** | No vendor service, no account, no sync, no telemetry, no crash reporter, no update check by default. If you opt into the Jev cloud fallback in Settings, TypeSafe AI receives a sender's address and sample subject lines for categorization only — never a message body. Off by default; see ADR-0023. |
| **Surveillance capitalism** — data monetised or profiled | **Yes** | Nothing leaves the machine to be monetised. The sender profiles, importance scores and summaries are computed and stored locally in the sandbox container and can be erased from Settings. |
| **Passive attacks** — an observer on the network | **Yes, to the extent of TLS** | Remote IMAP connections are TLS-only; plaintext and self-signed trust are refused for any host except `127.0.0.1`. What the observer sees is that you connected to your mail server, which they would see with any client. |
| **Mass surveillance** | **Partly** | Grokbox neither adds nor removes exposure here. Your mail still lives on your provider's servers under that provider's jurisdiction. Choosing the provider is the lever; Grokbox is not. |
| **Targeted attacks** — someone after *you* specifically | **Partly** | Sandbox and Keychain raise the cost of local compromise. Phishing links in mail are surfaced with hygiene warnings (domain mismatch, IP-literal hosts, "confirm your account" text) but Grokbox opens nothing on its own. It cannot protect a compromised Mac. |
| **Supply chain attacks** | **Partly** | Zero third-party dependencies; the whole engine is in this repository and builds with stock Xcode. Not yet protected: releases are not signed or checksummed and builds are not reproducible. See `SECURITY.md` → *Roadmap*. |
| **Public exposure** — doxxing, leaks | **N/A** | Grokbox neither publishes nor shares anything. |
| **Anonymity** | **No** | See above. |
| **Censorship** | **N/A** | Grokbox does not route or filter traffic. |

## What Grokbox specifically cannot protect you from

- **Your mail provider.** They already have everything. Grokbox reads through
  them; it cannot make Gmail forget your mail.
- **Apple's on-device model.** The default summariser is Apple's Foundation
  Models framework. Apple states it runs on-device and sends nothing off the
  Mac. Grokbox cannot verify that claim from outside; it takes Apple's
  documentation at its word. If that is not good enough for your threat model,
  choose **Ollama** in Settings — the whole stack is then open source and
  Grokbox refuses to talk to Ollama on anything but loopback.
- **Anything you click.** Unsubscribe sends one RFC 8058 POST to the URL the
  sender put in their own header, only when you press the button. That request
  reveals to the sender that the address is live. The button says so.
- **Prompt injection.** Message bodies go to a language model. A malicious
  message can try to steer the summary. The model has no tools, no network,
  and no ability to act; the worst outcome is a misleading one-line summary,
  which you can see next to the real subject line. Grokbox does not act on
  model output without you.

## Design consequence

Privacy Guides' *Why Privacy Matters* argues that per-app privacy dashboards are
an illusion — privacy has to be the default, not a setting. Grokbox has one
privacy-relevant toggle: the opt-in Jev cloud fallback (ADR-0023), off by
default. Everything else privacy-relevant is a consequence of the
architecture rather than a setting — which mail accounts to add and which
local model to use are the only other choices, and both are stated in plain
language where you make them.
