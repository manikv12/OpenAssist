#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_ROOT="${1:?Usage: build-native-helpers.sh OUTPUT_DIRECTORY [SIGN_IDENTITY]}"
SIGN_IDENTITY="${2:--}"
SOURCE_ROOT="${PROJECT_ROOT}/electron/helpers"

build_helper() {
  local app_name="$1"
  local executable_name="$2"
  local source_name="$3"
  local plist_name="$4"
  local entitlements_name="$5"
  shift 5
  local app_path="${OUTPUT_ROOT}/${app_name}.app"
  local macos_path="${app_path}/Contents/MacOS"

  rm -rf "$app_path"
  mkdir -p "$macos_path"
  cp "${SOURCE_ROOT}/${plist_name}" "${app_path}/Contents/Info.plist"
  /usr/bin/swiftc \
    -target arm64-apple-macos13.0 \
    "$@" \
    -Xlinker -sectcreate \
    -Xlinker __TEXT \
    -Xlinker __info_plist \
    -Xlinker "${SOURCE_ROOT}/${plist_name}" \
    "${SOURCE_ROOT}/${source_name}" \
    -o "${macos_path}/${executable_name}"
  chmod 755 "${macos_path}/${executable_name}"
  # Hardened runtime silently denies protected-resource access (e.g. EventKit
  # calendars) unless the binary carries the matching entitlements.
  if [ "$entitlements_name" != "-" ]; then
    /usr/bin/codesign --force --options runtime \
      --entitlements "${SOURCE_ROOT}/${entitlements_name}" \
      --sign "$SIGN_IDENTITY" "$app_path"
  else
    /usr/bin/codesign --force --options runtime --sign "$SIGN_IDENTITY" "$app_path"
  fi
}

mkdir -p "$OUTPUT_ROOT"
build_helper \
  "Open Assist Apple EventKit Helper" \
  "apple-eventkit-helper" \
  "apple-eventkit-helper.swift" \
  "apple-eventkit-helper-info.plist" \
  "apple-eventkit-helper-entitlements.plist" \
  -framework EventKit -framework AppKit

build_helper \
  "Open Assist Speech Helper" \
  "apple-speech-helper" \
  "apple-speech-helper.swift" \
  "apple-speech-helper-info.plist" \
  "-" \
  -framework AVFoundation -framework CoreAudio -framework Speech

/usr/bin/swiftc \
  -target arm64-apple-macos14.0 \
  -framework CoreImage \
  -framework Vision \
  "${SOURCE_ROOT}/vision-background-helper.swift" \
  -o "${OUTPUT_ROOT}/vision-background-helper"
chmod 755 "${OUTPUT_ROOT}/vision-background-helper"
/usr/bin/codesign --force --options runtime --sign "$SIGN_IDENTITY" \
  "${OUTPUT_ROOT}/vision-background-helper"

/usr/bin/swiftc \
  -target arm64-apple-macos13.0 \
  -framework AVFoundation \
  -framework CoreGraphics \
  -framework CoreVideo \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  "${SOURCE_ROOT}/short-video-helper.swift" \
  -o "${OUTPUT_ROOT}/short-video-helper"
chmod 755 "${OUTPUT_ROOT}/short-video-helper"
/usr/bin/codesign --force --options runtime --sign "$SIGN_IDENTITY" \
  "${OUTPUT_ROOT}/short-video-helper"

echo "Native helpers built at ${OUTPUT_ROOT}"
