#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="${1:-$repo_root/dist}"
mkdir -p "$output_root"
output_root="$(cd "$output_root" && pwd)"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/keychain-manager-package.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT

"$repo_root/scripts/build.sh" "$work_root"
app="$work_root/Keychain Manager.app"
version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
archive="Keychain-Manager-$version-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output_root/$archive"
(cd "$output_root" && shasum -a 256 "$archive" > "$archive.sha256")
echo "$output_root/$archive"
