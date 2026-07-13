#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Ping Warden"
BUNDLE_ID="com.amesvt.pingwarden"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/xcode-run"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/Ping Warden.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Ping Warden"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild build \
  -project "$ROOT_DIR/PingWarden/PingWarden.xcodeproj" \
  -scheme PingWarden \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
