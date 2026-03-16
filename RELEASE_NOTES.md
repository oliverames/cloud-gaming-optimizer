# Ping Warden 2.2.0

## Bug Fixes

- **Fixed permanent lockout when menu bar icon is hidden** (Issue #28) — Three-layer protection:
  - Relaunching Ping Warden with no visible windows now opens Settings automatically, so you can always get back in
  - The app now refuses to hide the menu bar icon unless the Dock icon is enabled — preventing the lockout state entirely
  - Uninstalling the helper now resets all preferences, so reinstalling starts fresh without inheriting a locked-out state
- **Fixed build regression from project rename** — Stale `AWDLControlHelper` references in the Xcode project caused the helper binary to be missing from the app bundle after the AWDLControl → PingWarden rename; all references updated to `PingWardenHelper`
- **Fixed game category detection** — Games in certain App Store categories were not being detected by Game Mode auto-detect due to an exact-match check; now uses prefix matching to cover all game subcategories

## Improvements

- **Plain-English status labels** — "AWDL Monitoring" is now "Ping Protection"; technical AWDL jargon replaced with clearer language throughout the UI
- **Confirmation before hiding menu bar icon** — Added a dialog explaining the Dock icon requirement before making the menu bar icon invisible, preventing accidental lockout
- **Ping quality based on recent median** — The quality indicator (Excellent/Good/Fair/Poor) now uses the median of the last 5 samples instead of the most recent one, reducing flickering from single-sample outliers
- **Version shown in health alerts** — The "helper needs reinstall" alert now shows the actual bundle version instead of a hardcoded string

## Code Quality

- **Thread safety** — Fixed a race condition in `xpcRetryCount` and standardized all lock/unlock calls to use `defer { stateLock.unlock() }` to prevent unlock skips on early returns
- **Eliminated dead code** — Removed 7 unnecessary `guard let` blocks from Preferences and a dead `checkControlCenterWidgetAvailable()` method
- **Security** — Pinned ControlCenter widget signing requirement to the specific team ID instead of accepting any Developer ID certificate
- **Crash safety** — Replaced two unsafe force-unwraps in QuarantineHelper with proper guard-let error handling

---

# Ping Warden 2.1.2

## Documentation improvements

- Expanded "Why Not Just Run `sudo ifconfig awdl0 down`?" section with detailed explanation of why polling scripts don't work—AWDL performs a channel scan each time it comes up, so even sub-second polling still introduces latency spikes.
- Added new "Other Sources of WiFi Latency" section covering Location Services WiFi scanning and manual mitigations.
- Added "Will Apple Fix This in Hardware?" section summarizing current research (including RIPE 91 October 2025 findings) on whether newer Apple chips might address this at the hardware level.
- Updated troubleshooting guide with Location Services diagnostics and workarounds.

## Code quality

- Fixed Swift 6 actor isolation warnings in MonitoringStateStore.
- Updated user-facing strings from "AWDLControl" to "Ping Warden" for consistency.
