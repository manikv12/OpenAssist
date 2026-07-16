#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-v1.8.1}"
ZIP_NAME="whisper-${VERSION}-xcframework.zip"
URL="https://github.com/ggml-org/whisper.cpp/releases/download/${VERSION}/${ZIP_NAME}"
DEST_DIR="Vendor/Whisper"
DEST_XCFRAMEWORK="${DEST_DIR}/whisper.xcframework"

mkdir -p "$DEST_DIR"
TMP_DIR="$(mktemp -d)"

echo "Downloading ${URL}..."
curl -fL "$URL" -o "$TMP_DIR/$ZIP_NAME"

echo "Extracting framework..."
unzip -q "$TMP_DIR/$ZIP_NAME" -d "$TMP_DIR/extracted"

SRC_XCFRAMEWORK="$(find "$TMP_DIR/extracted" -type d -name whisper.xcframework | head -n 1)"
if [ -z "$SRC_XCFRAMEWORK" ]; then
    echo "Failed to find whisper.xcframework in downloaded archive"
    exit 1
fi

if [ -d "$DEST_XCFRAMEWORK" ]; then
    BACKUP_PATH="${DEST_XCFRAMEWORK}.backup.$(date +%s)"
    mv "$DEST_XCFRAMEWORK" "$BACKUP_PATH"
    echo "Existing framework moved to ${BACKUP_PATH}"
fi

cp -R "$SRC_XCFRAMEWORK" "$DEST_XCFRAMEWORK"

CHECKSUM="$(swift package compute-checksum "$TMP_DIR/$ZIP_NAME")"

echo ""
echo "whisper framework updated at ${DEST_XCFRAMEWORK}"
echo "Version: ${VERSION}"
echo "Checksum: ${CHECKSUM}"
echo ""
echo "If using URL-based binary target, update checksum in Package.swift."
