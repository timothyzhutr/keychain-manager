# Keychain Manager

A tiny, native macOS app for browsing and editing your login keychain — so you don't have to fight the `security` CLI. Built with SwiftUI, talks to the keychain through Apple's Security framework directly (no shelling out, no network, no dependencies).

<img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13+"> <img src="https://img.shields.io/badge/Swift-5-orange" alt="Swift 5">

## Features

- List generic + internet passwords from your login (and data-protection) keychain
- Live search and a Generic / Internet filter
- **Reveal** a secret on demand, then one-click **Copy**
- **Add** a generic password (creates or updates in place)
- **Delete** with a confirmation dialog

Revealing a password created by another app triggers macOS's own authorization dialog — this app can't bypass the OS's gate on your secrets. Plaintext is held in memory only; nothing is written to disk or logged.

## Build

Requires the Xcode Command Line Tools (`xcode-select --install`).

```bash
# compile the binary into an app bundle
swiftc -swift-version 5 -O src/Keychain.swift src/App.swift \
  -o "Keychain Manager.app/Contents/MacOS/KeychainManager"

# ad-hoc sign (stable local identity so "Always Allow" grants persist)
codesign --force --sign - "Keychain Manager.app"

open "Keychain Manager.app"
```

The `Keychain Manager.app` bundle, its `Info.plist`, and the icon are build artifacts. A minimal bundle (`Contents/Info.plist` + `Contents/MacOS/` + `Contents/Resources/`) is all that's needed; see the build steps and `tools/icongen.swift` to regenerate the icon.

## Icon

`tools/icongen.swift` renders the full icon set with Core Graphics:

```bash
swiftc -O tools/icongen.swift -o /tmp/icongen && /tmp/icongen /tmp/AppIcon.iconset
iconutil -c icns /tmp/AppIcon.iconset -o "Keychain Manager.app/Contents/Resources/AppIcon.icns"
```

## Layout

- `src/Keychain.swift` — Security-framework wrapper (list / reveal / add / delete)
- `src/App.swift` — SwiftUI UI
- `tools/icongen.swift` — app-icon generator
- `keychain_manager.py` — earlier zero-dependency browser-based version (Python stdlib + `security` CLI); kept as an alternative

## Safety notes

- Not sandboxed; runs with your user rights over your login keychain (necessary for a keychain manager). Read the source — it's short.
- Ad-hoc signed, not notarized. Rebuilding changes the signature, so macOS re-prompts for "Always Allow" grants.
- Copied passwords sit on the clipboard until overwritten (and may sync via Universal Clipboard) — a general risk of copying any secret.
- Deletes are permanent; be careful with app-managed items like `… Safe Storage`.
