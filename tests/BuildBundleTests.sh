#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/keychain-manager-build-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

"$repo_root/scripts/build.sh" "$test_root"

app="$test_root/Keychain Manager.app"
binary="$app/Contents/MacOS/KeychainManager"
plist="$app/Contents/Info.plist"

test -x "$binary"
plutil -lint "$plist"
test "$(plutil -extract CFBundleIdentifier raw "$plist")" = "com.timothyzhutr.keychain-manager"
test "$(plutil -extract CFBundleExecutable raw "$plist")" = "KeychainManager"

architectures="$(lipo -archs "$binary")"
[[ " $architectures " == *" arm64 "* ]]
[[ " $architectures " == *" x86_64 "* ]]

codesign --verify --deep --strict --verbose=2 "$app"
echo "BuildBundleTests passed"
