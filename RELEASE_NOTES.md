# Ping Warden 4.0.0

Ping Warden is moving to a license for the AWDL-blocking feature. The source stays MIT and everything except enabling Ping Protection is free.

Starting with this release, enabling Ping Protection in the prebuilt, signed, and notarized app requires a one-time $15 license at [Gumroad](https://olivera40.gumroad.com/l/pingwarden). One key works on the Macs you own and covers all future updates. The app verifies once with Gumroad, then re-checks roughly every 6 hours while it runs and once at launch. Verification is offline-friendly for up to 14 days. Building from source under MIT remains free and unchanged.

## Pricing

- Ping Protection now requires a license in the prebuilt app. All other features remain free.
- The source code remains MIT. You can build from source, inspect it, and modify it whether you buy a license or not.
- The license is a one-time $15 purchase at [Gumroad](https://olivera40.gumroad.com/l/pingwarden). No subscription, no ads, no analytics. Taxes are handled by Gumroad as merchant of record — the 10% + 50¢ direct fee (30% via Discover) covers processing.

## Transition for existing users

- If Ping Protection was enabled on this Mac before the licensed build first ran, it keeps working for a 90-day transition that starts on that first launch. No action is needed today.
- Check the time remaining in **Settings → License**. When the transition ends, enter a license key there to keep protection available.
- On first launch of the licensed build, existing users see a one-time notice that explains the change and points to **Settings → License**. The notice appears only once per install.

## Donors

- If you supported Ping Warden through [Buy Me a Coffee](https://www.buymeacoffee.com/oliverames) before this release, email [oliver@ames.consulting](mailto:oliver@ames.consulting) with your receipt and it will be honored as a full license via a hidden 100% off code (`DONOR-HONOR`). The License pane and the gate error both surface this offer, and the app now handles the conversion — no extra purchase needed.
- The in-app donation prompt that appeared after latency sessions has been removed. The menu, Settings → Support, About, and Dashboard still offer a Donate link, and the full documentation now describes the licensed model instead.

## License management

- New **Settings → License** pane shows status (Licensed, transition with days remaining, or Unlicensed), key entry with verification, and a direct link to the Gumroad product page. The transition pane explains why the change is happening and carries the donor-honoring note with a mailto button.
- License keys are verified at `api.gumroad.com/v2/licenses/verify` with your product ID and key, then cached so the app works offline. A cached valid result stands in for 14 days when the API cannot be reached. Refunded, chargebacked, or disabled keys are treated as revoked and turn protection off with a notice at the next verification. An install still inside its 90-day transition keeps protection under that window, since the transition is granted for prior use rather than for a purchase.
- The Control Center widget reads the same cached entitlement from the shared app group and refuses to enable protection without a valid license. Disabling is always allowed.
- Uninstall clears all licensing state from the App Group defaults and the keychain.

---

# Ping Warden 3.1.0

[Donate to Ping Warden on Buy Me a Coffee](https://buymeacoffee.com/oliverames)

Ping Warden 3.1 keeps your choices where you put them. A pause now survives a quit, a failed server refresh tells you instead of going quiet, and the app stops working when nobody is looking at it.

## Protection

- Pausing protection survives quitting and relaunching. Ping Warden used to store nothing on disk when you paused, so quitting during the ten minute window silently re-blocked AWDL while you were still trying to AirDrop or share a screen. The pause window now persists, and every path that genuinely ends it still clears it.
- Protection controls stay responsive when several state changes race each other. Toggling from the menu, the dashboard, or the Control Center widget at the same time could strand the controls mid-transition and disable them until relaunch.
- Stopping protection no longer leaves monitoring stuck on. A slow reply from the privileged helper used to be discarded after the timeout, so the app reported protection as active across relaunch while AWDL was already restored.

## Cloud gaming

- A failed GeForce NOW zone refresh now says so and offers Retry. The server picker previously dropped its "Refreshing" caption and left a stale list with no explanation. Existing zones are kept through the failure, so a network blip cannot reset your selection or chart history.

## Battery and idle power

- Live menu metrics run only while the menu is open. Turning on "Show Live Metrics in Menu" used to start a permanent two second probe and a five second intervention poll, which sent tens of thousands of pointless network connections a day toward numbers nobody was reading. Opening the menu still shows a fresh reading immediately.
- Game Mode detection backs off while you are idle. Auto-detect scanned the full window list every ten seconds forever; after about ninety quiet seconds it now moves to thirty. App and display events still trigger an immediate check, so a game launching from deep idle is caught right away.

## Security

- Sparkle updates to 2.9.6, which carries a symlink hardening fix in the installer's archive handling and a privilege escalation fix for root-invoked Sparkle processes.
- The privileged helper now accepts XPC only from root and the logged-in console user. The previous check rejected system accounts but would have let any second desktop account drive the root daemon with a copy of the signed app.
- Sentry updates to 9.26.0. Crash reporting remains off by default.

## Release engineering

- Release validation now checks the helper's embedded version metadata, not just the app and widget. The helper's version lives in a plist compiled into its binary, so a half-applied version bump could previously ship with validation still reporting success.

---

# Ping Warden 3.0.0

[Donate to Ping Warden on Buy Me a Coffee](https://buymeacoffee.com/oliverames)

Ping Warden 3 turns Ping Protection into measurable Latency Sessions. Start a session for a game or call, watch one shared latency stream, and finish with a local recap that explains what happened without exposing network targets or claiming more than the measurements show.

## Latency Sessions and recaps

- Start and end Latency Sessions from the dashboard. Game Mode can manage sessions automatically.
- The menu bar now has one clear Ping Protection control. Latency Sessions stay in the dashboard so the two actions cannot be mistaken for duplicates.
- Review duration, median and P95 latency, jitter, Probe Failures, sample count, and wireless interventions.
- Share a privacy-scrubbed text recap. Hostnames, IP addresses, game names, and raw samples are never written to session history.
- Keep a bounded local history and clear it from the dashboard at any time.

## Performance

- The dashboard, menu, and sessions now share one probe stream instead of running duplicate monitors.
- Hostname lookups use a bounded five-minute address cache, one connection deadline, and cancellation that reaches DNS and socket work.
- Rolling history avoids repeated array shifts. Statistics and snapshots are prepared off the main thread and published once per sample.
- Game Mode detection moved its window scan off the main thread. App and display events trigger immediate checks, with a slower safety interval when no game is active.

## Security and privacy

- Sparkle 2.9.4 replaces 2.8.1. Ping Warden now requires signed appcast metadata and verifies updates before extraction.
- The Control Center widget applies protection directly through the helper's signed-client XPC boundary. Shared preferences and distributed notifications no longer authorize root operations.
- Shared app and widget settings now use a Team-ID-prefixed macOS App Group, restoring reliable persistence on macOS 15 and later without an embedded provisioning profile.
- Unsigned helper builds fail closed, and the helper launches on demand instead of staying alive after boot.
- Diagnostics redact custom targets, use owner-only file permissions, and show their contents before sharing.
- Crash reporting is off by default. Turning it off is immediate; opting in takes effect after relaunch.

## Setup and donations

- The welcome screen explains the AirDrop, AirPlay, and Handoff tradeoff before approval.
- Choosing Later no longer strands setup. Settings now has a visible Finish Setup action.
- Unsupported CPU and latency claims have been removed from the app.
- Every completed Latency Session recap includes a quiet donation link that never interrupts the recap or gates features. Permanent donation links are also available in the menu, Settings, About window, README, and GitHub repository.

## Release engineering

- Releases build a fresh archive and validate the staged app, helper, widget, DMG, signatures, Team ID, entitlements, Hardened Runtime, Gatekeeper result, notarization ticket, and version metadata before publishing.
- Marketing versions and numeric bundle builds are validated separately.
- CI builds the complete app on macOS 26, runs the Foundation core on macOS and Linux, lints release scripts, and adds CodeQL and Dependabot coverage.
- The update minimum is derived from the built app, fixing the appcast metadata that incorrectly excluded macOS 13 through 25 from recent updates.

---

# Ping Warden 2.5.0

[Support Ping Warden on Buy Me a Coffee](https://buymeacoffee.com/oliverames)

Ping Warden 2.5.0 is a reliability-focused release: a full audit of the helper daemon, XPC layer, widget sync, monitoring pipeline, and release tooling, with dozens of fixes.

## Changelog

### Protection Reliability
- **Protection now survives quit + relaunch**: Quitting the app no longer silently turns the Ping Protection preference off. If protection was on when you quit, it turns back on at the next launch.
- **Helper can never strand your Wi-Fi radio off**: Every helper exit path (grace-period shutdown, system termination) now guarantees the wireless interface is restored via a direct fallback, even if the helper's internal monitoring thread had died.
- **Honest failure reporting from the helper**: If the helper's kernel-event thread stops, protection commands now fail visibly instead of pretending to succeed while nothing was being enforced.
- **XPC reconnect fixed**: The reconnect retry counter is now only reset after the helper actually responds, closing an infinite silent reconnect loop when the helper was unregistered mid-session. Abandoned connections are also properly invalidated (fixing a slow resource leak), and a reconnect can no longer overwrite a stop you issued while it was in flight.
- **Helper setup can no longer wedge**: An interrupted registration flow used to permanently block future "Enable Ping Protection" attempts until app restart; registration polling now always resolves.
- **Race-free helper shutdown**: The helper's exit decision is now atomic with connection tracking, so an app reconnect can never be dropped mid-shutdown (which previously caused a brief AWDL flap — the exact latency spike the app prevents).
- **Hardened privileged daemon**: Release builds of the root helper now refuse to run if their code signature fails validation instead of downgrading to weaker checks.

### Game Mode & Quick Pause
- **Game detection now recognizes most games**: Apps declaring a game *subcategory* (action, RPG, strategy, …) in their Info.plist were never detected as games; now they are.
- **Pause and Game Mode no longer fight each other**: Pausing during a game session is honored when the game ends; a pause that expires mid-game restores your protection preference instead of leaving protection off permanently.
- **Pause timer reliability**: The 10-minute auto-resume now fires even while a menu or dialog is open, and the menu's Pause/Resume items enable/disable correctly.

### Control Center Widget
- **Widget state stays in sync**: The app now tells Control Center to refresh the toggle whenever protection changes from the menu bar, Settings, or Game Mode — the widget no longer displays stale state indefinitely.
- **Toggling off no longer snaps back to on**: The widget now displays and toggles the same state, fixing both the visual snap-back after disabling and a Shortcuts toggle that could never turn auto-enabled protection off.
- **Launch failures surface**: If the main app can't be launched to apply a widget toggle, the toggle now reverts and reports an error instead of showing protection as on while nothing happened.
- **Lockout prevention hardened**: Hiding the dock icon while in Control Center mode (menu bar hidden) is now blocked at all times, not just at the moment Control Center mode is enabled.

### Ping Monitoring & Dashboard
- **Accurate latency numbers**: Measured ping now excludes DNS resolution time and failed connection attempts — dual-stack hostnames no longer report ~1000 ms "successful" pings that poisoned averages, jitter, spike events, and Auto-Select rankings.
- **Unresponsive DNS can't freeze monitoring**: Hostname resolution now runs with a bounded deadline, so a hung resolver no longer stalls the entire ping pipeline and dashboard.
- **Saved server selection survives relaunch**: A selected GeForce NOW zone or local-gateway target is now restored once its source loads, instead of silently falling back to Cloudflare DNS forever.
- **Transient GFN outages keep your zones**: A failed GeForce NOW server-list refresh no longer wipes previously discovered zones (which reset your selection and erased chart history).
- **Dashboard chart performance**: Chart data is now memoized and downsampled (spikes always preserved), cutting per-second CPU dramatically on long timeframes — exactly during the gaming sessions the app protects.
- **Smaller fixes**: duplicate server entries are deduplicated everywhere; protection events that occur while the dashboard is closed no longer appear as one mistimed event; auto-select probes no longer starve the app's async runtime; settings window size/position is remembered again; diagnostics export falls back to a temp folder if Desktop access is denied; the quarantine-fix command now uses the app's real location; automatic update checks start correctly after first-run setup.

### Release Tooling & CI
- **Cross-platform test suite**: The core logic package now compiles and tests on Linux; CI gained an `ubuntu-latest` `swift test` job (plus 8 new tests) and shellcheck coverage for all scripts.
- **Release script fixes**: Sentry upload failures can no longer abort a release before the appcast is published; first-ever beta appcasts publish correctly; beta releases are marked as GitHub pre-releases; GitHub release pages now show only that version's notes; notarization failures print their diagnostics instead of dying silently; version arguments are validated against Info.plist.

---

# Ping Warden 2.4.3

[Support Ping Warden on Buy Me a Coffee](https://buymeacoffee.com/oliverames)

Patch release for the 2.4 line.

## Reliability
- **Settings crash fix**: Fixed a rare startup crash on macOS 26 and later. The hidden helper window that backs the standard Settings menu command was pinned to a one-pixel-wide size, which on newer macOS could send the layout engine into an endless update loop and abort the app. The window is now left to size itself, removing the loop.

---

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
