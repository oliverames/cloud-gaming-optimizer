# Ping Warden — Claude Instructions

## Project Overview

Ping Warden is a macOS menu bar app that monitors and blocks AWDL (Apple Wireless Direct Link) to reduce WiFi latency spikes during cloud gaming. Written in Swift/SwiftUI, targeting macOS 13+.

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

## Build

```bash
cd PingWarden
xcodebuild -project PingWarden.xcodeproj -scheme PingWarden -configuration Release
```

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

## Architecture Notes

- `stateLock: NSLock` in `PingWardenMonitor` — always use `defer { stateLock.unlock() }` after `lock()`
- `PingWardenPreferences.defaults` is non-optional (`UserDefaults.standard` fallback in `init`)
- App Group UserDefaults persists across app deletion — always reset in `performUninstall()`
- `applicationShouldHandleReopen` is the lockout recovery path (opens Settings if no windows visible)
- User-facing strings use "Ping Protection" not "AWDL monitoring"

## Version History

- `2.2.1` — Security hardening (XPC UID validation, atomic state), reliability fixes, performance improvements
- `2.2.0` — Lockout fix (Issue #28), UX humanization, thread safety, game category detection fix
- `2.1.2` — Documentation, actor isolation fix
