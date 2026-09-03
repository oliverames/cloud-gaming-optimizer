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
The package is **cross-platform**: `TCPProbe` and the test suite compile on
Linux (`#if canImport(Darwin)/Glibc` shims, poll(2) instead of select), and
CI runs `swift test` on both the macOS 26 runner and an `ubuntu-latest` Swift
container. Keep new Core code Foundation/POSIX-only.

```bash
swift test            # canonical command
./scripts/run-smoke-tests.sh   # thin wrapper, runs `swift test`
```

Read the SwiftPM test target for current coverage; it is the authoritative list.

## Release Process

The full release runbook lives in the **`ames-dev-workflows:project-release-runbooks` skill** (Ping Warden runbook) (unsigned-archive workaround for the broken Xcode 26 `-exportArchive`, standalone notarize test, beta channel, post-release appcast commit). Invoke it for any release. Canonical path, from a clean pushed commit:

```bash
cd PingWarden/PingWarden && bash release.sh X.Y.Z ../../RELEASE_NOTES.md
# then commit the main-side appcast.xml the script leaves modified
```

Sparkle EdDSA key is in keychain account `"ed25519"`. Notarytool profile: `"notarytool-profile"`.

**Version bump touches six carriers, and `release.sh` aborts if any lags:** the four `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` pairs in `PingWarden/PingWarden.xcodeproj/project.pbxproj`, the hardcoded `CFBundleShortVersionString` / `CFBundleVersion` in `PingWarden/PingWarden/Info.plist`, `PingWarden/PingWardenHelper/Info.plist`, and `PingWarden/PingWardenWidget/Info.plist`, and `HELPER_VERSION` in `PingWarden/PingWardenHelper/main.m`. Build number is the version with dots removed and a trailing zero pair (4.0.1 → 40001). Commit the bump as `release: bump to X.Y.Z` before running the script.

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

- **`xcodebuild -exportArchive` is broken** in Xcode 26 — use the unsigned-archive + rsync workaround in the `project-release-runbooks` skill.
- **SMAppService requires `/Applications`**: The daemon registration (`SMAppService.daemon(plistName:)`) refuses to register when the app runs from Xcode's DerivedData. To test the full helper registration flow, build in Release, copy to `/Applications`, and launch from there. Running from Xcode is fine for non-helper UI work.
- **Appcast publishing is automated**: `release.sh` snapshots the signed appcast, publishes it to `gh-pages`, and restores the original branch. It leaves the signed appcast modified on `main`, so commit and push that main-side copy after the release succeeds.
- **Ping Protection is license-gated** (4.0.0+): every app-side enable funnels through `ProtectionExperienceCoordinator.setPersistentProtection(true)` and `startSession`, which consult `LicenseManager.canEnableProtection`. The Control Center widget bypasses the coordinator entirely and applies its own gate in `PingWardenWidgetLicenseGate`. Add a gate to **both** when adding a new enable path.
- **The widget duplicates the license gate, including the seal.** `Core/LicensePolicy.swift` and `LicenseStateSeal.swift` are not members of the widget target, so `PingWardenWidgetLicenseGate.swift` re-declares `offlineGraceInterval`, the seal payload format (`pwlic1|valid=…|verified=…|grandfather=…|seen=…|device=…`), the HMAC secret, and the clock-rollback rule. Nothing catches divergence; change all of them together. The cached gate state in the App Group defaults is only trusted when `LicenseStateSeal` (HMAC-SHA256 bound to the Mac's IOPlatformUUID) matches, so a hand-written `defaults write` or a plist copied from another Mac reads as unlicensed. The one-shot grandfather marker lives in the keychain (account `grandfather-checked`), and the grant also requires an already-approved helper. `PingWardenMonitor.init` consults `LicenseManager.launchGateAllowsProtection` before restoring persisted protection; the buy URL is `LicenseManager.purchaseURL`.
- **Gumroad product ID is a build constant.** `LicenseManager.gumroadProductID` is `FmGG0pxyEyzJqp_BG4itFQ==` (permalink `pingwarden`). Verification fails closed, so a wrong or placeholder ID blocks protection for everyone.
- **Grandfathering is one-shot per install.** `establishGrandfatheringIfNeeded()` runs once, keyed on `AWDLMonitoringEnabled` at first launch of the licensed build, and must stay ahead of `handleMonitoringStateChange()` in `applicationDidFinishLaunching`. A refund does not revoke an active grandfather window; the window is granted for prior use, not for a purchase.
- **Gumroad license-key generation is a content block, not a Settings checkbox.** Gumroad's current editor has no "Generate a unique license key per sale" toggle; a product issues keys only when its rich content (Content tab) contains a `licenseKey` node (Insert → License key). Without it buyers pay and receive no key, and the app stays gated. Check with `gumroad products content get qthvm --json | jq '[.[0].description.content[].type]'` and expect `licenseKey` in the list; the editor confirms it with a "License key (sample)" card. `gumroad products content set` can add the node (done 2026-09-03). The storefront lives at `amesconsulting.gumroad.com`, and its public `.json` endpoint does not expose the flag. Never publish the product without the `licenseKey` block.
- **Direct pushes to `main` report a bypass, and that is intentional.** The `Protect main` ruleset grants the owner `bypass_mode: always` precisely so `release.sh` can push the appcast commit; removing the bypass would break release automation. The `4 of 4 required status checks are expected` line on push is expected. Confirm `Build Verification` goes green afterward rather than treating the message as a failure.
