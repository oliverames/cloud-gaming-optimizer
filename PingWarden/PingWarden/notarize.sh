#!/bin/bash
#
#  notarize.sh
#  Notarize Ping Warden for distribution
#
#  Usage: ./notarize.sh [version]
#  Example: ./notarize.sh 2.1.1
#
#  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
#  Licensed under the MIT License.
#

set -euo pipefail

# Resolve paths relative to this script so execution is cwd-independent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
APP_NAME="Ping Warden"
VERSION="${1:-2.2.1}"
BUNDLE_ID="com.amesvt.pingwarden"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-notarytool-profile}"  # Must match setup in NOTARIZATION_GUIDE.md
TEAM_ID="PV3W52NDZ3"  # Apple Developer Team ID

# Pre-flight: confirm notarytool credentials are configured before we burn time
# building/staging an archive that we can't actually submit.
if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    echo "Error: notarytool keychain profile '$KEYCHAIN_PROFILE' is not configured." >&2
    echo "Run: xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\"" >&2
    exit 1
fi

# Paths
BUILD_DIR="$PROJECT_ROOT/build"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_NAME="$PROJECT_ROOT/PingWarden-${VERSION}.dmg"
ZIP_NAME="$PROJECT_ROOT/PingWarden-${VERSION}.zip"
CREATE_DMG_SCRIPT="$PROJECT_ROOT/create-dmg.sh"
APP_ENTITLEMENTS="$PROJECT_ROOT/PingWarden/PingWarden.entitlements"
WIDGET_ENTITLEMENTS="$PROJECT_ROOT/PingWardenWidget/PingWardenWidget.entitlements"
STAGING_DIR=""
STAGED_APP_PATH=""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

cleanup() {
    if [ -f "$ZIP_NAME" ]; then
        rm "$ZIP_NAME"
    fi
    if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
        rm -r "$STAGING_DIR"
    fi
}
trap cleanup EXIT

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Ping Warden Notarization Script v${VERSION}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 1: Verify app exists
if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}Error: ${APP_PATH} not found${NC}"
    echo "Please build the app in Xcode first:"
    echo "  1. Product → Archive"
    echo "  2. Export as Developer ID signed app"
    echo "  3. Move to ${BUILD_DIR}/"
    exit 1
fi

echo -e "${GREEN}✓${NC} App bundle found"

# Step 1.25: Stage app in a local temp directory to avoid iCloud metadata xattrs
if ! command -v rsync >/dev/null 2>&1; then
    echo -e "${RED}Error: rsync is required for notarization staging${NC}"
    exit 1
fi

STAGING_DIR="$(mktemp -d /tmp/pingwarden-notary.XXXXXX)"
STAGED_APP_PATH="$STAGING_DIR/${APP_NAME}.app"

echo "Preparing staging copy..."
rsync -a "$APP_PATH/" "$STAGED_APP_PATH/"
echo -e "${GREEN}✓${NC} Staging copy ready"

# Step 1.5: Validate Sparkle configuration used at runtime
SPARKLE_FEED_URL=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$STAGED_APP_PATH/Contents/Info.plist" 2>/dev/null || true)
SPARKLE_PUBLIC_ED_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$STAGED_APP_PATH/Contents/Info.plist" 2>/dev/null || true)
SPARKLE_PUBLIC_ED_KEY=$(echo "$SPARKLE_PUBLIC_ED_KEY" | tr -d '[:space:]')

if [ -z "$SPARKLE_FEED_URL" ]; then
    echo -e "${RED}Error: SUFeedURL is missing in $STAGED_APP_PATH/Contents/Info.plist${NC}"
    echo "Sparkle updater will fail to start without a feed URL."
    exit 1
fi

if [ -z "$SPARKLE_PUBLIC_ED_KEY" ]; then
    echo -e "${RED}Error: SUPublicEDKey is missing or empty in $STAGED_APP_PATH/Contents/Info.plist${NC}"
    echo "Sparkle updater will fail to start without a valid EdDSA public key."
    exit 1
fi

