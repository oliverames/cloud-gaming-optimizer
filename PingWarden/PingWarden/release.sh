#!/bin/bash
#
#  release.sh
#  Complete release automation: notarize + create DMG + update appcast + GitHub release
#
#  Usage: ./release.sh [version] [release-notes-file]
#  Example: ./release.sh 2.1.1 release_notes_2.1.1.txt
#
#  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
#  Licensed under the MIT License.
#

set -euo pipefail

# Resolve paths relative to this script so execution is cwd-independent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)"

# Configuration
VERSION="${1:-}"
RELEASE_NOTES="${2:-RELEASE_NOTES.md}"
APP_NAME="Ping Warden"
BUNDLE_ID="com.amesvt.pingwarden"
DMG_BASENAME="PingWarden-${VERSION}.dmg"
DMG_PATH="$PROJECT_ROOT/$DMG_BASENAME"
BUILD_DIR="$PROJECT_ROOT/build"
SPARKLE_KEY="$HOME/sparkle_private_key"
SPARKLE_KEYCHAIN_ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-ed25519}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-notarytool-profile}"
GITHUB_USER="oliverames"
REPO_NAME="ping-warden"
NOTARIZE_SCRIPT="$SCRIPT_DIR/notarize.sh"
APPCAST_FILE="$REPO_ROOT/appcast.xml"
APP_INFO_PLIST="$PROJECT_ROOT/PingWarden/Info.plist"
NOTARYTOOL_ARGS=()

if [ -n "${NOTARYTOOL_KEY:-}" ] && [ -n "${NOTARYTOOL_KEY_ID:-}" ] && [ -n "${NOTARYTOOL_ISSUER_ID:-}" ]; then
    NOTARYTOOL_ARGS=(--key "$NOTARYTOOL_KEY" --key-id "$NOTARYTOOL_KEY_ID" --issuer "$NOTARYTOOL_ISSUER_ID")
else
    NOTARYTOOL_ARGS=(--keychain-profile "$KEYCHAIN_PROFILE")
fi

# Pre-flight credential checks. Both blocks fail fast so we don't go through
# 5+ minutes of build/sign/notarize only to discover at the end that an
# enrichment step (dSYM upload) was going to silently no-op the whole time.
# SKIP_NOTARIZE=1 / SKIP_SENTRY=1 are explicit opt-outs for cases like
# re-running against an already-notarized DMG.
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    if ! xcrun notarytool history "${NOTARYTOOL_ARGS[@]}" >/dev/null 2>&1; then
        echo "Error: notarytool credentials are not configured or not readable." >&2
        echo "Provide either keychain profile '$KEYCHAIN_PROFILE' or NOTARYTOOL_KEY, NOTARYTOOL_KEY_ID, and NOTARYTOOL_ISSUER_ID." >&2
        echo "Or set SKIP_NOTARIZE=1 to skip (not recommended for production releases)." >&2
        exit 1
    fi
fi

# Sentry pre-flight. We require sentry-cli, op CLI, and a readable token in
# the vault. Anything missing -> abort here, before notarization. The previous
# inline checks in Step 6 would have *warned and continued*, which means a
# Mac without the tooling could ship a release with no dSYMs uploaded and
# the maintainer would only notice weeks later when crashes came in
# unsymbolicated. That failure mode is closed by checking up-front.
if [ "${SKIP_SENTRY:-0}" != "1" ]; then
    # Match the runtime PATH that Step 6 uses so this check sees the same binaries.
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
else
    if [ -f "$PROJECT_ROOT/$RELEASE_NOTES" ]; then
        RELEASE_NOTES_PATH="$PROJECT_ROOT/$RELEASE_NOTES"
    else
        RELEASE_NOTES_PATH="$REPO_ROOT/$RELEASE_NOTES"
    fi
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Validation
if [ -z "$VERSION" ]; then
    echo -e "${RED}Error: Version required${NC}"
    echo "Usage: ./release.sh [version] [release-notes-file]"
    echo "Example: ./release.sh 2.1.1"
    exit 1
fi

# Ensure the app bundle version matches the release argument
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_INFO_PLIST" 2>/dev/null || true)
if [ -z "$PLIST_VERSION" ]; then
    echo -e "${RED}Error: Failed to read CFBundleShortVersionString from $APP_INFO_PLIST${NC}"
    exit 1
