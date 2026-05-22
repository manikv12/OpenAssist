#!/usr/bin/env bash

set -euo pipefail

APP_NAME="${OPENASSIST_ELECTRON_APP_NAME:-Open Assist Electron}"
BUNDLE_ID="${OPENASSIST_ELECTRON_BUNDLE_ID:-com.developingadventures.OpenAssistElectron}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${PROJECT_ROOT}/out"
DIST_DIR="${PROJECT_ROOT}/dist"
ENTITLEMENTS="${PROJECT_ROOT}/electron/release-entitlements.plist"
EXTEND_INFO="${PROJECT_ROOT}/electron/release-info.plist"
APP_VERSION="${OPENASSIST_VERSION:-$(node -p "require('./package.json').version")}"
BUILD_VERSION="${OPENASSIST_BUILD_VERSION:-$(git -C "${PROJECT_ROOT}/.." rev-list --count HEAD 2>/dev/null || echo 1)}"
APP_PATH="${OUT_DIR}/${APP_NAME}-darwin-arm64/${APP_NAME}.app"
DMG_FINAL="${DIST_DIR}/${APP_NAME}.dmg"

cd "$PROJECT_ROOT"

echo "Building ${APP_NAME} ${APP_VERSION} (${BUILD_VERSION})..."
npm run build

rm -rf "$OUT_DIR" "$DIST_DIR"
mkdir -p "$DIST_DIR"

PACKAGER_ARGS=(
  .
  "$APP_NAME"
  --platform=darwin
  --arch=arm64
  --out="$OUT_DIR"
  --overwrite
  --app-bundle-id="$BUNDLE_ID"
  --helper-bundle-id="${BUNDLE_ID}.helper"
  --app-category-type=public.app-category.productivity
  --app-version="$APP_VERSION"
  --build-version="$BUILD_VERSION"
  --icon=icon.icns
  --no-asar
  --extend-info="$EXTEND_INFO"
  --ignore='^/(out|out-unpacked|dist|verification|\.vite|\.playwright-mcp|dist-renderer/assets/.*\.map)$'
)

if [ -n "${DEVELOPER_ID:-}" ]; then
  SIGN_ID="Developer ID Application: ${DEVELOPER_ID}"
  echo "Packaging and signing with ${SIGN_ID}..."
  PACKAGER_ARGS+=(
    --osx-sign.identity="$SIGN_ID"
    --osx-sign.entitlements="$ENTITLEMENTS"
    --osx-sign.entitlements-inherit="$ENTITLEMENTS"
  )
else
  echo "Packaging without Developer ID; applying local ad-hoc signature after packaging."
fi

npx electron-packager "${PACKAGER_ARGS[@]}"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: packaged app not found at ${APP_PATH}"
  exit 1
fi

if [ -z "${DEVELOPER_ID:-}" ]; then
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Creating ${DMG_FINAL}..."
npx -y create-dmg "$APP_PATH" "$DIST_DIR/" --overwrite --no-version-in-filename --icon-size 128
CREATED_DMG="$(find "$DIST_DIR" -maxdepth 1 -name "*.dmg" | head -n 1)"
if [ -z "$CREATED_DMG" ]; then
  echo "Error: create-dmg did not produce a DMG."
  exit 1
fi
if [ "$CREATED_DMG" != "$DMG_FINAL" ]; then
  mv "$CREATED_DMG" "$DMG_FINAL"
fi

echo "Electron release DMG ready at ${DMG_FINAL}"