echo -e "${GREEN}✓${NC} Sparkle feed and EdDSA public key present"

# Step 1.6: Validate compiled app icon from icon composer is present in bundle
APP_ICON_PATH="$STAGED_APP_PATH/Contents/Resources/AppIcon.icns"
if [ ! -f "$APP_ICON_PATH" ]; then
    echo -e "${RED}Error: App icon not found at $APP_ICON_PATH${NC}"
    echo "Xcode should compile PingWarden/AppIcon.icon into AppIcon.icns during build."
    exit 1
fi

echo -e "${GREEN}✓${NC} Compiled app icon present (AppIcon.icns)"

# Step 1.75: Re-sign Sparkle helper binaries for distribution notarization
SPARKLE_FRAMEWORK_ROOT="$STAGED_APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK_ROOT/Versions/B"

APP_DEVELOPER_IDENTITY=$(codesign -dvv "$STAGED_APP_PATH" 2>&1 | awk -F= '/^Authority=Developer ID Application:/ {print $2; exit}')
if [ -z "$APP_DEVELOPER_IDENTITY" ]; then
    echo -e "${RED}Error: Could not determine Developer ID identity from staged app${NC}"
    exit 1
fi

echo "Re-signing distribution payload with secure timestamps..."

if [ -d "$SPARKLE_VERSION_DIR" ]; then
    if [ -d "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" ]; then
        codesign -f -s "$APP_DEVELOPER_IDENTITY" -o runtime --timestamp "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
    fi
    
    if [ -d "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" ]; then
        codesign -f -s "$APP_DEVELOPER_IDENTITY" -o runtime --timestamp --preserve-metadata=entitlements "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
    fi
    
    if [ -f "$SPARKLE_VERSION_DIR/Autoupdate" ]; then
        codesign -f -s "$APP_DEVELOPER_IDENTITY" -o runtime --timestamp "$SPARKLE_VERSION_DIR/Autoupdate"
    fi
    
    if [ -d "$SPARKLE_VERSION_DIR/Updater.app" ]; then
        codesign -f -s "$APP_DEVELOPER_IDENTITY" -o runtime --timestamp "$SPARKLE_VERSION_DIR/Updater.app"
    fi
    codesign -f -s "$APP_DEVELOPER_IDENTITY" -o runtime --timestamp "$SPARKLE_FRAMEWORK_ROOT"
fi

HELPER_BINARY_PATH="$STAGED_APP_PATH/Contents/MacOS/PingWardenHelper"
if [ -f "$HELPER_BINARY_PATH" ]; then
    codesign -f -s "$APP_DEVELOPER_IDENTITY" -o runtime --timestamp "$HELPER_BINARY_PATH"
fi

WIDGET_APPEX_PATH="$STAGED_APP_PATH/Contents/PlugIns/PingWardenWidget.appex"
WIDGET_BINARY_PATH="$WIDGET_APPEX_PATH/Contents/MacOS/PingWardenWidget"
if [ -d "$WIDGET_APPEX_PATH" ]; then
    if [ ! -f "$WIDGET_ENTITLEMENTS" ]; then
        echo -e "${RED}Error: Widget entitlements not found at $WIDGET_ENTITLEMENTS${NC}"
        exit 1
    fi
    if [ -f "$WIDGET_BINARY_PATH" ]; then
        codesign -f -s "$APP_DEVELOPER_IDENTITY" -o runtime --timestamp --entitlements "$WIDGET_ENTITLEMENTS" "$WIDGET_BINARY_PATH"
    fi
    codesign -f -s "$APP_DEVELOPER_IDENTITY" -o runtime --timestamp --entitlements "$WIDGET_ENTITLEMENTS" "$WIDGET_APPEX_PATH"
fi

if [ ! -f "$APP_ENTITLEMENTS" ]; then
    echo -e "${RED}Error: App entitlements not found at $APP_ENTITLEMENTS${NC}"
    exit 1
fi
codesign -f -s "$APP_DEVELOPER_IDENTITY" -o runtime --timestamp --entitlements "$APP_ENTITLEMENTS" --preserve-metadata=requirements,flags "$STAGED_APP_PATH"

