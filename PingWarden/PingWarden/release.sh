#!/bin/bash
#
#  release.sh
#  Complete release automation: notarize + create DMG + update appcast +
#  GitHub release + Sentry publish + appcast deploy + Gumroad deliverable
#
#  Usage: ./release.sh [version] [release-notes-file]
#  Example: ./release.sh 2.1.1 release_notes_2.1.1.txt
#
#  Beta releases: prefix the invocation with BETA_CHANNEL=1 to publish to
#  appcast-beta.xml instead of the stable appcast.xml. Use semver beta tags
#  in the version (e.g. 2.4.0-beta.1). The beta appcast lives on the same
#  gh-pages branch and is signed with the same EdDSA key.
#  Example: BETA_CHANNEL=1 ./release.sh 2.4.0-beta.1 release_notes_2.4.0-beta.1.md
#
#  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
#  Licensed under the MIT License.
#

set -euo pipefail

# Resolve paths relative to this script so execution is cwd-independent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)"
VALIDATION_SCRIPT="$REPO_ROOT/scripts/release_validation.sh"
if [ ! -f "$VALIDATION_SCRIPT" ]; then
    echo "Error: release validation library not found at $VALIDATION_SCRIPT" >&2
    exit 1
fi
# The path is resolved from this script's repository root.
# shellcheck disable=SC1090,SC1091
source "$VALIDATION_SCRIPT"

# Configuration
VERSION="${1:-}"
RELEASE_NOTES="${2:-RELEASE_NOTES.md}"
APP_NAME="Ping Warden"
DMG_BASENAME="PingWarden-${VERSION}.dmg"
DMG_PATH="$PROJECT_ROOT/$DMG_BASENAME"
BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE_PATH="/tmp/PingWarden-${VERSION}.xcarchive"
ARCHIVED_APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
SPARKLE_KEYCHAIN_ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-ed25519}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-notarytool-profile}"
GITHUB_USER="oliverames"
REPO_NAME="ping-warden"
# Gumroad product that sells the license. The release DMG is attached as the
# product's download deliverable (Step 9). qthvm is the product ID the
# gumroad CLI resolves; override with GUMROAD_PRODUCT_ID=... if it changes.
GUMROAD_PRODUCT_ID="${GUMROAD_PRODUCT_ID:-qthvm}"
NOTARIZE_SCRIPT="$SCRIPT_DIR/notarize.sh"
PYTHON_BIN="${PYTHON_BIN:-/opt/homebrew/bin/python3}"
STABLE_APPCAST="$REPO_ROOT/appcast.xml"
BETA_APPCAST="$REPO_ROOT/appcast-beta.xml"
APPCAST_UPDATER="$REPO_ROOT/scripts/update_appcast.py"
GUMROAD_PUBLISHER="$REPO_ROOT/scripts/publish_gumroad.py"


# Beta-channel branching: BETA_CHANNEL=1 writes to appcast-beta.xml and uses
# distinct channel metadata in the appcast skeleton. The DMG/GitHub release
# path is identical; only the appcast target file changes. Sparkle picks the
# right channel at runtime via SPUUpdaterDelegate.feedURLString(for:).
if [ "${BETA_CHANNEL:-0}" = "1" ]; then
    APPCAST_BASENAME="appcast-beta.xml"
    APPCAST_CHANNEL_TITLE="Ping Warden Beta Updates"
    APPCAST_CHANNEL_DESCRIPTION="Pre-release updates for Ping Warden"
else
    APPCAST_BASENAME="appcast.xml"
    APPCAST_CHANNEL_TITLE="Ping Warden Updates"
    APPCAST_CHANNEL_DESCRIPTION="Updates for Ping Warden"
fi
APPCAST_FILE="$REPO_ROOT/$APPCAST_BASENAME"
NOTARYTOOL_ARGS=()

if [ -z "$VERSION" ]; then
    echo "Error: version is required" >&2
    echo "Usage: ./release.sh X.Y.Z [release-notes-file]" >&2
    exit 1
fi
validate_release_version "$VERSION"

if [[ "$VERSION" == *-* ]] && [ "${BETA_CHANNEL:-0}" != "1" ]; then
    echo "Error: prerelease version '$VERSION' requires BETA_CHANNEL=1" >&2
    exit 1
