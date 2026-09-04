#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/espremote-hid-tests.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
swiftc -swift-version 5 \
  "$repo_root/Shared/HIDReports.swift" \
  "$repo_root/Shared/HIDHostStore.swift" \
  "$repo_root/Shared/ShareTextHandoff.swift" \
  "$repo_root/Tests/DirectHIDTests.swift" \
  -o "$build_dir/hid-tests"
"$build_dir/hid-tests"
