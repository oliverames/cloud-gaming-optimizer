# Ping Warden

macOS menu bar app that monitors and blocks AWDL (Apple Wireless Direct Link) to reduce WiFi latency spikes during cloud gaming. Swift/SwiftUI, macOS 13+.

## Key Components

| Component | Purpose |
|-----------|---------|
| `PingWarden` (main app) | SwiftUI menu bar app, preferences, UI |
| `PingWardenHelper` | Privileged SMAppService daemon, manages AWDL via `ifconfig` |
| `PingWardenWidget` | macOS Control Center widget |
| XPC | App↔helper communication |
| Licensing | Gumroad-gated Ping Protection; `LicensePolicy` (Core, pure) + `LicenseManager` (app) + widget gate |

**Bundle IDs:** `com.amesvt.pingwarden` (app), `com.amesvt.pingwarden.widget`, `com.amesvt.pingwarden.helper`
**Team ID:** `PV3W52NDZ3`
**App Group:** `PV3W52NDZ3.com.amesvt.pingwarden` (Team-ID-prefixed so Developer ID builds work without an embedded provisioning profile)

## Source Structure

```
PingWarden/
├── PingWarden/               # Main app (Swift/SwiftUI)
│   ├── Core/                 # PingStatistics, TCPProbe, XPCReconnectPolicy, LicensePolicy
│   ├── PingWardenApp.swift   # Entry point, menu bar setup
│   ├── PingWardenMonitor.swift  # AWDL blocking logic, stateLock
│   ├── PingMonitor.swift     # Real-time TCP latency monitoring
│   ├── DashboardView.swift   # Live ping dashboard
│   ├── MonitoringStateStore.swift  # Persisted monitoring state
│   ├── DiagnosticsExporter.swift  # Diagnostic data export
│   ├── QuarantineHelper.swift     # macOS quarantine attribute handling
│   ├── ControlCenterSupport.swift # Control Center widget integration
│   ├── PingWardenPreferences.swift # UserDefaults wrapper
│   ├── LicenseManager.swift  # Gumroad verify, keychain key, grandfather window
│   ├── notarize.sh           # Notarization + stapling
│   └── release.sh            # DMG creation, appcast signing, GitHub release
├── PingWardenHelper/         # Privileged daemon (Obj-C)
│   ├── main.m                # Daemon entry point
│   └── PingWardenMonitor.h/.m  # AF_ROUTE socket listener, ifconfig calls
├── PingWardenWidget/         # macOS Control Center widget (toggle intent, preferences, license gate)
├── Common/                   # Shared XPC protocol (HelperProtocol.h)
├── create-dmg.sh             # DMG packaging
└── PingWarden.xcodeproj
```

## Build

```bash
cd PingWarden
xcodebuild -project PingWarden.xcodeproj -scheme PingWarden -configuration Release
```

## Testing

The Foundation-only core helpers are covered by a SwiftPM test target driven
by `Package.swift` at the repo root. The Xcode app build is unaffected — the
package's `PingWardenCore` target points at `PingWarden/PingWarden/Core/` via
an explicit `path:` so the same Swift sources back both build systems.
Core helpers and tests stay Foundation/POSIX-only so CI can run them on both
the macOS 26 runner and an `ubuntu-latest` Swift container.

```bash
swift test            # canonical command
./scripts/run-smoke-tests.sh   # thin wrapper, runs `swift test`
```

Coverage: `PingStatistics.calculate()` edge cases (empty, healthy, lossy,
even-count median, fair band, min/max, all-failures, single-sample jitter),
`XPCReconnectPolicy.delayForAttempt` (backoff curve, 30 s cap, monotonicity),
`TCPProbe` failure and success paths (invalid hostname, closed loopback port,
open loopback port), `StateObserverRegistry` add/remove/snapshot lifecycle,
`VersionPromptPolicy` and custom-target boundaries, `LicensePolicy` (offline
grace, grandfather window, Gumroad response mapping), and `HelperBundleValidator`
failure modes (missing binary, missing plist, non-executable binary, valid
bundle).

## Release Process

`notarize.sh` pre-validates notarytool credentials automatically (it calls
`xcrun notarytool history --keychain-profile` and aborts with a setup hint
before doing any work). If the profile ever expires, run:
```bash
xcrun notarytool store-credentials "notarytool-profile"
```

**Do NOT use `xcodebuild -exportArchive`** — broken in Xcode 26 (IDEDistributionMethodManagerErrorDomain Code=2). Archive **unsigned** and let `notarize.sh` apply the real Developer ID signature (fully headless, no Xcode UI needed):
1. `xcodebuild archive -project PingWarden.xcodeproj -scheme PingWarden -configuration Release -archivePath /tmp/PingWarden-X.Y.Z.xcarchive -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`. The `CODE_SIGNING_ALLOWED=NO` is **required** so the archive is deterministic and does not depend on Xcode's provisioning UI. The app uses a Team-ID-prefixed macOS App Group that does not require a profile. `notarize.sh` re-signs every component with `codesign --entitlements` (Developer ID, no profile). The archive's signing is throwaway. The archive yields both the `.app` **and** `dSYMs/` (the latter is needed by `release.sh` for Sentry).
2. `rsync -a "/tmp/PingWarden-X.Y.Z.xcarchive/Products/Applications/Ping Warden.app/" "PingWarden/build/Ping Warden.app/"`
3. `cd PingWarden/PingWarden && bash notarize.sh X.Y.Z` (optional — standalone notarize test; `release.sh` runs it internally)
4. `bash release.sh X.Y.Z ../../RELEASE_NOTES.md` — runs `notarize.sh` (re-sign + notarize app + DMG + staple), signs the Sparkle update, creates the GitHub release, uploads dSYMs to Sentry, **and pushes the gh-pages `appcast.xml` automatically**.
5. `release.sh` leaves `appcast.xml` modified on `main` after its gh-pages push; commit the main-side copy too: `git add appcast.xml && git commit -m "Update appcast for vX.Y.Z" && git push`.

