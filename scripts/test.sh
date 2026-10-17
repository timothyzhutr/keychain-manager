#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/keychain-manager-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

swiftc -swift-version 5 \
    "$repo_root/src/Keychain.swift" \
    "$repo_root/tests/KeychainQueryTests.swift" \
    -o "$test_root/KeychainQueryTests"
"$test_root/KeychainQueryTests"

swiftc -swift-version 5 \
    "$repo_root/src/Keychain.swift" \
    "$repo_root/tests/KeychainFailureTests.swift" \
    -o "$test_root/KeychainFailureTests"
"$test_root/KeychainFailureTests"

swiftc -swift-version 5 \
    "$repo_root/src/Secrets.swift" \
    "$repo_root/src/Lifecycle.swift" \
    "$repo_root/tests/SecretLifecycleTests.swift" \
    -o "$test_root/SecretLifecycleTests"
"$test_root/SecretLifecycleTests"

swiftc -swift-version 5 \
    "$repo_root/src/Keychain.swift" \
    "$repo_root/tests/PersistentRefIntegrationTests.swift" \
    -o "$test_root/PersistentRefIntegrationTests"
"$test_root/PersistentRefIntegrationTests"

bash "$repo_root/tests/BuildBundleTests.sh"
