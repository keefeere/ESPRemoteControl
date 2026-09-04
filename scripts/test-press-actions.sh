#!/bin/bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/espremote-press-actions.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

# Build the exact production button style in a small host app. The UI runner
# exercises actual touches without Bluetooth permissions or a paired computer.
cp "$repo_root/Tests/PressActions/"* "$test_root/"
cp "$repo_root/ESPRemoteControl/ShortAndLongPressButtonStyle.swift" "$test_root/"
xcodegen generate --spec "$test_root/project.yml"

simulator_id="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device["name"].startswith("iPhone"):
            print(device["udid"])
            sys.exit(0)
sys.exit("No available iPhone simulator")
')"
xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simulator_id" -b
mkdir -p "$repo_root/dist"
xcodebuild test -quiet \
    -project "$test_root/PressActionsTests.xcodeproj" \
    -scheme PressActionsHost \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -parallel-testing-enabled NO \
    -derivedDataPath "$test_root/DerivedData" \
    -resultBundlePath "$repo_root/dist/press-actions.xcresult" \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$repo_root/dist/press-actions-tests.log"
