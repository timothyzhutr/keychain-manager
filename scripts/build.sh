#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="${1:-$repo_root/build}"
app="$output_root/Keychain Manager.app"
contents="$app/Contents"
binary="$contents/MacOS/KeychainManager"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/keychain-manager-build.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT

case "$app" in
    */"Keychain Manager.app") ;;
    *) echo "Refusing unsafe app output path: $app" >&2; exit 1 ;;
esac
if [[ -e "$app" ]]; then
    rm -rf -- "$app"
fi

mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$repo_root/app/Info.plist" "$contents/Info.plist"

swiftc -target arm64-apple-macosx13.0 -swift-version 5 -O \
    "$repo_root"/src/*.swift -o "$work_root/KeychainManager-arm64"
swiftc -target x86_64-apple-macosx13.0 -swift-version 5 -O \
    "$repo_root"/src/*.swift -o "$work_root/KeychainManager-x86_64"
lipo -create \
    "$work_root/KeychainManager-arm64" \
    "$work_root/KeychainManager-x86_64" \
    -output "$binary"

swiftc -O "$repo_root/tools/icongen.swift" -o "$work_root/icongen"
"$work_root/icongen" "$work_root/AppIcon.iconset"
iconutil -c icns "$work_root/AppIcon.iconset" \
    -o "$contents/Resources/AppIcon.icns"

# Local ad-hoc signing gives macOS a repeatable identity for keychain access.
# It is intentionally not Developer ID distribution signing.
codesign --force --sign - "$app"

plutil -lint "$contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$app"
echo "$app"
