# Platform and stack

## Identified stack

| Aspect | Finding |
|---|---|
| Name | Grokbox |
| Bundle id | `com.wesleykeetch.grokbox` |
| Version | `MARKETING_VERSION` **0.2.0**, build 2 — docs describe v0.4 (see issues) |
| OS | macOS only |
| Deployment target | **macOS 26.0**; running on macOS 27.0 |
| Architecture | Apple Silicon (arm64). No Intel slice built or tested. |
| Language | Swift 6, strict concurrency = `complete` |
| UI | SwiftUI (`WindowGroup` + `MenuBarExtra`), no AppKit views except `NSPasteboard`/`NSApp` |
| Persistence | SwiftData, 8 `@Model` types, local store in the app container |
| Local model | Apple **FoundationModels** framework, with an **Ollama** loopback fallback |
| Networking | `Network.framework` (`NWConnection`) for IMAP, `URLSession` for autoconfig/unsubscribe/Ollama |
| Project generation | XcodeGen from `project.yml` |
| Package manager | Swift Package Manager (local package only) |
| **Third-party dependencies** | **None.** The IMAP client, MIME parser and RFC 2047 decoder are hand-written. |

## Targets

- `Grokbox` — the app (~2 330 lines of Swift, 16 files)
- `GrokboxCore` — a local Swift package holding all mail, analysis, storage and sync logic
  (~6 000 lines, 32 files), with its own test target (~1 800 lines, 101 tests)

No auxiliary apps, no XPC services, no helper tools, no CLI, no browser extension,
no background daemon, no local server in the shipping build.

## Entitlements and sandbox

```
com.apple.security.app-sandbox        = true
com.apple.security.network.client     = true
```

That is the complete list. Notably **absent and correctly so**: `network.server`,
`files.user-selected`, `automation`, camera/microphone. The demo mailbox was deliberately
rewritten to run in-process precisely so no listening socket — and therefore no
`network.server` entitlement — is needed.

## Outbound network surface

Exactly four kinds of connection exist in the code:

1. IMAP to the user's own mail server (TLS, port 993)
2. `autoconfig.thunderbird.net` / `autoconfig.<domain>` — only on "Look up settings", domain only
3. `127.0.0.1:11434` — Ollama, only if the user selects it, loopback-enforced in code
4. A sender's own `List-Unsubscribe` URL — only when the user clicks Unsubscribe

No telemetry, no analytics, no crash reporter, no update check. Verified by grepping every
URL literal in the source; the only other hosts present are `.example` domains inside the
demo corpus fixtures.
