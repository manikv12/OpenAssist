#!/bin/bash

set -euo pipefail

APP_NAME="Open Assist"
APP_EXECUTABLE="OpenAssist"
APP_BUNDLE_ID="com.manikvashith.OpenAssist"
APP_DIR="dist/${APP_NAME}.app"
INSTALL_DIR="/Applications/${APP_NAME}.app"
DMG_ROOT="dist/dmg-root"
DMG_FINAL="dist/${APP_NAME}.dmg"
DMG_VOLUME_NAME="${APP_NAME} Installer"
PROJECT_ROOT="$(pwd)"
APP_DIR_ABS="${PROJECT_ROOT}/${APP_DIR}"
DIST_DIR_ABS="${PROJECT_ROOT}/dist"
SOURCE_INFO_PLIST="Resources/Info.plist"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

INSTALL_APP=false
MAKE_DMG=false

read_source_plist_value() {
    local key="$1"
    "$PLIST_BUDDY" -c "Print :${key}" "$SOURCE_INFO_PLIST" 2>/dev/null || true
}

resolve_marketing_version() {
    local tagged_version
    tagged_version="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
    if [ -n "$tagged_version" ]; then
        echo "${tagged_version#v}"
        return
    fi

    local plist_version
    plist_version="$(read_source_plist_value "CFBundleShortVersionString")"
    if [ -n "$plist_version" ]; then
        echo "$plist_version"
        return
    fi

    echo "1.0.0"
}

resolve_build_version() {
    local commit_count
    commit_count="$(git rev-list --count HEAD 2>/dev/null || true)"
    if [[ "$commit_count" =~ ^[0-9]+$ ]] && [ "$commit_count" -gt 0 ]; then
        echo "$commit_count"
        return
    fi

    local plist_build
    plist_build="$(read_source_plist_value "CFBundleVersion")"
    if [[ "$plist_build" =~ ^[0-9]+$ ]] && [ "$plist_build" -gt 0 ]; then
        echo "$plist_build"
        return
    fi

    echo "1"
}

APP_MARKETING_VERSION="${OPENASSIST_VERSION:-$(resolve_marketing_version)}"
APP_BUILD_VERSION="${OPENASSIST_BUILD_VERSION:-$(resolve_build_version)}"

for arg in "$@"; do
    case "$arg" in
        --install)
            INSTALL_APP=true
            ;;
        --make-dmg)
            MAKE_DMG=true
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: ./build.sh [--install] [--make-dmg]"
            exit 1
            ;;
    esac
done

echo "Building ${APP_NAME} (Release)..."
echo "Using app version ${APP_MARKETING_VERSION} (${APP_BUILD_VERSION})"
if [ ! -d "Vendor/Whisper/whisper.xcframework" ]; then
    echo "whisper.xcframework not found, downloading framework..."
    Scripts/update-whisper-framework.sh
fi
swift build -c release

echo "Creating macOS App Bundle at ${APP_DIR}..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

echo "Copying executable..."
cp ".build/release/${APP_EXECUTABLE}" "$APP_DIR/Contents/MacOS/"
chmod +x "$APP_DIR/Contents/MacOS/${APP_EXECUTABLE}"

echo "Embedding whisper framework..."
WHISPER_MACOS_FRAMEWORK="$(find Vendor/Whisper/whisper.xcframework -maxdepth 2 -type d -name whisper.framework | grep 'macos-' | head -n 1 || true)"
if [ -z "$WHISPER_MACOS_FRAMEWORK" ]; then
    echo "Failed to locate macOS whisper.framework inside Vendor/Whisper/whisper.xcframework"
    exit 1
fi
cp -R "$WHISPER_MACOS_FRAMEWORK" "$APP_DIR/Contents/MacOS/"

echo "Embedding Sparkle framework..."
SPARKLE_FRAMEWORK="$(find .build/artifacts -type d -name 'Sparkle.framework' | head -n 1 || true)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "Failed to locate Sparkle.framework in .build/artifacts"
    exit 1
fi
cp -R "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/"

echo "Configuring runtime search paths..."
APP_BINARY="$APP_DIR/Contents/MacOS/${APP_EXECUTABLE}"
if ! otool -l "$APP_BINARY" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"
fi

echo "Copying Info.plist and resources..."
cp "$SOURCE_INFO_PLIST" "$APP_DIR/Contents/"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/"
cp Resources/AppIcon.png "$APP_DIR/Contents/Resources/"
"$PLIST_BUDDY" -c "Set :CFBundleShortVersionString ${APP_MARKETING_VERSION}" "$APP_DIR/Contents/Info.plist"
"$PLIST_BUDDY" -c "Set :CFBundleVersion ${APP_BUILD_VERSION}" "$APP_DIR/Contents/Info.plist"

echo "Applying code signature..."
if [ -n "${DEVELOPER_ID:-}" ]; then
    SIGN_ID="Developer ID Application: $DEVELOPER_ID"
    echo "  Signing with Developer ID: $DEVELOPER_ID"

    # Sign Sparkle's nested XPC services individually first
    for xpc in "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/"*.xpc; do
        [ -d "$xpc" ] && codesign --force --options runtime --sign "$SIGN_ID" "$xpc"
    done

    codesign --force --deep --options runtime --entitlements Resources/OpenAssist.entitlements --sign "$SIGN_ID" "$APP_DIR"
else
    echo "  No DEVELOPER_ID set — using ad-hoc signature."
    echo "  (Set DEVELOPER_ID env var for distribution-ready signing)"
    codesign --force --deep --sign - "$APP_DIR"
fi

if [ "$MAKE_DMG" = true ]; then
    echo "Creating professional drag-and-drop DMG at ${DMG_FINAL}..."
    rm -f "$DMG_FINAL"

    # Use create-dmg to build a professional-looking installer with an arrow background
    # and correct icon positions
    npx -y create-dmg "$APP_DIR_ABS" "$DIST_DIR_ABS/" --overwrite --no-version-in-filename --icon-size 128
fi

if [ "$INSTALL_APP" = true ]; then
    echo "Installing to /Applications..."
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
    sleep 1
    rm -rf "${INSTALL_DIR}-new"
    cp -R "$APP_DIR" "${INSTALL_DIR}-new"
    rm -rf "$INSTALL_DIR"
    mv "${INSTALL_DIR}-new" "$INSTALL_DIR"

    echo "Resetting Accessibility permission..."
    sudo tccutil reset Accessibility "$APP_BUNDLE_ID" || echo "  (sudo failed — run manually: sudo tccutil reset Accessibility ${APP_BUNDLE_ID})"

    echo ""
    echo "Build complete! Installed to ${INSTALL_DIR}"
    echo "Run with: open ${INSTALL_DIR}"
    if [ "$MAKE_DMG" = true ]; then
        echo "Drag-and-drop installer created at: ${DMG_FINAL}"
    fi
    echo "Then re-grant Accessibility access in System Settings -> Privacy & Security -> Accessibility"
else
    echo ""
    echo "Build complete! App bundle at: ${APP_DIR}"
    if [ "$MAKE_DMG" = true ]; then
        echo "Drag-and-drop installer ready at: ${DMG_FINAL}"
        echo "Open installer with: open ${DMG_FINAL}"
    fi
    echo "Run app directly with: open ${APP_DIR}"
    echo "To install to /Applications, run: ./build.sh --install"
fi
