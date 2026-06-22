# Ping Warden

macOS menu bar app that monitors and blocks AWDL (Apple Wireless Direct Link) to reduce WiFi latency spikes during cloud gaming. Swift/SwiftUI, macOS 13+.

## Key Components

| Component | Purpose |
|-----------|---------|
| `PingWarden` (main app) | SwiftUI menu bar app, preferences, UI |
| `PingWardenHelper` | Privileged SMAppService daemon, manages AWDL via `ifconfig` |
| `PingWardenWidget` | macOS Control Center widget |
| XPC | App↔helper communication |

**Bundle IDs:** `com.amesvt.pingwarden` (app), `com.amesvt.pingwarden.widget`, `com.amesvt.pingwarden.helper`
**Team ID:** `PV3W52NDZ3`
**App Group:** `group.com.amesvt.pingwarden`

## Source Structure

```
PingWarden/
├── PingWarden/               # Main app (Swift/SwiftUI)
│   ├── Core/                 # PingStatistics, TCPProbe, XPCReconnectPolicy
│   ├── PingWardenApp.swift   # Entry point, menu bar setup
│   ├── PingWardenMonitor.swift  # AWDL blocking logic, stateLock
│   ├── PingMonitor.swift     # Real-time TCP latency monitoring
│   ├── DashboardView.swift   # Live ping dashboard
│   ├── MonitoringStateStore.swift  # Persisted monitoring state
│   ├── DiagnosticsExporter.swift  # Diagnostic data export
│   ├── QuarantineHelper.swift     # macOS quarantine attribute handling
│   ├── ControlCenterSupport.swift # Control Center widget integration
│   ├── PingWardenPreferences.swift # UserDefaults wrapper
│   ├── notarize.sh           # Notarization + stapling
│   └── release.sh            # DMG creation, appcast signing, GitHub release
├── PingWardenHelper/         # Privileged daemon (Obj-C)
│   ├── main.m                # Daemon entry point
│   └── PingWardenMonitor.h/.m  # AF_ROUTE socket listener, ifconfig calls
├── PingWardenWidget/         # macOS Control Center widget (toggle intent + preferences)
├── Common/                   # Shared XPC protocol (HelperProtocol.h)
├── create-dmg.sh             # DMG packaging with background image
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

```bash
swift test            # canonical command
./scripts/run-smoke-tests.sh   # thin wrapper, runs `swift test`
```

Coverage: `PingStatistics.calculate()` edge cases (empty, healthy, lossy,
even-count median), `XPCReconnectPolicy.delayForAttempt` (backoff curve),
`TCPProbe` failure and success paths (invalid hostname, closed loopback port,
open loopback port), `StateObserverRegistry` add/remove/snapshot lifecycle,
and `HelperBundleValidator` failure modes (missing binary, missing plist,
non-executable binary, valid bundle).

## Release Process

`notarize.sh` pre-validates notarytool credentials automatically (it calls
`xcrun notarytool history --keychain-profile` and aborts with a setup hint
before doing any work). If the profile ever expires, run:
```bash
xcrun notarytool store-credentials "notarytool-profile"
```

**Do NOT use `xcodebuild -exportArchive`** — broken in Xcode 26 (IDEDistributionMethodManagerErrorDomain Code=2). Archive **unsigned** and let `notarize.sh` apply the real Developer ID signature (fully headless, no Xcode UI needed):
1. `xcodebuild archive -project PingWarden.xcodeproj -scheme PingWarden -configuration Release -archivePath /tmp/PingWarden-X.Y.Z.xcarchive -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` — the `CODE_SIGNING_ALLOWED=NO` is **required**: the App Groups entitlement otherwise demands a provisioning profile that Xcode only synthesizes through its UI. The app is non-sandboxed, so `notarize.sh` re-signs every component with `codesign --entitlements` (Developer ID, no profile) — the archive's signing is throwaway. The archive yields both the `.app` **and** `dSYMs/` (the latter is needed by `release.sh` for Sentry).
2. `rsync -a "/tmp/PingWarden-X.Y.Z.xcarchive/Products/Applications/Ping Warden.app/" "PingWarden/build/Ping Warden.app/"`
3. `cd PingWarden/PingWarden && bash notarize.sh X.Y.Z` (optional — standalone notarize test; `release.sh` runs it internally)
4. `bash release.sh X.Y.Z ../../RELEASE_NOTES.md` — runs `notarize.sh` (re-sign + notarize app + DMG + staple), signs the Sparkle update, creates the GitHub release, uploads dSYMs to Sentry, **and pushes the gh-pages `appcast.xml` automatically**.
5. `release.sh` leaves `appcast.xml` modified on `main` after its gh-pages push; commit the main-side copy too: `git add appcast.xml && git commit -m "Update appcast for vX.Y.Z" && git push`.

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
| `create-dmg.sh` | `PingWarden/` | DMG packaging with background image |
| `core_logic_smoke.swift` | `scripts/` | Standalone smoke tests |

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
- **Appcast on `gh-pages` branch**: After releasing, you must switch to `gh-pages`, update `appcast.xml`, push, then switch back. Easy to forget.

