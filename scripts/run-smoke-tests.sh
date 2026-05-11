#!/usr/bin/env bash
#
# Thin wrapper around `swift test` for the Ping Warden core logic suite.
#
# The real test definitions live in Tests/PingWardenCoreTests/, driven by the
# Package.swift at the repo root. This script exists so CI scripts and humans
# can keep running a single command without remembering the SwiftPM target
# names.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec swift test --package-path "$REPO_ROOT"
