#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="${1:-$repo_root/build}"
app="$output_root/Keychain Manager.app"
contents="$app/Contents"
binary="$contents/MacOS/KeychainManager"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/keychain-manager-build.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT

# Some Command Line Tools releases ship a macOS SDK whose SwiftUI declares
# @State as a macro but omit the SwiftUIMacros compiler plugin (Xcode has it).
# If the default SDK can't expand it, fall back to the newest installed macOS
# SDK that can. Set SDKROOT to pick an SDK yourself and skip this check.
if [[ -z "${SDKROOT:-}" ]]; then
    probe="$work_root/SDKProbe.swift"
    cat > "$probe" <<'EOF'
import SwiftUI
struct SDKProbe: View {
    @State private var value = 0
    var body: some View { Text("\(value)") }
}
EOF
    sdk_works() {
        SDKROOT="$1" swiftc -typecheck -target arm64-apple-macosx13.0 \
            -swift-version 5 "$probe" >/dev/null 2>&1
    }
    default_sdk="$(cd "$(xcrun --sdk macosx --show-sdk-path)" && pwd -P)"
    if ! sdk_works "$default_sdk"; then
        fallback_sdk=""
        while IFS= read -r sdk; do
            [[ -L "$sdk" || "$sdk" == "$default_sdk" ]] && continue
            if sdk_works "$sdk"; then
                fallback_sdk="$sdk"
                break
            fi
        done < <(ls -d "$(dirname "$default_sdk")"/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV)
        if [[ -z "$fallback_sdk" ]]; then
            echo "No installed macOS SDK can compile SwiftUI's @State with this toolchain." >&2
            echo "Install Xcode, or set SDKROOT to a compatible SDK." >&2
            exit 1
        fi
        echo "Default SDK can't expand SwiftUI macros here; using $fallback_sdk" >&2
        export SDKROOT="$fallback_sdk"
    fi
fi

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
# Hardened runtime blocks DYLD_INSERT_LIBRARIES-style injection, which would
# otherwise let any same-user process run code with this app's keychain grants.
codesign --force --sign - --options runtime "$app"

plutil -lint "$contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$app"
echo "$app"
