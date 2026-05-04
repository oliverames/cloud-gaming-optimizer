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

No Xcode test target. Smoke tests via standalone Swift script:
```bash
swift scripts/core_logic_smoke.swift
```
Covers `PingStatistics.calculate()` edge cases (empty, healthy, mixed, high-loss samples).

## Release Process

**Before starting a release, always pre-validate notarytool credentials:**
```bash
xcrun notarytool history --keychain-profile "notarytool-profile"
# If 401: xcrun notarytool store-credentials "notarytool-profile"
```

**Do NOT use `xcodebuild -exportArchive`** — broken in Xcode 26 (IDEDistributionMethodManagerErrorDomain Code=2). Instead:
1. `xcodebuild archive ... -archivePath /tmp/PingWarden-X.Y.Z.xcarchive`
2. `rsync -a "/tmp/PingWarden-X.Y.Z.xcarchive/Products/Applications/Ping Warden.app/" "PingWarden/build/Ping Warden.app/"`
3. `cd PingWarden/PingWarden && bash notarize.sh X.Y.Z`
4. `bash release.sh X.Y.Z ../../RELEASE_NOTES.md`
5. Push appcast: `git checkout gh-pages && git add appcast.xml && git commit -m "Update appcast for vX.Y.Z" && git push && git checkout main`

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

