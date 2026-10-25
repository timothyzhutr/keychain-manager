# Keychain Manager

A tiny, native macOS app for browsing and editing your file-based keychains — plus a read-only view of your launchd jobs — so you don't have to fight the `security` and `launchctl` CLIs. Built with SwiftUI; keychain access goes straight through Apple's Security framework. No network, no third-party dependencies.

<img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13+"> <img src="https://img.shields.io/badge/Swift-5-orange" alt="Swift 5">

## Features

**Keychain tab**
- List generic + internet passwords from the file-based keychains in your search list (normally your login keychain)
- Live search and a Generic / Internet filter
- **Reveal** a secret on demand, with **Hide** and a 60-second reveal timeout
- **Copy** a revealed password; clipboard auto-clears after 60s or on normal app quit, unless another copy has changed it
- **Add** a generic password to your default keychain; replacing an existing service/account requires explicit confirmation
- **Update** a password or token in place, keeping its name, account, notes, and access settings
- **Delete** with type-the-name confirmation

**launchd tab**
- Read-only view of your user (GUI) launchd domain via `launchctl list`
- Running / All / Third-party filters, live search, PID and last-exit status
- Never loads, unloads, or kills anything — display only

Revealing a protected password can trigger macOS's own authorization dialog. This app respects the item's access controls. Passwords are not logged or saved to files by the app. Revealed text is hidden and its application state cleared on reload, leaving the app or Keychain tab, window close, sleep/session changes, and quit. Reload, tab/window close, sleep/session changes, and quit also invalidate pending reveals. A result arriving while the app is inactive is discarded; a pending authorization may complete after the app becomes active again. Cleanup releases references to plaintext; Swift strings do not provide guaranteed memory zeroing.

This is a utility for file-based keychains, not a complete replacement for Apple Passwords. It does not browse the data-protection/iCloud password store, passkeys, certificates, or private keys.

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

Tests use a temporary keychain and a private clipboard, not your saved passwords or current clipboard. They cover exact item targeting, duplicate protection and confirmed replacement, generic and internet password updates with metadata preservation, list failures, reveal expiry and stale results, clipboard ownership and cleanup, and the extracted universal app bundle. GitHub Actions runs the same checks on macOS.

## Share with friends

```bash
./scripts/package.sh
```

This creates `dist/Keychain-Manager-1.1.0-macOS.zip` and a `.sha256` checksum. Send both files. To verify the archive, run `shasum -a 256 -c Keychain-Manager-1.1.0-macOS.zip.sha256` in the download folder, then unzip and drag **Keychain Manager.app** into **Applications**.

The package uses the same local ad-hoc signature as a source build. It is not Developer ID signed or notarized; an internet-downloaded copy may require approval using macOS's [Open Anyway procedure](https://support.apple.com/en-us/102445). Friends who prefer to build locally can use the Build instructions above. Only macOS is supported; test on a friend's Mac before sharing more widely.

**Using it:** choose **Reveal** only for an item you need, then **Copy** or **Hide**. Reveals expire after 60 seconds. The clipboard remains available when you switch apps to paste, and clears on its own timer. **Save** creates a password; if it already exists, **Cancel** preserves the original and **Replace** changes exactly that item. A failed save keeps the form open for retry. Deletion requires typing the displayed name and is permanent.

To rotate a saved password or API token, choose **Update** on its row, paste the new value, and choose **Update** again. The current secret is never loaded into the form. This changes only the selected item's saved value; it preserves its name, account, notes, and access settings. Cancel leaves the item unchanged, and a failed update keeps the form open for retry. Updating the keychain does not change a password or issue a token at the original service—obtain the new value there first.

## Icon

`tools/icongen.swift` renders the full icon set with Core Graphics:

```bash
swiftc -O tools/icongen.swift -o /tmp/icongen && /tmp/icongen /tmp/AppIcon.iconset
mkdir -p "build/Keychain Manager.app/Contents/Resources"
iconutil -c icns /tmp/AppIcon.iconset -o "build/Keychain Manager.app/Contents/Resources/AppIcon.icns"
```

## Layout

- `src/Keychain.swift` — Security-framework wrapper (list / reveal / add / update / delete)
- `src/App.swift` — SwiftUI UI (tabbed shell + Keychain tab)
- `src/Launchd.swift` — launchd tab (`launchctl list`, read-only)
- `src/Secrets.swift` — reveal lifecycle and clipboard ownership/expiry
- `src/Lifecycle.swift` — app activation, window/sleep, and quit cleanup
- `scripts/package.sh` — shareable ZIP and SHA-256 checksum
- `tools/icongen.swift` — app-icon generator

The earlier Python/browser implementation and `.command` launcher have been retired. Use the native app; the older version passed passwords through command-line arguments and did not use persistent references for item targeting.

## Safety notes

- Not sandboxed; runs with your user rights and can modify keychain items you authorize. Read the source — it's short.
- Ad-hoc signed, not notarized. Rebuilding changes the signature, so macOS re-prompts for "Always Allow" grants.
- Signed with the hardened runtime to block dynamic-library injection such as `DYLD_INSERT_LIBRARIES`.
- Copied passwords are marked concealed so well-behaved clipboard managers skip them, but other apps can read the clipboard while it is set, and it may sync via Universal Clipboard. Auto-clear runs after 60s and on normal quit, and preserves anything copied afterward. A force quit, crash, or power loss can prevent cleanup.
- Deletes are permanent; be careful with app-managed items like `… Safe Storage`.
