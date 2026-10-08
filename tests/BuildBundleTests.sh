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

for arch in arm64 x86_64; do
    signature="$(codesign --display --verbose=2 --arch "$arch" "$app" 2>&1)"
    if ! grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime' <<<"$signature"; then
        echo "FAIL: $arch slice is not signed with hardened runtime" >&2
        exit 1
    fi
done
echo "BuildBundleTests passed"
