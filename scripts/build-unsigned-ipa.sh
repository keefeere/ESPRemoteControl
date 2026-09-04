#!/bin/bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/espremote-ios.XXXXXX")"
output_dir="$repo_root/dist"
ipa_path="$output_dir/ESPRemoteControl-unsigned.ipa"

cleanup() {
  rm -rf "$build_root"
}
trap cleanup EXIT

xcodebuild \
  -project "$repo_root/ESPRemoteControl.xcodeproj" \
  -scheme ESPRemoteControl \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_root/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  DEVELOPMENT_TEAM='' \
  clean build

app_path="$build_root/DerivedData/Build/Products/Release-iphoneos/ESPRemoteControl.app"
if [[ ! -d "$app_path" ]]; then
  echo "Built app was not found at $app_path" >&2
  exit 1
fi

# Fake-sign both executables before packaging. SideStore replaces these
# signatures with the user development certificate during installation.
share_extension_path="$app_path/PlugIns/ESPRemoteControlShare.appex"
if [[ ! -d "$share_extension_path" ]]; then
  echo "Built Share Extension was not found at $share_extension_path" >&2
  exit 1
fi

ldid -S "$share_extension_path/ESPRemoteControlShare"
ldid -S "$app_path/ESPRemoteControl"

mkdir -p "$build_root/Payload" "$output_dir"
ditto "$app_path" "$build_root/Payload/ESPRemoteControl.app"

(
  cd "$build_root"
  ditto -c -k --sequesterRsrc --keepParent Payload "$ipa_path"
)

(
  cd "$output_dir"
  shasum -a 256 "$(basename "$ipa_path")" > "$(basename "$ipa_path").sha256"
)
echo "Unsigned IPA created at $ipa_path"