fi

if [ "$PLIST_VERSION" != "$VERSION" ]; then
    echo -e "${RED}Error: Version mismatch${NC}"
    echo "  release.sh version: $VERSION"
    echo "  Info.plist version: $PLIST_VERSION"
    echo "Update Info.plist before running release.sh."
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

# Step 1: Notarize (or reuse existing notarized DMG)
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo -e "${YELLOW}Step 1: Skipping notarization (SKIP_NOTARIZE=1)${NC}"
else
    echo -e "${GREEN}Step 1: Notarizing app...${NC}"
    "$NOTARIZE_SCRIPT" "$VERSION"

    if [ $? -ne 0 ]; then
        echo -e "${RED}Notarization failed!${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Notarization complete${NC}"
fi
echo ""

# Step 2: Verify DMG exists
if [ ! -f "$DMG_PATH" ]; then
    echo -e "${RED}Error: DMG not found: $DMG_PATH${NC}"
    echo "notarize.sh should have created it"
    exit 1
fi

echo -e "${GREEN}✓ DMG found: $(basename "$DMG_PATH")${NC}"
echo ""

# Step 3: Sign update for Sparkle (required)
echo -e "${GREEN}Step 2: Signing update for Sparkle...${NC}"

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

# Prefer the keychain account: it's the documented setup (CLAUDE.md), survives
# DerivedData wipes, and matches what notarize.sh uses. Fall back to a private
# key file at $SPARKLE_KEY only if the keychain attempt fails.
SIGNATURE=""
if SIGNATURE=$("$SIGN_TOOL" "$DMG_PATH" --account "$SPARKLE_KEYCHAIN_ACCOUNT" -p 2>/dev/null | tr -d '\r\n') && [ -n "$SIGNATURE" ]; then
    :
elif [ -f "$SPARKLE_KEY" ]; then
    echo -e "${YELLOW}Keychain account '$SPARKLE_KEYCHAIN_ACCOUNT' did not yield a signature${NC}"
    echo "Falling back to private key file at $SPARKLE_KEY..."
    SIGNATURE=$("$SIGN_TOOL" "$DMG_PATH" --ed-key-file "$SPARKLE_KEY" -p | tr -d '\r\n')
fi

if [ -z "$SIGNATURE" ]; then
    echo -e "${RED}Error: Sparkle signature generation returned an empty signature${NC}"
    echo "Ensure your EdDSA key exists either at $SPARKLE_KEY or in the login keychain account '$SPARKLE_KEYCHAIN_ACCOUNT'."
    exit 1
fi

echo -e "${GREEN}✓ Signature: ${SIGNATURE}${NC}"

echo ""

# Step 4: Get file size and date
DMG_SIZE=$(stat -f%z "$DMG_PATH")
DMG_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S %Z")

echo -e "${GREEN}Step 3: Preparing release metadata...${NC}"
echo "  Version: $VERSION"
echo "  DMG Size: $DMG_SIZE bytes"
echo "  Date: $DMG_DATE"
echo ""

# Step 5: Update appcast.xml
echo -e "${GREEN}Step 4: Updating appcast.xml...${NC}"

# Check if appcast exists
if [ ! -f "$APPCAST_FILE" ]; then
    echo "Creating new appcast.xml"
    cat > "$APPCAST_FILE" << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Ping Warden Updates</title>
    <link>https://GITHUB_USER.github.io/REPO_NAME/appcast.xml</link>
    <description>Updates for Ping Warden</description>
    <language>en</language>
  </channel>
</rss>
EOF
    # Replace placeholders
    sed -i "" "s/GITHUB_USER/$GITHUB_USER/g" "$APPCAST_FILE"
    sed -i "" "s/REPO_NAME/$REPO_NAME/g" "$APPCAST_FILE"
fi

# Render release notes from RELEASE_NOTES.md to styled HTML for the Sparkle
# update window. If the section is missing or rendering fails, fall back to
# the legacy stub so the release doesn't abort over cosmetic content.
RENDER_SCRIPT="$REPO_ROOT/scripts/render_release_notes.sh"
if [ -x "$RENDER_SCRIPT" ] && RELEASE_NOTES_HTML=$("$RENDER_SCRIPT" "$VERSION" 2>/dev/null) && [ -n "$RELEASE_NOTES_HTML" ]; then
    echo "  ✓ rendered release notes from RELEASE_NOTES.md ($(printf '%s' "$RELEASE_NOTES_HTML" | wc -c | tr -d ' ') bytes)"
