#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/inpudeck-hid-tests.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

swiftc -swift-version 5 \
  "$repo_root/Shared/Localization.swift" \
  "$repo_root/Shared/HIDReports.swift" \
  "$repo_root/Shared/HIDHostStore.swift" \
  "$repo_root/Tests/DirectHIDTests.swift" \
  -o "$build_dir/hid-tests"
"$build_dir/hid-tests"

swiftc -swift-version 5 \
  "$repo_root/Shared/HIDReports.swift" \
  "$repo_root/Shared/HIDMouseButton.swift" \
  "$repo_root/Tests/MouseButtonMaskTests.swift" \
  -o "$build_dir/mouse-button-mask-tests"
"$build_dir/mouse-button-mask-tests"

swiftc -swift-version 5 \
  "$repo_root/Shared/Localization.swift" \
  "$repo_root/Shared/HID.swift" \
  "$repo_root/Shared/TextTypingPlanner.swift" \
  "$repo_root/Tests/HIDMappingTests.swift" \
  -o "$build_dir/hid-mapping-tests"
"$build_dir/hid-mapping-tests"

swiftc -swift-version 5 \
  "$repo_root/Shared/TextMutationPlanner.swift" \
  "$repo_root/Tests/TextMutationPlannerTests.swift" \
  -o "$build_dir/text-mutation-planner-tests"
"$build_dir/text-mutation-planner-tests"
