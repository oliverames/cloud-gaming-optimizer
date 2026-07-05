#!/bin/bash
#
# render_release_notes.sh
#
# Extracts a single version's release notes from RELEASE_NOTES.md, renders the
# markdown to HTML via GitHub's /markdown API (so the result matches what users
# see on the release page), wraps it with brand-matched inline CSS, and prints
# the result to stdout.
#
# Used by release.sh to populate the <description> CDATA of each appcast item
# so Sparkle's update window shows real release notes instead of "See release
# notes on GitHub". Also usable standalone for previewing.
#
# Usage: ./scripts/render_release_notes.sh <version> [--markdown]
# Example: ./scripts/render_release_notes.sh 2.3.0
#
# --markdown prints the raw extracted markdown section instead of rendered
# HTML (used by release.sh for the GitHub release body, so each release page
# shows only its own notes rather than the whole history file).
#
# Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
# Licensed under the MIT License.
#

set -euo pipefail

VERSION="${1:-}"
OUTPUT_MODE="${2:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [--markdown]" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_NOTES_FILE="$REPO_ROOT/RELEASE_NOTES.md"

if [ ! -f "$RELEASE_NOTES_FILE" ]; then
    echo "Error: $RELEASE_NOTES_FILE not found" >&2
    exit 1
fi

if [ "$OUTPUT_MODE" != "--markdown" ] && ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI required for markdown rendering" >&2
    exit 1
fi

# Extract the section for this version. Capture begins after the matching
# heading and ends at either the next "# Ping Warden " heading or a "---"
# horizontal rule (both are used as separators in RELEASE_NOTES.md).
SECTION=$(awk -v v="$VERSION" '
    $0 == "# Ping Warden " v { capture = 1; next }
    capture && /^# Ping Warden / { exit }
    capture && /^---$/ { exit }
    capture { print }
' "$RELEASE_NOTES_FILE")

# Trim leading/trailing blank lines.
SECTION=$(printf '%s\n' "$SECTION" | awk 'NF{p=1}p' | awk 'BEGIN{n=0} {a[n++]=$0} END{while(n>0 && a[n-1]==""){n--} for(i=0;i<n;i++)print a[i]}')

if [ -z "$SECTION" ]; then
    echo "Error: no release notes found for version '$VERSION' in RELEASE_NOTES.md" >&2
    exit 2
fi

if [ "$OUTPUT_MODE" = "--markdown" ]; then
    printf '%s\n' "$SECTION"
    exit 0
fi

# Render markdown → HTML using gh's /markdown endpoint. The `gfm` mode matches
# what GitHub renders on the release page, so users see the same formatting in
# the Sparkle update window as on github.com.
HTML_BODY=$(printf '%s' "$SECTION" | gh api -X POST /markdown -F mode=gfm -F text=@-)

# CDATA safety. The XML CDATA terminator is `]]>` — if the rendered HTML ever
# contains that sequence (e.g. inside a code block), it would prematurely close
# the appcast description. The canonical escape splits the sequence across two
# CDATA sections: `]]>` → `]]]]><![CDATA[>`. Extremely unlikely with our
# release notes but cheap insurance.
HTML_BODY_SAFE=$(printf '%s' "$HTML_BODY" | sed 's/]]>/]]]]><![CDATA[>/g')

# Sparkle's update window is a WKWebView. The CSS below mirrors the README
# brand (BMC orange `#f5a542` for links, system fonts, modest line height) and
# respects the user's appearance via prefers-color-scheme so the panel looks
# right in both Light and Dark Mode. Keep selectors specific so they only
# touch elements gh-rendered markdown actually produces.
cat <<HTML
<style>
body {
    font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
    font-size: 13px;
    line-height: 1.55;
    color: #1d1d1f;
    margin: 0;
    padding: 0;
}
h1, h2, h3 { color: #000; font-weight: 600; }
h1 { font-size: 18px; margin: 0 0 10px 0; }
h2 {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.6px;
    color: #6e6e73;
    margin: 18px 0 6px 0;
}
h3 { font-size: 13px; margin: 14px 0 6px 0; }
p { margin: 0 0 10px 0; }
ul, ol { padding-left: 20px; margin: 0 0 10px 0; }
li { margin-bottom: 5px; }
li > strong:first-child { color: #000; }
code {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    background: #f2f2f7;
    padding: 1px 5px;
    border-radius: 3px;
    font-size: 12px;
}
a { color: #f5a542; text-decoration: none; }
a:hover { text-decoration: underline; }
hr { border: 0; border-top: 1px solid #e5e5ea; margin: 16px 0; }
@media (prefers-color-scheme: dark) {
    body { color: #f5f5f7; }
    h1, h2, h3, li > strong:first-child { color: #fff; }
    h2 { color: #98989d; }
    code { background: #2c2c2e; }
    hr { border-top-color: #38383a; }
}
</style>
$HTML_BODY_SAFE
HTML
