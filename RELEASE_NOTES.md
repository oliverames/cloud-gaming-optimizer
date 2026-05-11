# Ping Warden 2.2.2

Correctness, concurrency, and tooling improvements. No user-visible feature changes.

## Reliability
- **TCPProbe**: removed a `freeaddrinfo` call on the `getaddrinfo` failure path. POSIX leaves the result pointer's contents unspecified on resolver failure, so calling `freeaddrinfo` on it was undefined behavior — tolerated on macOS today but a latent portability bug. Tightened the success-path defer to use a non-optional pointer.
- **Process pipes**: three subprocess invocations (`getAWDLInterfaceStatus`, `runIfconfig`, `NetworkGatewayResolver`) used a wait-then-read pipe pattern that can deadlock if a subprocess fills the kernel pipe buffer. Now read first (which unblocks on subprocess EOF) and route unused streams to `/dev/null`.
- **Concurrency**: `xpcRetryCount += 1` opened a brief unlocked window between read and write through the property accessor. Replaced with an atomic `incrementXPCRetryCount()` helper that does read-modify-write under a single locked critical section.
- **Game Mode cache**: PID → isGame cache now evicts entries when the application terminates (via `NSWorkspace.didTerminateApplicationNotification`), so the cache stays bounded over long sessions and cannot be poisoned by PID reuse.

## Correctness
- **Median calculation**: `PingStatistics.calculate` now uses the true median for even-count windows (mean of two middle elements) instead of the upper-middle pick. Improves quality classification for edge cases like a 2-sample window.

## Code Quality
- **Removed `connectXPCWithRetry()`**: it was a no-op wrapper that reset a counter `connectXPC()` was about to reset anyway.
- **Removed dead `onStateChange` callback**: declared on `PingWardenMonitor` and called, but never assigned anywhere in the codebase — guaranteed nil.
- **Extracted `StateObserverRegistry`** into `Core/`: thread-safe observer registry with its own lock, reducing contention on `PingWardenMonitor.stateLock`.
- **Extracted `HelperBundleValidator`** into `Core/`: pure-Foundation validator for the helper-bundle layout, fully unit-testable.
- **Decomposed `DashboardView.swift`** (was 1304 lines):
  - `NetworkGatewayResolver` → its own file
  - `GeForceNOWDiscovery` → its own file
  - `DashboardViewModel` → its own file
  - Remaining `DashboardView.swift` is 673 lines of view code

## Test infrastructure
- **`Package.swift` test target**: smoke tests are now driven by `swift test` via a proper SwiftPM `XCTest` target at `Tests/PingWardenCoreTests/`. The Xcode app build is unaffected — the SwiftPM target references the same `Core/` sources via an explicit `path:`.
- **Coverage**: 15 tests across `PingStatistics`, `XPCReconnectPolicy`, `TCPProbe` (failure and success paths), `StateObserverRegistry`, and `HelperBundleValidator`.

---

# Ping Warden 2.2.1

Security hardening, reliability, and performance improvements.

## Security
- XPC helper now validates caller identity (UID-based defense-in-depth)
- AWDL state control uses atomic operations and returns accurate success/failure
- Sparkle update feed uses Info.plist as single source of truth

## Reliability
- Fixed potential socket hang in network probes when fcntl fails
- Fixed potential pipe buffer deadlock in helper response test
- Complete App Group preferences reset on uninstall (prevents stale widget state)
- DiagnosticsExporter enforces background thread contract

## Performance
- Game Mode detector caches app category lookups (eliminates repeated disk I/O)
- Dashboard gateway resolution moved off main thread

## Quality
- Removed dead code (unused variables, redundant dispatch)
- Helper version synced with app version

---

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

- **Rebuilt settings window chrome** — Replaced dual settings window paths (manual NSWindow + SwiftUI Settings scene) with a single NavigationSplitView inside the Settings scene, restoring native macOS sidebar-under-titlebar appearance with proper vibrancy

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
