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
  echo "Packaging without automatic Electron signing; signing final app with ${SIGN_ID}..."
else
  echo "Packaging without Developer ID; applying local ad-hoc signature after packaging."
fi

npx electron-packager "${PACKAGER_ARGS[@]}"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: packaged app not found at ${APP_PATH}"
  exit 1
fi

sign_target() {
  local target="$1"
  if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$target"
  else
    codesign --force --options runtime --sign - "$target"
  fi
}

normalize_framework_layout() {
  local framework_path="$1"
  local version_dir="${framework_path}/Versions/A"
  if [ ! -d "$version_dir" ]; then
    return
  fi

  rm -rf "${framework_path}/Versions/Current"
  ln -s "A" "${framework_path}/Versions/Current"

  for linked_dir in Headers Modules Resources; do
    if [ -e "${version_dir}/${linked_dir}" ]; then
      rm -rf "${framework_path}/${linked_dir}"
      ln -s "Versions/Current/${linked_dir}" "${framework_path}/${linked_dir}"
    fi
  done

  local info_plist="${version_dir}/Resources/Info.plist"
  local executable_name=""
  if [ -f "$info_plist" ]; then
    executable_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$info_plist" 2>/dev/null || true)"
  fi
  if [ -n "$executable_name" ] && [ -e "${version_dir}/${executable_name}" ]; then
    rm -rf "${framework_path}/${executable_name}"
    ln -s "Versions/Current/${executable_name}" "${framework_path}/${executable_name}"
  fi
}

APP_RESOURCE_ROOT="${APP_PATH}/Contents/Resources/app"
if [ -d "$APP_RESOURCE_ROOT" ]; then
  while IFS= read -r -d '' framework_path; do
    normalize_framework_layout "$framework_path"
    sign_target "$framework_path"
  done < <(find "$APP_RESOURCE_ROOT" -type d -name "*.framework" -print0)

  while IFS= read -r -d '' native_file; do
    case "$native_file" in
      *.framework/*) continue ;;
    esac
    if file "$native_file" | grep -q "Mach-O"; then
      sign_target "$native_file"
    fi
  done < <(find "$APP_RESOURCE_ROOT" -type f -perm -111 -print0)
fi

if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP_PATH"
else
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