else
    echo -e "${YELLOW}  ⚠ release-notes render unavailable; using stub${NC}"
    RELEASE_NOTES_HTML="<h2>What's New in $VERSION</h2><p>See release notes on GitHub</p>"
fi

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
NEW_ITEM="    <item>
      <title>Version $VERSION</title>
      <link>https://github.com/$GITHUB_USER/$REPO_NAME/releases/tag/v$VERSION</link>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <description><![CDATA[
$RELEASE_NOTES_HTML
      ]]></description>$CRITICAL_UPDATE_TAG
      <pubDate>$DMG_DATE</pubDate>
      <enclosure
        url=\"https://github.com/$GITHUB_USER/$REPO_NAME/releases/download/v$VERSION/$DMG_BASENAME\"
        sparkle:version=\"$VERSION\"
        sparkle:shortVersionString=\"$VERSION\"
        length=\"$DMG_SIZE\"
        type=\"application/octet-stream\"
        $([ -n "$SIGNATURE" ] && echo "sparkle:edSignature=\"$SIGNATURE\"")
      />
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    </item>"

# Insert new item after <language>en</language> line (idempotent)
if grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST_FILE"; then
    echo "Version $VERSION already exists in appcast.xml; skipping insert."
else
    INSERT_FILE=$(mktemp /tmp/pingwarden-appcast-item.XXXXXX)
    printf "%s\n" "$NEW_ITEM" > "$INSERT_FILE"
    awk -v insert_file="$INSERT_FILE" '
        /<language>en<\/language>/ {
            print
            while ((getline line < insert_file) > 0) {
                print line
            }
            close(insert_file)
            next
        }
        { print }
    ' "$APPCAST_FILE" > "$APPCAST_FILE.tmp"
    mv "$APPCAST_FILE.tmp" "$APPCAST_FILE"
    rm -f "$INSERT_FILE"
fi

echo -e "${GREEN}✓ Appcast updated${NC}"
echo ""

# Validate appcast is well-formed and latest version matches requested release
if ! xmllint --noout "$APPCAST_FILE" 2>/dev/null; then
    echo -e "${RED}Error: appcast.xml is not valid XML${NC}"
    exit 1
fi

# Use xmllint XPath instead of grep|sed: namespace-safe via local-name(),
# and unaffected by formatting (whitespace, multi-line tags, attribute order).
LATEST_APPCAST_VERSION=$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="shortVersionString"])' \
    "$APPCAST_FILE" 2>/dev/null || true)
if [ "$LATEST_APPCAST_VERSION" != "$VERSION" ]; then
    echo -e "${RED}Error: appcast latest version is '$LATEST_APPCAST_VERSION', expected '$VERSION'${NC}"
    exit 1
fi

# Step 6: Create GitHub release
echo -e "${GREEN}Step 5: Creating GitHub release...${NC}"

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
    # Create release with gh CLI
    if [ -f "$RELEASE_NOTES_PATH" ]; then
        gh release create "v$VERSION" \
            "$DMG_PATH" \
            --title "Ping Warden v$VERSION" \
            --target "$CURRENT_SHA" \
            --notes-file "$RELEASE_NOTES_PATH"
    else
        gh release create "v$VERSION" \
            "$DMG_PATH" \
            --title "Ping Warden v$VERSION" \
            --target "$CURRENT_SHA" \
            --notes "See CHANGELOG for details"
    fi
    
    echo -e "${GREEN}✓ GitHub release created${NC}"
fi

echo ""

# Step 6: Upload dSYMs and tag the release in Sentry.
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
XCARCHIVE_DSYMS="/tmp/PingWarden-${VERSION}.xcarchive/dSYMs"

# Prepend the official sentry-cli install path so the official binary at
# ~/.local/bin wins over any older brew-tap install on $PATH.
export PATH="$HOME/.local/bin:$PATH"

