# Releasing

One command builds, signs, notarises and checksums a release:

```bash
scripts/release.sh 0.5.0
```

It refuses to run on a dirty tree, refuses if the version does not match
`project.yml`, runs the engine tests first, and fails if the App Sandbox
entitlement is missing after signing. The output lands in `dist/`.

## What you need once

Two things, both from Apple, both one-time.

### 1. A Developer ID Application certificate

This is the certificate for distributing a Mac app **outside** the App Store.
An "Apple Development" certificate is not the same thing and will not work:
apps signed with it only run on devices registered to your account.

1. Join the Apple Developer Program if you have not. It is $99/year, and there
   is no way to notarise without it.
2. In Xcode: Settings → Accounts → your Apple ID → Manage Certificates → **+**
   → **Developer ID Application**.
3. Check it landed: `security find-identity -v -p codesigning` should list a
   `Developer ID Application: <your name> (TEAMID)`.

### 2. A stored notarytool credential

Notarising means uploading the app to Apple, who scan it and issue a ticket
that Gatekeeper trusts. It needs an app-specific password, not your Apple
password.

1. Create one at <https://account.apple.com> → Sign-In and Security →
   App-Specific Passwords.
2. Store it once:

```bash
xcrun notarytool store-credentials grokbox \
  --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
```

The profile name must be `grokbox`; the script looks for exactly that.

## What happens without them

The script still produces a working app and a checksum, ad-hoc signed, and says
plainly that it is not ready for anyone else. macOS shows an "unidentified
developer" warning to anyone who downloads it, which they can bypass by
right-clicking and choosing Open. That is fine for you on this machine and not
fine as a release.

## Publishing

```bash
git tag -s v0.5.0 -m "Grokbox 0.5.0"
git push origin v0.5.0
gh release create v0.5.0 dist/Grokbox-0.5.0.zip dist/Grokbox-0.5.0.zip.sha256 \
  --title "Grokbox 0.5.0" --notes-file docs/release-notes-0.5.0.md
```

Tags are signed with the same SSH key as commits (`tag.gpgSign` is on).
Put the SHA-256 in the release notes so anyone can check what they downloaded:

```bash
shasum -a 256 -c Grokbox-0.5.0.zip.sha256
```

## Reproducing a build

Grokbox has no third-party dependencies, so a build depends only on the tag,
the Xcode version and the SDK. Record all three in the release notes:

```bash
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
```

Two builds from the same tag with the same toolchain produce the same code;
the signatures differ, because a signature includes a timestamp.