**Beta releases:** prefix step 4 with `BETA_CHANNEL=1` (same env-flag pattern as the existing `CRITICAL_UPDATE=1`). The script writes to `appcast-beta.xml` on `gh-pages` instead of `appcast.xml`, uses distinct channel metadata, and writes a different commit message. Same EdDSA signing, same DMG packaging, same GitHub release flow; beta is a Sparkle-layer concept only. Users opted into the beta channel via Settings → Advanced → Updates get routed there by `SPUUpdaterDelegate.feedURLString(for:)`.
```bash
BETA_CHANNEL=1 bash release.sh 3.1.0-beta.1 ../../RELEASE_NOTES.md
```

The canonical release path is now one command from a clean, pushed commit:
`cd PingWarden/PingWarden && bash release.sh X.Y.Z ../../RELEASE_NOTES.md`.
It creates and validates the unsigned archive and dSYMs itself before running
the signing, notarization, DMG, appcast, GitHub, Sentry, and `gh-pages` steps.
The numbered commands above remain useful only for a standalone notarization
test.

Sparkle EdDSA key is in keychain account `"ed25519"`. Notarytool profile: `"notarytool-profile"`.

## Distribution

- **Sparkle** auto-update framework with EdDSA signing (keychain account `"ed25519"`)
- `appcast.xml` on `gh-pages` branch — update after each release
- DMGs built via `create-dmg.sh` (PingWarden directory)
- Developer ID signed + Apple notarized

## Key Scripts

| Script | Location | Purpose |
|--------|----------|---------|
| `notarize.sh` | `PingWarden/PingWarden/` | Notarize, poll, staple |
| `release.sh` | `PingWarden/PingWarden/` | DMG + Sparkle appcast entry + GitHub release |
| `create-dmg.sh` | `PingWarden/` | DMG packaging |

## Architecture Notes

- Mixed Swift/Obj-C: main app is Swift, helper daemon is Obj-C (requires root for `ifconfig`). XPC protocol shared via `Common/HelperProtocol.h` and bridging header
- `stateLock: NSLock` in `PingWardenMonitor` — always use `defer { stateLock.unlock() }` after `lock()`
- `PingWardenPreferences.defaults` is non-optional (`UserDefaults.standard` fallback in `init`)
- App Group UserDefaults persists across app deletion — always reset in `performUninstall()`
- `applicationShouldHandleReopen` is the lockout recovery path (opens Settings if no windows visible)
- User-facing strings use "Ping Protection" not "AWDL monitoring"

## Gotchas

- **`xcodebuild -exportArchive` is broken** in Xcode 26 — use the rsync workaround in the Release Process section above.
- **SMAppService requires `/Applications`**: The daemon registration (`SMAppService.daemon(plistName:)`) refuses to register when the app runs from Xcode's DerivedData. To test the full helper registration flow, build in Release, copy to `/Applications`, and launch from there. Running from Xcode is fine for non-helper UI work.
- **Appcast publishing is automated**: `release.sh` snapshots the signed appcast, publishes it to `gh-pages`, and restores the original branch. It leaves the signed appcast modified on `main`, so commit and push that main-side copy after the release succeeds.
- **Ping Protection is license-gated** (4.0.0+): every app-side enable funnels through `ProtectionExperienceCoordinator.setPersistentProtection(true)` and `startSession`, which consult `LicenseManager.canEnableProtection`. The Control Center widget bypasses the coordinator entirely and applies its own gate in `PingWardenWidgetLicenseGate`. Add a gate to **both** when adding a new enable path.
- **The widget duplicates the 14-day grace constant.** `Core/LicensePolicy.swift` is not a member of the widget target, so `PingWardenWidgetLicenseGate.swift` re-declares `offlineGraceInterval`. Nothing catches divergence; change both together.
- **Gumroad product ID is a build constant.** `LicenseManager.gumroadProductID` is `FmGG0pxyEyzJqp_BG4itFQ==` (permalink `pingwarden`). Verification fails closed, so a wrong or placeholder ID blocks protection for everyone.
- **Grandfathering is one-shot per install.** `establishGrandfatheringIfNeeded()` runs once, keyed on `AWDLMonitoringEnabled` at first launch of the licensed build, and must stay ahead of `handleMonitoringStateChange()` in `applicationDidFinishLaunching`. A refund does not revoke an active grandfather window; the window is granted for prior use, not for a purchase.