echo -e "${GREEN}Step 6: Publishing release to Sentry...${NC}"

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
    SENTRY_FAILURES=0
    (
        set +e
        sentry-cli debug-files upload "$XCARCHIVE_DSYMS" || exit 1
        sentry-cli releases new "$SENTRY_RELEASE" || exit 2
        sentry-cli releases set-commits "$SENTRY_RELEASE" --auto || true  # needs repo integration; non-fatal
        sentry-cli releases finalize "$SENTRY_RELEASE" || exit 4
        exit 0
    )
    SENTRY_FAILURES=$?

    unset SENTRY_AUTH_TOKEN SENTRY_ORG SENTRY_PROJECT SENTRY_LOG_LEVEL
    if [ "$SENTRY_FAILURES" = "0" ]; then
        echo -e "${GREEN}✓ Sentry release published: $SENTRY_RELEASE${NC}"
    else
        echo -e "${RED}⚠ Sentry step exited with code $SENTRY_FAILURES — check above. Release continues.${NC}"
    fi
fi

echo ""

# Step 7: Push appcast to gh-pages
#
# Sparkle reads the appcast from the gh-pages branch (Github Pages), so this
# branch must be updated alongside the GitHub release. Doing this manually is
# the easiest step in the release process to forget. We snapshot the new
# appcast to a temp file, switch branches with git stash for any in-progress
# work, copy it in, commit, push, and switch back. A trap restores the
# original branch on any failure.
echo -e "${GREEN}Step 7: Publishing appcast to gh-pages...${NC}"

if [ "${SKIP_GH_PAGES:-0}" = "1" ]; then
    echo -e "${YELLOW}SKIP_GH_PAGES=1 set; skipping gh-pages publish.${NC}"
else
    # Capture original branch so we can restore on failure.
    ORIGINAL_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)
    if [ -z "$ORIGINAL_BRANCH" ] || [ "$ORIGINAL_BRANCH" = "HEAD" ]; then
        echo -e "${RED}Error: could not determine current branch in $REPO_ROOT${NC}"
        exit 1
    fi

    # Snapshot the just-updated appcast BEFORE any stash. The previous order
    # (stash → snapshot) silently reverted the snapshot to the committed
    # version of appcast.xml, leaving gh-pages stuck on the prior release.
    #
    # macOS mktemp requires the X-placeholder to be at the very END of the
    # template. The previous form `XXXXXX.xml` produced a *literal* filename
    # with X's that persisted across release runs and caused "File exists"
    # on subsequent invocations.
    APPCAST_SNAPSHOT=$(mktemp -t pingwarden-appcast)
    cp "$APPCAST_FILE" "$APPCAST_SNAPSHOT"

    # Stash any in-progress changes so the branch switch is clean.
    STASHED=0
    if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
        git -C "$REPO_ROOT" stash push --include-untracked -m "release.sh v$VERSION pre-gh-pages" >/dev/null
        STASHED=1
    fi

    restore_branch() {
        local rc=$?
        # Best-effort: return to the original branch and pop the stash.
        git -C "$REPO_ROOT" checkout --quiet "$ORIGINAL_BRANCH" 2>/dev/null || true
        if [ "$STASHED" = "1" ]; then
            git -C "$REPO_ROOT" stash pop --quiet 2>/dev/null || true
        fi
        return $rc
    }
    trap restore_branch EXIT

    git -C "$REPO_ROOT" fetch --quiet origin gh-pages
    git -C "$REPO_ROOT" checkout --quiet gh-pages
    git -C "$REPO_ROOT" pull --quiet --ff-only origin gh-pages || true

    cp "$APPCAST_SNAPSHOT" "$REPO_ROOT/appcast.xml"
    rm -f "$APPCAST_SNAPSHOT"

    if git -C "$REPO_ROOT" diff --quiet -- appcast.xml; then
        echo -e "${YELLOW}gh-pages appcast already matches v$VERSION; nothing to push.${NC}"
    else
        git -C "$REPO_ROOT" add appcast.xml
        # Release automation runs non-interactively; avoid SSH signing helpers
        # blocking the gh-pages appcast publish step.
        git -C "$REPO_ROOT" -c commit.gpgsign=false commit -m "Update appcast for v$VERSION"
        git -C "$REPO_ROOT" push origin gh-pages
        echo -e "${GREEN}✓ gh-pages appcast pushed${NC}"
    fi

    # Trap fires on EXIT to restore branch + stash.
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
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
