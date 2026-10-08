# Keychain Manager

A tiny, native macOS app for browsing and editing your login keychain — plus a read-only view of your launchd jobs — so you don't have to fight the `security` and `launchctl` CLIs. Built with SwiftUI; keychain access goes straight through Apple's Security framework. No network, no dependencies.

<img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13+"> <img src="https://img.shields.io/badge/Swift-5-orange" alt="Swift 5">

## Features

**Keychain tab**
- List generic + internet passwords from your login (and data-protection) keychain
- Live search and a Generic / Internet filter
- **Reveal** a secret on demand, then one-click **Copy** (masked entry; clipboard auto-clears after 60s)
- **Add** a generic password (creates or updates in place)
- **Delete** with type-the-name confirmation

**launchd tab**
- Read-only view of your user (GUI) launchd domain via `launchctl list`
- Running / All / Third-party filters, live search, PID and last-exit status
- Never loads, unloads, or kills anything — display only

Revealing a password created by another app triggers macOS's own authorization dialog — this app can't bypass the OS's gate on your secrets. Plaintext is held in memory only; nothing is written to disk or logged.

## Build

Requires the Xcode Command Line Tools (`xcode-select --install`).

```bash
# build a universal (Apple silicon + Intel) app with its icon and local signature
./scripts/build.sh

open "build/Keychain Manager.app"
```

The app is written to `build/Keychain Manager.app`. Pass a different output
directory as the first argument if needed. The script targets macOS 13+, builds
both architectures, generates the icon, and applies a local ad-hoc signature so
"Always Allow" keychain grants persist until the app is rebuilt.

Run the regression and bundle checks with:

```bash
./scripts/test.sh
```

## Icon

`tools/icongen.swift` renders the full icon set with Core Graphics:

```bash
swiftc -O tools/icongen.swift -o /tmp/icongen && /tmp/icongen /tmp/AppIcon.iconset
mkdir -p "build/Keychain Manager.app/Contents/Resources"
iconutil -c icns /tmp/AppIcon.iconset -o "build/Keychain Manager.app/Contents/Resources/AppIcon.icns"
```

## Layout

- `src/Keychain.swift` — Security-framework wrapper (list / reveal / add / delete)
- `src/App.swift` — SwiftUI UI (tabbed shell + Keychain tab)
- `src/Launchd.swift` — launchd tab (`launchctl list`, read-only)
- `tools/icongen.swift` — app-icon generator
- `keychain_manager.py` — earlier zero-dependency browser-based version (Python stdlib + `security` CLI); kept as an alternative

## Safety notes

- Not sandboxed; runs with your user rights over your login keychain (necessary for a keychain manager). Read the source — it's short.
- Ad-hoc signed, not notarized. Rebuilding changes the signature, so macOS re-prompts for "Always Allow" grants.
- Signed with the hardened runtime, so other processes can't inject code into the app (e.g. via `DYLD_INSERT_LIBRARIES`) and use its keychain grants.
- Copied passwords are auto-cleared from the clipboard after 60s (unless you copy something else first) and marked concealed so well-behaved clipboard managers skip them — but any app can read the clipboard while it's set, and it may sync via Universal Clipboard. A general risk of copying any secret.
- Deletes are permanent; be careful with app-managed items like `… Safe Storage`.
