#!/bin/bash
#
#  create-dmg.sh
#  Creates a distributable DMG with installation instructions
#
#  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
#  Licensed under the MIT License.
#

set -euo pipefail

# Resolve paths relative to this script so execution is cwd-independent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
APP_NAME="Ping Warden"
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Error: version argument is required (a stale default here once produced" >&2
    echo "DMGs whose filename didn't match their contents)." >&2
    echo "Usage: ./create-dmg.sh <version> [app-path]" >&2
    exit 1
fi
DMG_NAME="PingWarden-${VERSION}"
BUILD_DIR="$SCRIPT_DIR/build"
DMG_PATH="$SCRIPT_DIR/${DMG_NAME}.dmg"
SOURCE_APP_PATH="${2:-${BUILD_DIR}/${APP_NAME}.app}"
DMG_TEMP=""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Creating DMG for ${APP_NAME} v${VERSION}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if app exists
if [ ! -d "$SOURCE_APP_PATH" ]; then
    echo "Error: app bundle not found at $SOURCE_APP_PATH"
    echo "Please build the app first using Xcode"
    exit 1
fi

# Create temp staging directory outside cloud-backed paths to avoid metadata/xattr issues.
DMG_TEMP="$(mktemp -d /tmp/pingwarden-dmg.XXXXXX)"
cleanup() {
    if [ -n "$DMG_TEMP" ] && [ -d "$DMG_TEMP" ]; then
        rm -r "$DMG_TEMP"
    fi
}
trap cleanup EXIT

# Copy app
echo "Copying app bundle..."
# Use rsync so disallowed Finder metadata xattrs do not get embedded in the DMG payload.
rsync -a "$SOURCE_APP_PATH/" "$DMG_TEMP/${APP_NAME}.app/"

# Create a symlink to Applications
echo "Creating Applications symlink..."
ln -s /Applications "$DMG_TEMP/Applications"

# Create DMG
echo "Creating DMG..."
rm -f "$DMG_PATH"

# Create DMG with nice settings
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "$DMG_TEMP" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

# Calculate DMG size
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)

echo ""
echo -e "${GREEN}✓ DMG created successfully!${NC}"
echo ""
echo "  File: $(basename "$DMG_PATH")"
echo "  Size: ${DMG_SIZE}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Test the DMG by mounting it"
echo "  2. Verify all installation methods work"
echo "  3. Upload to GitHub releases"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
