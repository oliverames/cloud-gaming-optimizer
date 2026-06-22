# Ping Warden 2.4.2

[Support Ping Warden on Buy Me a Coffee](https://buymeacoffee.com/oliverames)

Patch release for the 2.4 line.

## Reliability
- **Donation prompt crash fix**: The support prompt now uses an explicit SwiftUI content size and matching AppKit window content rect. This avoids an unbounded macOS 27 SwiftUI/AppKit button measurement loop that could abort with an AttributeGraph stack overflow.
- **Dashboard picker layout fix**: The Ping History timeframe segmented control no longer shows a squeezed visible picker label when the dashboard card is narrow.
- **Settings title readability**: Settings section titles now use the native macOS titlebar material and soft scroll-edge treatment so scrolled content fades underneath without muddying the header text.

---

# Ping Warden 2.4.1

[Support Ping Warden on Buy Me a Coffee](https://buymeacoffee.com/oliverames)

Patch release for the 2.4 line.

## Reliability
- **Crash-reporting privacy/noise fix**: Sentry now explicitly disables failed HTTP request capture, so transient GitHub/Sparkle download errors like a 502 from a release asset do not get reported as Ping Warden errors. Crash reporting remains crash-only.

---

# Ping Warden 2.4.0

[Support Ping Warden on Buy Me a Coffee](https://buymeacoffee.com/oliverames)

Ping Warden 2.4.0 is a macOS 26-focused release that brings the app's settings, dashboard, and menu surfaces up to the current Tahoe design direction while tightening the release pipeline and Swift concurrency posture.

## Changelog

### Interface
- **Native settings redesign**: Settings now uses a single native split-view window with macOS sidebar chrome, consistent section spacing, and Tahoe-friendly rounded surfaces.
- **Liquid Glass polish**: Settings, dashboard cards, and first-run callouts now use macOS 26 glass materials and concentric corners where appropriate, with older fallback styling kept in place.
- **Dashboard layout cleanup**: The Ping Protection and Connection Settings panels have tighter alignment, clearer status states, and a more readable ping graph.
- **Menu bar icons**: Status menu actions now include SF Symbols so the dropdown matches the icon-led macOS 26 menu style.

### Features
- **Game Mode Auto-Detect is production-ready**: The setting is no longer labeled beta and now has steadier fullscreen-game detection behavior.
- **Control Center Widget is production-ready**: The widget path is no longer labeled beta. Settings now distinguishes widget availability from signing state without implying the feature is experimental.
- **Beta update channel**: Advanced settings include an opt-in Sparkle beta channel for testing pre-release builds.

### Reliability
- **Swift 6 strict concurrency**: The app target now builds with complete strict-concurrency checking, with sendable observer callbacks, explicit main-actor UI hops, and locked XPC callback state.
- **CI fix**: GitHub Actions now runs the maintained SwiftPM test suite instead of the removed smoke-test script.
- **Packaging hardening**: Release tooling validates notes, notarization prerequisites, appcast updates, and Sentry symbol upload paths before publishing.

---

# Ping Warden 2.3.4

Post-release stability and polish pass from manual macOS app testing.

## UX
- **Ping Protection language**: Settings, Dashboard, and the Control Center widget now consistently use "Ping Protection" and "protection events" in primary UI instead of implementation-level AWDL labels.
- **Dashboard state copy**: The interventions panel now reflects the actual protection state instead of saying protection is active when it is off or not set up.

## Packaging
- **Leaner app bundle**: Release automation scripts are excluded from the shipped app resources.
- **macOS metadata**: The app now declares the Utilities category in its Info.plist.

---

# Ping Warden 2.3.3

First-launch and Settings polish found during manual macOS app testing.

## UX
- **Cleaner first launch** — Sparkle no longer opens its automatic-update prompt before Ping Warden's own welcome/setup flow. Manual "Check for Updates" still works from the menu.
- **Settings scrolling** — Settings tabs now keep their section header pinned outside the scroll view, and Dashboard no longer nests a second scroll view inside Settings. Dashboard content can scroll without sliding under the titlebar.

## Internal
- **Release automation** — The release script now accepts App Store Connect API-key notarization credentials as well as the legacy keychain profile, and the gh-pages appcast commit disables GPG signing in non-interactive automation.

---

# Ping Warden 2.3.2

Stability-focused beta with packaging fixes for the Control Center widget and tighter reconnect behavior around the privileged helper.

## Reliability
- **Control Center widget packaging** — The widget target now builds with its own `Info.plist` and entitlements instead of inheriting the main app metadata. The built `.appex` now carries the required `NSExtension` payload and correct extension package type.
- **Helper reconnect hardening** — Replacing an XPC connection can no longer let the old connection's invalidation handler clear the fresh connection. This avoids false "lost helper" states during reconnect churn.
- **Ping monitor session isolation** — Stale ping probes are dropped after a target change or monitor restart, and overlapping probes are skipped instead of building a backlog when a network call is slow.
- **Helper control pipe** — The helper's write side of the control pipe is now non-blocking, so rapid toggle/reconnect churn cannot hang an XPC handler thread.

## Internal
- Version metadata is consistent across the app, helper, widget, Xcode build settings, and helper runtime version string.
- XPC helper connection counting now guards against underflow on duplicate invalidation callbacks.

---

# Ping Warden 2.3.1

Adds opt-in crash reporting and hardens the release pipeline so future updates ship with symbolicated crash reports and properly-formatted release notes. Recommended for all users.

## Features
- **Crash reporting** — On by default to help find bugs you don't see. Anonymous data only: no IP address, no usage telemetry, no information about your ping targets, and no app-lifecycle session events. Toggle it off under Settings → Advanced → Privacy if you'd rather not send anything.

## Internal
- **Sparkle release notes** — The update window now renders the actual release notes from `RELEASE_NOTES.md` (categorized "Features / Internal" with brand-styled HTML, light and dark mode) instead of "See release notes on GitHub". v2.3.0 also retroactively updated on the live appcast.
- **`release.sh` pre-flight hardening** — `notarytool`, `sentry-cli`, the 1Password CLI, and the vaulted Sentry token are all checked up-front. Missing tooling aborts before notarization rather than silently shipping a release with no dSYMs uploaded.
- **dSYM upload to Sentry** — Each release now uploads the xcarchive's dSYMs so crash reports come in symbolicated, and creates a Sentry release object tagged with the version. The pipeline is fail-soft after the GitHub release publishes: a Sentry-side network blip warns but does not abort the script before the gh-pages appcast push.
- **Critical-update marker** — Sparkle prompts every user on a prior version to install this update, since the crash-reporting infrastructure is what the next several releases will depend on.

## Documentation
- **README refresh** — Imperative tagline, live release-version badge, and a new Privacy section documenting the opt-in Sentry posture and the data we never collect. Restructured so the "How It Works" section reads as product positioning rather than objection-handling.

---

# Ping Warden 2.3.0

Two user-facing features plus the usual round of testing improvements.

## Features
- **Custom ping servers** ([#29](https://github.com/oliverames/ping-warden/issues/29)) — Add your own DNS or ping targets (NextDNS, Control D, anything else) under Dashboard → Custom Servers. Targets persist in the App Group, survive updates, and feed into the same auto-select-nearest flow as the built-in list.
- **One-time donation prompt** — A polite, dismissible Buy Me a Coffee ask that appears once on launch and again only on minor-version bumps. A "Don't ask again" button is a permanent kill switch, and the entire flow is governed by `VersionPromptPolicy` so it cannot accidentally re-fire after a patch release.

## Internal
- New `VersionPromptPolicy` and `CustomPingTargetStore` in `Core/`, both pure-Foundation and covered by `swift test`. Total Core test count: 33 (up from 15 in v2.2.2).
- `PingWardenPreferences.defaults` is now exposed so non-singleton consumers (custom-target store, future targets) can share the App Group suite without duplicating the suite name.
- `performUninstall` resets the new donation-prompt and custom-targets state alongside the existing keys.

---

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