fi
if [[ "$VERSION" != *-* ]] && [ "${BETA_CHANNEL:-0}" = "1" ]; then
    echo "Error: BETA_CHANNEL=1 requires an alpha, beta, or rc version" >&2
    exit 1
fi

# Fail before building if a required publication surface is unavailable.
command -v gh >/dev/null || { echo "Error: gh is required to publish release downloads" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Error: GitHub authentication is required" >&2; exit 1; }
REMOTE_TAG=$(git -C "$REPO_ROOT" ls-remote --tags origin "refs/tags/v$VERSION")
if [ -n "$REMOTE_TAG" ]; then
    echo "Error: v$VERSION already exists; a full release requires a new version and tag." >&2
    exit 1
fi
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "Error: full releases must notarize their fresh archive; reusing a same-version DMG can publish stale code." >&2
    exit 1
fi
if [ "${BETA_CHANNEL:-0}" != "1" ] && [ "${SKIP_GUMROAD:-0}" != "1" ]; then
    "$PYTHON_BIN" "$GUMROAD_PUBLISHER" "$GUMROAD_PRODUCT_ID" --check
fi
BUILD_CHECK_ARGS=(--stable "$STABLE_APPCAST" --beta "$BETA_APPCAST" --check-build "$(plist_value "$SCRIPT_DIR/Info.plist" CFBundleVersion)")
if [ "${BETA_CHANNEL:-0}" = "1" ]; then BUILD_CHECK_ARGS+=(--beta-release); fi
"$PYTHON_BIN" "$APPCAST_UPDATER" "${BUILD_CHECK_ARGS[@]}"

if [ -n "${NOTARYTOOL_KEY:-}" ] && [ -n "${NOTARYTOOL_KEY_ID:-}" ] && [ -n "${NOTARYTOOL_ISSUER_ID:-}" ]; then
    NOTARYTOOL_ARGS=(--key "$NOTARYTOOL_KEY" --key-id "$NOTARYTOOL_KEY_ID" --issuer "$NOTARYTOOL_ISSUER_ID")
else
    NOTARYTOOL_ARGS=(--keychain-profile "$KEYCHAIN_PROFILE")
fi

# Pre-flight credential checks. Both blocks fail fast so we don't go through
# 5+ minutes of build/sign/notarize only to discover at the end that an
# enrichment step (dSYM upload) was going to silently no-op the whole time.
# SKIP_SENTRY=1 is an explicit opt-out for crash-symbol publication.
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    if ! xcrun notarytool history "${NOTARYTOOL_ARGS[@]}" >/dev/null 2>&1; then
        echo "Error: notarytool credentials are not configured or not readable." >&2
        echo "Provide either keychain profile '$KEYCHAIN_PROFILE' or NOTARYTOOL_KEY, NOTARYTOOL_KEY_ID, and NOTARYTOOL_ISSUER_ID." >&2
        exit 1
    fi
fi

# Sentry pre-flight. We require sentry-cli, op CLI, and a readable token in
# the vault. Anything missing -> abort here, before notarization. The previous
# inline checks in Step 7 would have *warned and continued*, which means a
# Mac without the tooling could ship a release with no dSYMs uploaded and
# the maintainer would only notice weeks later when crashes came in
# unsymbolicated. That failure mode is closed by checking up-front.
if [ "${SKIP_SENTRY:-0}" != "1" ]; then
    # Match the runtime PATH that Step 7 uses so this check sees the same binaries.
    export PATH="$HOME/.local/bin:$PATH"
    SENTRY_PREFLIGHT_OK=1
    if ! command -v sentry-cli >/dev/null 2>&1; then
        echo "Error: sentry-cli not on PATH." >&2
        echo "  Install: curl -sSfL https://sentry.io/get-cli/ | INSTALL_DIR=\"\$HOME/.local/bin\" bash" >&2
        SENTRY_PREFLIGHT_OK=0
    fi
    if ! command -v op >/dev/null 2>&1; then
        echo "Error: 1Password CLI (op) not on PATH." >&2
        echo "  Install: brew install 1password-cli" >&2
        SENTRY_PREFLIGHT_OK=0
    fi
    if [ "$SENTRY_PREFLIGHT_OK" = "1" ]; then
        if ! op read "op://Development/PingWarden Sentry API Token/credential" >/dev/null 2>&1; then
            echo "Error: Cannot read Sentry token from 1Password." >&2
            echo "  Expected vault item: 'PingWarden Sentry API Token' in 'Development'." >&2
            SENTRY_PREFLIGHT_OK=0
        fi
    fi
    if [ "$SENTRY_PREFLIGHT_OK" != "1" ]; then
        echo "Or set SKIP_SENTRY=1 to skip Sentry upload (not recommended for production releases)." >&2
        exit 1
    fi
fi

if [[ "$RELEASE_NOTES" = /* ]]; then
    RELEASE_NOTES_PATH="$RELEASE_NOTES"
elif [ -f "$RELEASE_NOTES" ]; then
    RELEASE_NOTES_PATH="$(cd "$(dirname "$RELEASE_NOTES")" && pwd)/$(basename "$RELEASE_NOTES")"
else
    if [ -f "$PROJECT_ROOT/$RELEASE_NOTES" ]; then
        RELEASE_NOTES_PATH="$PROJECT_ROOT/$RELEASE_NOTES"
    else
        RELEASE_NOTES_PATH="$REPO_ROOT/$RELEASE_NOTES"
    fi
fi
if [ ! -f "$RELEASE_NOTES_PATH" ]; then
    echo "Error: release notes not found: $RELEASE_NOTES_PATH" >&2
    exit 1
fi
RENDER_SCRIPT="$REPO_ROOT/scripts/render_release_notes.sh"
RELEASE_NOTES_HTML=$("$RENDER_SCRIPT" "$VERSION" --html "$RELEASE_NOTES_PATH")

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
    echo -e "${RED}Error: release worktree is not clean${NC}" >&2
    echo "Commit the complete, verified release source before building and publishing." >&2
    git -C "$REPO_ROOT" status --short >&2
    exit 1
fi

CURRENT_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD)
if command -v gh >/dev/null 2>&1; then
    # `gh release create` defaults new tags to the remote default branch.
    # If the release commit exists only locally, GitHub can otherwise tag an
    # older commit while the DMG was built from the local tree.
    if ! gh api "repos/$GITHUB_USER/$REPO_NAME/commits/$CURRENT_SHA" >/dev/null 2>&1; then
        echo -e "${RED}Error: current commit is not reachable on GitHub:${NC} $CURRENT_SHA" >&2
        echo "Push the release commit before running release.sh so v$VERSION tags the built source." >&2
        exit 1
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ${BLUE}Ping Warden Release Automation v${VERSION}${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 1: Produce a fresh unsigned archive and stage its app. The archive is
# the source of both the release payload and the dSYMs uploaded later, so a
# stale app in build/ can never be paired with a newer source commit.
echo -e "${GREEN}Step 1: Building release archive...${NC}"
rm -rf "$ARCHIVE_PATH"
xcodebuild archive \
    -project "$PROJECT_ROOT/PingWarden.xcodeproj" \
    -scheme PingWarden \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO

if [ ! -d "$ARCHIVED_APP_PATH" ]; then
    echo -e "${RED}Error: archive did not contain $ARCHIVED_APP_PATH${NC}" >&2
    exit 1
fi
if [ ! -d "$ARCHIVE_PATH/dSYMs" ]; then
    echo -e "${RED}Error: archive did not contain dSYMs${NC}" >&2
    exit 1
fi
validate_app_artifact "$ARCHIVED_APP_PATH" "$VERSION" 0

mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_DIR/$APP_NAME.app"
rsync -a "$ARCHIVED_APP_PATH/" "$BUILD_DIR/$APP_NAME.app/"
echo -e "${GREEN}✓ Fresh archive and staged app verified${NC}"
echo ""

# Step 2: Notarize (or reuse existing notarized DMG)
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo -e "${YELLOW}Step 2: Skipping notarization (SKIP_NOTARIZE=1)${NC}"
else
    echo -e "${GREEN}Step 2: Notarizing app...${NC}"
    if ! "$NOTARIZE_SCRIPT" "$VERSION"; then
        echo -e "${RED}Notarization failed!${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Notarization complete${NC}"
fi
echo ""

# Verify DMG exists
if [ ! -f "$DMG_PATH" ]; then
    echo -e "${RED}Error: DMG not found: $DMG_PATH${NC}"
    echo "notarize.sh should have created it"
    exit 1
fi

echo -e "${GREEN}✓ DMG found: $(basename "$DMG_PATH")${NC}"
echo ""

# Always validate the mounted DMG. Never sign
# update metadata for an unnotarized, stale, or incorrectly versioned payload.
echo -e "${GREEN}Validating release artifact...${NC}"
if ! validate_dmg_artifact "$DMG_PATH" "$VERSION" 1; then
    echo -e "${RED}Error: DMG artifact validation failed${NC}" >&2
    exit 1
fi
ARTIFACT_BUILD_VERSION="$VALIDATED_BUNDLE_VERSION"
MINIMUM_SYSTEM_VERSION="$VALIDATED_MINIMUM_SYSTEM_VERSION"
echo -e "${GREEN}✓ Artifact v$VALIDATED_SHORT_VERSION (build $ARTIFACT_BUILD_VERSION), macOS $MINIMUM_SYSTEM_VERSION+${NC}"
echo ""

# Step 3: Sign update for Sparkle (required)
echo -e "${GREEN}Step 3: Signing update for Sparkle...${NC}"

# Locate the sign_update tool. Sparkle SPM puts it under the user's DerivedData,
# but the path varies by Xcode version, scheme name and hash. Searching ~ is
# slow and unreliable, so prefer xcrun --find first; fall back to a bounded
# DerivedData search only if that fails.
SIGN_TOOL=""
if command -v xcrun >/dev/null 2>&1; then
    SIGN_TOOL=$(xcrun --find sign_update 2>/dev/null || true)
fi
if [ -z "$SIGN_TOOL" ]; then
    # Depth 7 path under DerivedData:
    # <project-hash>/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
    SIGN_TOOL=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
                     -maxdepth 8 -type f -name "sign_update" -perm -u+x -print -quit 2>/dev/null || true)
fi

if [ -z "$SIGN_TOOL" ] || [ ! -x "$SIGN_TOOL" ]; then
    echo -e "${RED}Error: sign_update tool not found${NC}"
    echo "Build the Sparkle SPM package once so DerivedData contains sign_update,"
    echo "or install the Sparkle command-line tools system-wide."
    exit 1
fi

# The Sparkle private key remains in Keychain. File-based fallbacks risk
# accidentally persisting release credentials outside the canonical store.
SIGNATURE=""
if SIGNATURE=$("$SIGN_TOOL" "$DMG_PATH" --account "$SPARKLE_KEYCHAIN_ACCOUNT" -p 2>/dev/null | tr -d '\r\n') && [ -n "$SIGNATURE" ]; then
    :
fi

if [ -z "$SIGNATURE" ]; then
    echo -e "${RED}Error: Sparkle signature generation returned an empty signature${NC}"
    echo "Ensure the EdDSA key exists in the login keychain account '$SPARKLE_KEYCHAIN_ACCOUNT'."
    exit 1
fi

PUBLIC_KEY=$(plist_value "$BUILD_DIR/$APP_NAME.app/Contents/Info.plist" SUPublicEDKey)
SIGNING_PUBLIC_KEY=$("$(dirname "$SIGN_TOOL")/generate_keys" --account "$SPARKLE_KEYCHAIN_ACCOUNT" -p)
if [ "$PUBLIC_KEY" != "$SIGNING_PUBLIC_KEY" ]; then
    echo "Error: Sparkle signing key does not match the app's embedded public key" >&2
    exit 1
fi
if ! "$SIGN_TOOL" --account "$SPARKLE_KEYCHAIN_ACCOUNT" --verify "$DMG_PATH" "$SIGNATURE" >/dev/null; then
    echo -e "${RED}Error: Sparkle archive signature did not verify${NC}" >&2
    exit 1
fi

echo -e "${GREEN}✓ Signature: ${SIGNATURE}${NC}"

echo ""

# Step 4: Get file size and date
DMG_SIZE=$(stat -f%z "$DMG_PATH")
# LC_ALL=C keeps day/month names English (RFC 822 requires them; a localized
# LC_TIME would emit names Sparkle's date parser rejects), and +0000 is used
# because "UTC" is not a valid RFC 822 zone token.
DMG_DATE=$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")

echo -e "${GREEN}Step 4: Preparing release metadata...${NC}"
echo "  Version: $VERSION"
echo "  DMG Size: $DMG_SIZE bytes"
echo "  Date: $DMG_DATE"
echo ""

# Step 5: Update appcast.xml
echo -e "${GREEN}Step 5: Updating appcast.xml...${NC}"

# Check if appcast exists
if [ ! -f "$APPCAST_FILE" ]; then
    echo "Creating new $APPCAST_BASENAME"
    cat > "$APPCAST_FILE" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>$APPCAST_CHANNEL_TITLE</title>
    <link>https://$GITHUB_USER.github.io/$REPO_NAME/$APPCAST_BASENAME</link>
    <description>$APPCAST_CHANNEL_DESCRIPTION</description>
    <language>en</language>
  </channel>
</rss>
EOF
fi

# Paid-upgrade disclosures must be present in the update window, so rendering
# failure is a release blocker rather than a reason to publish a generic stub.
[ -n "$RELEASE_NOTES_HTML" ] || { echo "Error: release notes are empty" >&2; exit 1; }

# Critical update marker. Adds <sparkle:criticalUpdate/> to the appcast item
# so Sparkle treats this version as required for all users on prior
# versions — prompt is more prominent and Skip This Version is disabled.
# Use for releases that fix security/stability issues or land
# observability the maintainer needs everyone on (e.g. crash reporting).
# Invoke with: CRITICAL_UPDATE=1 release.sh X.Y.Z
if [ "${CRITICAL_UPDATE:-0}" = "1" ]; then
    CRITICAL_UPDATE_TAG="
      <sparkle:criticalUpdate />"
    echo "  ✓ marking v$VERSION as a critical update (recommended for all users)"
else
    CRITICAL_UPDATE_TAG=""
fi

# Create new item entry
NEW_ITEM="    <item xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\">
      <title>Version $VERSION</title>
      <link>https://github.com/$GITHUB_USER/$REPO_NAME/releases/tag/v$VERSION</link>
      <sparkle:version>$ARTIFACT_BUILD_VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <description><![CDATA[
$RELEASE_NOTES_HTML
      ]]></description>$CRITICAL_UPDATE_TAG
      <pubDate>$DMG_DATE</pubDate>
      <enclosure
        url=\"https://github.com/$GITHUB_USER/$REPO_NAME/releases/download/v$VERSION/$DMG_BASENAME\"
        sparkle:version=\"$ARTIFACT_BUILD_VERSION\"
        sparkle:shortVersionString=\"$VERSION\"
        length=\"$DMG_SIZE\"
        type=\"application/octet-stream\"
        $([ -n "$SIGNATURE" ] && echo "sparkle:edSignature=\"$SIGNATURE\"")
      />
      <sparkle:minimumSystemVersion>$MINIMUM_SYSTEM_VERSION</sparkle:minimumSystemVersion>
    </item>"

# Replace by version and normalize every paid entry before final signing.
# Stable entries also reach the beta endpoint, including its existing users.
INSERT_FILE=$(mktemp -t pingwarden-appcast-item)
printf "%s\n" "$NEW_ITEM" > "$INSERT_FILE"
APPCAST_ARGS=(--stable "$STABLE_APPCAST" --beta "$BETA_APPCAST" --item "$INSERT_FILE")
if [ "${BETA_CHANNEL:-0}" = "1" ]; then APPCAST_ARGS+=(--beta-release); fi
"$PYTHON_BIN" "$APPCAST_UPDATER" "${APPCAST_ARGS[@]}"
rm -f "$INSERT_FILE"
for FEED in "$STABLE_APPCAST" "$BETA_APPCAST"; do
    xmllint --noout "$FEED"
    "$SIGN_TOOL" "$FEED" --account "$SPARKLE_KEYCHAIN_ACCOUNT" --disable-signing-warning
    "$SIGN_TOOL" --account "$SPARKLE_KEYCHAIN_ACCOUNT" --verify "$FEED" >/dev/null
    swift "$REPO_ROOT/scripts/verify_sparkle.swift" "$FEED" "$PUBLIC_KEY"
done
echo -e "${GREEN}✓ Stable and beta appcasts signed and verified${NC}"

# Step 6: Create GitHub release
echo -e "${GREEN}Step 6: Creating GitHub release...${NC}"

if ! command -v gh &> /dev/null; then
    echo -e "${YELLOW}⚠ GitHub CLI (gh) not installed${NC}"
    echo ""
    echo "To create release manually:"
    echo "1. Go to https://github.com/$GITHUB_USER/$REPO_NAME/releases/new"
    echo "2. Tag: v$VERSION"
    echo "3. Title: Ping Warden v$VERSION"
    echo "4. Upload: $DMG_PATH"
    echo "5. Copy notes from $RELEASE_NOTES"
    echo ""
else
    # Betas (and any semver pre-release tag) must be marked --prerelease or
    # GitHub promotes them to "latest release", pointing the README badge and
    # releases/latest at a beta DMG for stable users.
    # Prefer just this version's section from RELEASE_NOTES.md; the file
    # passed as $2 is the full multi-version history, and using it verbatim
    # put every release's notes on every release page.
    VERSION_NOTES_FILE=$(mktemp -t pingwarden-release-notes)
    "$RENDER_SCRIPT" "$VERSION" --markdown "$RELEASE_NOTES_PATH" > "$VERSION_NOTES_FILE"
    GH_NOTES_ARGS=(--notes-file "$VERSION_NOTES_FILE")

    # Build one non-empty argument array. macOS still ships Bash 3.2, where
    # expanding an empty array under `set -u` fails with "unbound variable".
    # That used to stop stable releases because only prereleases add an
    # optional flag.
    GH_RELEASE_ARGS=(
        release create "v$VERSION"
        "$DMG_PATH"
        --title "Ping Warden v$VERSION"
        --target "$CURRENT_SHA"
    )
    if [ "${BETA_CHANNEL:-0}" = "1" ] || [[ "$VERSION" == *-* ]]; then
        GH_RELEASE_ARGS+=(--prerelease)
        echo "  ✓ marking GitHub release as pre-release"
    fi
    GH_RELEASE_ARGS+=("${GH_NOTES_ARGS[@]}")

    gh "${GH_RELEASE_ARGS[@]}"

    echo -e "${GREEN}✓ GitHub release created${NC}"
fi

echo ""

# Step 7: Upload dSYMs and tag the release in Sentry.
#
# Sentry needs the dSYMs to symbolicate crash reports — without them the
# stacks are raw memory addresses. We also create a release object so
# crashes can be filtered/grouped by version.
#
# Auth token comes from 1Password at runtime via `op read`; never written
# to disk and never committed. Fail-soft: if sentry-cli or `op` are
# missing, or SKIP_SENTRY=1 is set, we warn and continue with the release.
SENTRY_RELEASE="com.amesvt.pingwarden@${VERSION}"
SENTRY_ORG="ames-consulting-llc"
SENTRY_PROJECT="ping-warden"
XCARCHIVE_DSYMS="$ARCHIVE_PATH/dSYMs"

# Prepend the official sentry-cli install path so the official binary at
# ~/.local/bin wins over any older brew-tap install on $PATH.
export PATH="$HOME/.local/bin:$PATH"

echo -e "${GREEN}Step 7: Publishing release to Sentry...${NC}"

if [ "${SKIP_SENTRY:-0}" = "1" ]; then
    echo -e "${YELLOW}SKIP_SENTRY=1 set; skipping Sentry upload.${NC}"
elif [ ! -d "$XCARCHIVE_DSYMS" ]; then
    # This case is the only thing pre-flight couldn't validate (xcarchive
    # is produced by notarize.sh earlier in this run). If it's still
    # missing here, something upstream went wrong and we shouldn't
    # quietly skip — abort so gh-pages doesn't get pushed without dSYMs.
    echo -e "${RED}Error: No dSYMs found at $XCARCHIVE_DSYMS${NC}" >&2
    echo "notarize.sh should have produced the xcarchive there." >&2
    exit 1
else
    # Pre-flight validated sentry-cli, op, and token readability. Read the
    # token now into env for the duration of this block only.
    SENTRY_AUTH_TOKEN=$(op read "op://Development/PingWarden Sentry API Token/credential")
    export SENTRY_AUTH_TOKEN
    export SENTRY_ORG SENTRY_PROJECT
    export SENTRY_LOG_LEVEL=warn

    # Sentry is enrichment, not a release gate. GitHub has already published
    # by this point; a network blip during one sentry-cli call must not abort
    # the script before gh-pages gets updated. The subshell + set +e localizes
    # the relaxed error handling, and the trailing summary makes any failures
    # visible rather than silently passing.
    # Keep the subshell inside an `if` so its non-zero exit is exempt from the
    # outer `set -e`. Capture the status in the `else` branch before another
    # command can overwrite `$?`.
    SENTRY_FAILURES=0
    if (
        set +e
        sentry-cli debug-files upload "$XCARCHIVE_DSYMS" || exit 1
        sentry-cli releases new "$SENTRY_RELEASE" || exit 2
        sentry-cli releases set-commits "$SENTRY_RELEASE" --auto || true  # needs repo integration; non-fatal
        sentry-cli releases finalize "$SENTRY_RELEASE" || exit 4
        exit 0
    ); then
        :
    else
        SENTRY_FAILURES=$?
    fi

    unset SENTRY_AUTH_TOKEN SENTRY_ORG SENTRY_PROJECT SENTRY_LOG_LEVEL
    if [ "$SENTRY_FAILURES" = "0" ]; then
        echo -e "${GREEN}✓ Sentry release published: $SENTRY_RELEASE${NC}"
    else
        echo -e "${RED}⚠ Sentry step exited with code $SENTRY_FAILURES — check above. Release continues.${NC}"
    fi
fi

echo ""

# Step 8: Publish from an isolated checkout; never switch or stash the source.
echo -e "${GREEN}Step 8: Publishing appcasts to gh-pages...${NC}"
if [ "${SKIP_GH_PAGES:-0}" = "1" ]; then
    echo -e "${YELLOW}SKIP_GH_PAGES=1 set; skipping gh-pages publish.${NC}"
else
    git -C "$REPO_ROOT" fetch --quiet origin gh-pages
    PUBLISH_DIR=$(mktemp -d -t pingwarden-publish)
    git -C "$REPO_ROOT" worktree add --quiet --detach "$PUBLISH_DIR" origin/gh-pages
    cleanup_publish() {
        git -C "$REPO_ROOT" worktree remove "$PUBLISH_DIR" || true
    }
    trap cleanup_publish EXIT
    cp "$STABLE_APPCAST" "$PUBLISH_DIR/appcast.xml"
    cp "$BETA_APPCAST" "$PUBLISH_DIR/appcast-beta.xml"
    git -C "$PUBLISH_DIR" add appcast.xml appcast-beta.xml
    if ! git -C "$PUBLISH_DIR" diff --cached --quiet; then
        git -C "$PUBLISH_DIR" commit -m "Update stable and beta appcasts for v$VERSION"
        git -C "$PUBLISH_DIR" push origin HEAD:gh-pages
    fi
    cleanup_publish
    trap - EXIT
    echo -e "${GREEN}✓ Both appcasts published${NC}"
fi

echo ""

# Step 9: Attach the release DMG to the Gumroad product as its download
# deliverable. Gumroad handles the first install; Sparkle (Step 5/8) handles
# every update after that, so the two never conflict.
#
# Stable releases only: a beta DMG must never become the paid deliverable.
# Publication is incomplete until buyer content is verified. On failure,
# rerun scripts/publish_gumroad.py with the product and release DMG.
# SKIP_GUMROAD=1 opts out (e.g. re-running for an already-attached DMG).
echo -e "${GREEN}Step 9: Publishing DMG to Gumroad product...${NC}"

if [ "${BETA_CHANNEL:-0}" = "1" ]; then
    echo -e "${YELLOW}Beta channel; skipping Gumroad deliverable upload.${NC}"
elif [ "${SKIP_GUMROAD:-0}" = "1" ]; then
    echo -e "${YELLOW}SKIP_GUMROAD=1 set; skipping Gumroad upload.${NC}"
else
    "$PYTHON_BIN" "$GUMROAD_PUBLISHER" "$GUMROAD_PRODUCT_ID" "$DMG_PATH"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}Release Complete!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo ""
echo "1. Test the update:"
echo "   - Install an older version"
echo "   - Click 'Check for Updates'"
echo "   - Verify v$VERSION is offered"
echo ""
echo "2. Announce on Reddit:"
echo "   - r/GeForceNOW"
echo "   - r/xcloud"
echo "   - r/macgaming"
echo ""
echo "Release artifacts:"
echo "  • $DMG_PATH"
echo "  • GitHub release: https://github.com/$GITHUB_USER/$REPO_NAME/releases/tag/v$VERSION"
echo "  • Appcast: $APPCAST_FILE (published to gh-pages)"
echo "  • Gumroad deliverable: product '$GUMROAD_PRODUCT_ID' (stable releases; skipped for betas)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
