#!/usr/bin/env bash
# Notarize an Open Assist DMG for public distribution.
#
# Prerequisites:
#   1. Apple Developer Program membership
#   2. The DMG must be signed with a Developer ID certificate (see build.sh)
#   3. Set these environment variables:
#        APPLE_ID          — your Apple ID email
#        APPLE_TEAM_ID     — your 10-character Team ID
#        APPLE_APP_PASSWORD — an app-specific password (create at appleid.apple.com)
#
# Usage:
#   Scripts/notarize.sh [path-to-dmg]
#
# If no path is given, defaults to dist/Open Assist.dmg

set -euo pipefail

DMG="${1:-dist/Open Assist.dmg}"

if [ ! -f "$DMG" ]; then
    echo "Error: DMG not found at $DMG"
    echo "Run ./build.sh first to create the DMG."
    exit 1
fi

if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ] || [ -z "${APPLE_APP_PASSWORD:-}" ]; then
    echo "Error: Missing required environment variables."
    echo ""
    echo "Set these before running:"
    echo "  export APPLE_ID=\"you@example.com\""
    echo "  export APPLE_TEAM_ID=\"ABCDE12345\""
    echo "  export APPLE_APP_PASSWORD=\"xxxx-xxxx-xxxx-xxxx\""
    echo ""
    echo "Create an app-specific password at https://appleid.apple.com"
    exit 1
fi

echo "Submitting $DMG for notarization..."
echo "  Apple ID:  $APPLE_ID"
echo "  Team ID:   $APPLE_TEAM_ID"

xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait

echo ""
echo "Stapling notarization ticket to $DMG..."
xcrun stapler staple "$DMG"

echo ""
echo "Done! $DMG is now notarized and ready for distribution."
echo "Recipients can open it without Gatekeeper warnings."