echo -e "${GREEN}✓${NC} Distribution payload re-signed for notarization"

# Ensure debug entitlement is not present in distribution payload.
if codesign -d --entitlements :- "$STAGED_APP_PATH" 2>/dev/null | grep -q "com.apple.security.get-task-allow"; then
    echo -e "${RED}Error: get-task-allow entitlement still present in staged app${NC}"
    exit 1
fi

# Step 2: Verify code signing
echo ""
echo "Verifying code signature..."
if ! codesign --verify --deep --strict --verbose=2 "$STAGED_APP_PATH" 2>&1 | grep -q "satisfies"; then
    echo -e "${RED}Error: App is not properly code signed${NC}"
    echo "Make sure you built with Developer ID Application certificate"
    exit 1
fi

# Check for Developer ID signature (not ad-hoc)
SIGNING_IDENTITY=$(codesign -dvv "$STAGED_APP_PATH" 2>&1 | grep "Authority=Developer ID Application" || true)
if [ -z "$SIGNING_IDENTITY" ]; then
    echo -e "${RED}Error: App is not signed with Developer ID Application certificate${NC}"
    echo "Current signature:"
    codesign -dvv "$STAGED_APP_PATH" 2>&1 | grep "Authority"
    echo ""
    echo "Please sign with Developer ID certificate in Xcode"
    exit 1
fi

echo -e "${GREEN}✓${NC} Code signature valid"
echo "  ${SIGNING_IDENTITY}"

# Step 3: Create ZIP for notarization
echo ""
echo "Creating ZIP archive for notarization..."
ditto -c -k --keepParent "$STAGED_APP_PATH" "$ZIP_NAME"

echo -e "${GREEN}✓${NC} Created $(basename "$ZIP_NAME")"

# Step 4: Submit for notarization
echo ""
echo "Submitting to Apple for notarization..."
echo "This may take 1-10 minutes..."
echo ""

SUBMIT_OUTPUT=$(xcrun notarytool submit "$ZIP_NAME" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait 2>&1)

echo "$SUBMIT_OUTPUT"

# Check if submission succeeded
if echo "$SUBMIT_OUTPUT" | grep -q "status: Accepted"; then
    echo ""
    echo -e "${GREEN}✓ Notarization successful!${NC}"
else
    echo ""
    echo -e "${RED}✗ Notarization failed${NC}"
    exit 1
fi

# Step 5: Staple the ticket
echo ""
echo "Stapling notarization ticket..."
xcrun stapler staple "$STAGED_APP_PATH"

echo -e "${GREEN}✓${NC} Ticket stapled successfully"

# Step 6: Create notarized DMG
echo ""
echo "Creating notarized DMG..."
if [ -f "$CREATE_DMG_SCRIPT" ]; then
    "$CREATE_DMG_SCRIPT" "$VERSION" "$STAGED_APP_PATH"
    
    if [ -f "$DMG_NAME" ]; then
        echo ""
        echo "Submitting DMG to Apple for notarization..."
        DMG_SUBMIT_OUTPUT=$(xcrun notarytool submit "$DMG_NAME" \
            --keychain-profile "$KEYCHAIN_PROFILE" \
            --wait 2>&1)
        echo "$DMG_SUBMIT_OUTPUT"
        
        if ! echo "$DMG_SUBMIT_OUTPUT" | grep -q "status: Accepted"; then
            echo -e "${RED}✗ DMG notarization failed${NC}"
            exit 1
        fi
        
        echo -e "${GREEN}✓${NC} DMG notarization successful"
        echo ""
        echo "Stapling DMG..."
        xcrun stapler staple "$DMG_NAME"
        echo -e "${GREEN}✓${NC} DMG stapled"
    fi
fi

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}Notarization Complete!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Notarized files:"
echo "  • ${STAGED_APP_PATH}"
if [ -f "$DMG_NAME" ]; then
    echo "  • $(basename "$DMG_NAME")"
fi
echo ""
echo -e "${GREEN}Done!${NC} 🎉"
echo ""
