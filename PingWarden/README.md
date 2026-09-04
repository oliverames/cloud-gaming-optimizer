# Ping Warden Full Documentation

This document is the detailed technical and operational guide for Ping Warden.

For quick setup, see [Quick Start](QUICKSTART.md). For issue recovery, see [Troubleshooting](TROUBLESHOOTING.md).

## 1. Overview

Ping Warden is a macOS utility that keeps AWDL from reactivating during latency-sensitive work.

AWDL (Apple Wireless Direct Link) is used by Apple ecosystem features such as AirDrop, AirPlay, and Handoff. On some networks and workflows, AWDL interface transitions can correlate with sudden latency jumps. Ping Warden provides a controlled, user-friendly way to keep AWDL suppressed when desired, while retaining the ability to restore normal behavior instantly.

Primary goals:

- Keep AWDL suppressed during latency-sensitive games, cloud streaming, and calls.
- Avoid repeated password prompts for normal day-to-day usage.
- Provide clear observability (status, ping history, interventions).
- Offer safe operational controls (enable/disable/pause/restore).

## 2. Why Not Just Run `sudo ifconfig awdl0 down`?

A one-time shell command might seem like a simple fix, but it doesn't actually solve the problem.

**The core issue:** macOS can bring AWDL back up automatically. A polling script reacts only after the interface is active, so it cannot prevent the transition itself.

**Why Ping Warden is different:** Instead of polling, the helper daemon waits for kernel route and interface events through an `AF_ROUTE` socket. When macOS raises AWDL while protection is active, the helper takes the interface back down and records an intervention. Ping Warden does not claim that a specific intervention proves a particular latency spike was avoided.

Additional benefits:

- **No repeated sudo prompts:** One-time approval during setup, then background operation.
- **Observability:** Live dashboard with ping history, intervention counts, and spike timeline.
- **Proper lifecycle:** Explicit startup, reconnect, health-check, and shutdown behavior.

## 3. High-Level Architecture

Ping Warden uses a split architecture:

- Main app (Swift/SwiftUI + AppKit bridge):
  - UI, settings, dashboard, diagnostics, automation, Sparkle updates.
- Helper daemon (Objective-C):
  - Privileged AWDL control and low-level monitoring.

Communication boundary:

- XPC service: `com.amesvt.pingwarden.xpc`
- Protocol: `PingWardenHelperProtocol` (in `PingWarden/Common/HelperProtocol.h`)

Registration model:

- Helper is registered using `SMAppService.daemon(plistName:)`.
- Registration requires one-time user approval in System Settings.

## 4. Key Components

### 4.1 Main App

Important files:

- `PingWarden/PingWarden/PingWardenApp.swift`
- `PingWarden/PingWarden/PingWardenMonitor.swift`
- `PingWarden/PingWarden/DashboardView.swift`
- `PingWarden/PingWarden/ProtectedSessionCoordinator.swift`
- `PingWarden/PingWarden/PingWardenPreferences.swift`
- `PingWarden/PingWarden/DiagnosticsExporter.swift`

Responsibilities:

- Menu bar app behavior and settings window lifecycle.
- User intent state persistence (`isMonitoringEnabled`).
- Effective runtime state tracking (`effectiveMonitoringEnabled`).
- Dashboard data collection and charting.
- Latency Session lifecycle and local recap history.
- Sparkle update checks and update menu entries.

### 4.2 Helper Daemon

Important files:

- `PingWarden/PingWardenHelper/main.m`
- `PingWarden/PingWardenHelper/PingWardenMonitor.h`
- `PingWarden/PingWardenHelper/PingWardenMonitor.m`
- `PingWarden/PingWardenHelper/com.amesvt.pingwarden.helper.plist`

Responsibilities:

- Monitor interface change events through `AF_ROUTE`.
- Enforce desired AWDL state through `ioctl` on interface flags.
- Count and report interventions.
- Restore AWDL to enabled state when helper exits.

## 5. Monitoring Model and Timing Behavior

Core behavior:

- AWDL blocking mode means: keep `awdl0` down.
- Allow mode means: permit `awdl0` to remain up.
- Helper thread blocks on `poll()` waiting for:
  - Route/interface events (`AF_ROUTE` socket).
  - Internal control messages (`pipe`).

When monitoring is active and the system raises AWDL:

1. Kernel route event arrives.
2. Helper identifies `awdl0` state change (`RTM_IFINFO`).
3. Helper clears `IFF_UP` on `awdl0` via `SIOCSIFFLAGS`.
4. Intervention counter increments.

This is event-driven, not a delayed periodic shell loop.

## 6. State Model

Two state concepts are used:

- User intent state:
  - Preference for whether monitoring should be enabled.
  - Stored in user defaults.
- Effective runtime state:
  - Actual active status considering helper availability and XPC connectivity.

This separation allows robust behavior during reconnects, restarts, or temporary failures.

## 7. Setup and Approval Flow

Initial setup sequence:

1. Launch app.
2. App checks helper registration status via `SMAppService`.
3. If unregistered or approval required, user is guided to System Settings.
4. App polls registration status and proceeds once enabled.
5. XPC connection is activated.

The design avoids recurring password prompts after the one-time approval step.

## 8. Settings and UI Areas

Settings sections:

- Dashboard
- General
- License
- Automation
- Advanced

### 8.1 Dashboard

Provides real-time latency visibility and tuning controls.

Cards include:

- Latency Session:
  - Start and end a measured game or call.
  - Review duration, median, p95, jitter, Probe Failures, and interventions.
  - Share a privacy-scrubbed text recap.

- Network Quality:
  - Current ping, average, best, worst, jitter, Probe Failures, AWDL state.
- Ping History:
  - Timeframe zoom windows: 1 min, 5 min, 15 min, 30 min, 1 hour.
  - Timeframe changes are non-destructive (history is not deleted by zoom changes).
- Latency Timeline:
  - Spike and intervention event list.
- Ping Protection:
  - Intervention counter and explanatory status.
- Connection Settings:
  - Ping target selection.
  - Auto-select nearest endpoint.
  - Update interval selection.

Data retention behavior:

- Dashboard keeps a rolling history window (approximately one hour plus buffer).
- Chart zoom filters the in-memory history for display only.

### 8.2 General

Controls:

- Ping Protection setup and status.
- Launch at Login.
- Show Dock Icon.
- Menu Dropdown Metrics (show current ping and interventions in menu dropdown).

Status block:

- Displays helper registration and effective blocking status.

### 8.3 Automation

Controls:

- Game Mode Auto-Detect.
- Hide Menu Bar Icon mode for people who use the Control Center toggle (macOS 26+, signed release builds only).

### 8.4 Advanced

Tools:

- Test the registered helper and signed XPC connection.
- Open Console logs.
- Create a local diagnostics snapshot and review it before sharing.
- Repair the helper connection without changing the protection preference.
- Prepare for removal by turning off protection, unregistering services, clearing local data, revealing the app, and quitting.

### 8.5 License

- View status (Licensed, transition period with days remaining, or Unlicensed).
- Enter a license key and verify with Gumroad, or open the Gumroad product page.
- The transition applies when protection was enabled with an approved helper at the first launch of version 4. It lasts 90 days from that launch, and updates preserve the deadline. For donations before version 4, the pane explains how to request a license at [oliver@ames.consulting](mailto:oliver@ames.consulting).
- Activation and refresh send the license key and product ID to Gumroad over HTTPS. The key stays in the macOS Keychain between checks.

## 9. Menu Bar and App Menu Integration

Menu bar:

- One primary Ping Protection action, plus a contextual 10-minute pause.
- Latency Sessions stay in the dashboard so they are not confused with the persistent protection control.
- Optional live metrics in dropdown.
- Settings, About, Donate, and update actions.

App menu (frontmost app state):

- `Check for Updates...` is injected/ensured when app is active with regular activation policy.
- This complements the status item update command.

## 10. Sparkle Update System

Update stack:

- Framework: Sparkle 2.9.4.
- Stable feed: `https://oliverames.github.io/ping-warden/appcast.xml`.
- Beta feed: `https://oliverames.github.io/ping-warden/appcast-beta.xml`, selected in **Settings → Advanced → Updates**. Stable releases also reach this feed.
- Signature model: EdDSA (`SUPublicEDKey` in app plist).
- Signed feeds and pre-extraction archive verification are required.

Operational details:

- App clears stale user-default feed overrides at startup.
- Updater delegate provides canonical feed URL.
- Manual update checks available from both menu entry points.
- The paid-upgrade boundary at build 40000 requires users of free versions to review the upgrade before installation.

Release wiring:

- `PingWarden/PingWarden/release.sh` builds a fresh archive, signs and notarizes the app and DMG, and publishes signed update feeds.
- Stable releases replace the Gumroad app download while preserving the license-key block and other buyer content.
- GitHub release artifacts and appcast metadata must remain synchronized.

## 11. Security Model

Security controls include:

- Privileged helper exposed only through XPC interface.
- Mandatory code-signing requirements for the app and widget XPC clients.
- Exact Team ID and bundle identifier validation in the helper bootstrap path.
- Unsigned or ad-hoc helper builds fail closed instead of falling back to UID-only access.
- Shared defaults and distributed notifications never authorize privileged changes.
- Bounded error handling and controlled shutdown paths.
- Developer ID signing, Hardened Runtime, notarization, and stapling are release gates.

## 12. Diagnostics and Health Checks

Built-in diagnostics surface:

- Helper registration state.
- XPC reachability.
- Helper version and status calls.
- Current `awdl0` flags snapshot.
- Health check pass/fail messaging.
- Intervention counter and reset support.

Export diagnostics:

- Generates a local support snapshot with owner-only permissions.
- Redacts custom ping targets to a category before writing.
- Shows the contents for review and never uploads the file automatically.

## 13. Performance Characteristics

Design choices for low overhead:

- Event-driven helper thread using `poll()` rather than busy loops.
- One reference-counted telemetry stream shared by dashboard, menu, and sessions.
- Rolling bounded history with statistics calculated off the main thread.
- Five-minute hostname and address caching with cancellable probe deadlines.
- Game Mode uses event-triggered checks plus a 10-second inactive safety interval.
- Narrow command surface over XPC.
- Dashboard sampling rate configurable by user.

## 14. Build and Development

Prerequisites:

- macOS 13+
- Xcode supporting project targets and current SDK requirements

Open in Xcode:

```bash
cd PingWarden
open PingWarden.xcodeproj
```

Build from CLI (example):

```bash
xcodebuild -project PingWarden.xcodeproj -scheme PingWarden -configuration Debug build
```

Key project areas:

- App target: UI and orchestration.
- Helper target: privileged monitoring and control.
- Widget target: optional control-center/menu integration path.

## 15. Release and Distribution

Run the release command from a clean commit that is already pushed:

```bash
cd PingWarden/PingWarden
bash release.sh X.Y.Z ../../RELEASE_NOTES.md
```

The command creates a fresh unsigned archive and dSYMs, validates and signs the
app, helper, and widget, notarizes and staples the app and DMG, mount-tests the
DMG, signs the Sparkle archive and appcast, publishes the GitHub release and
Sentry dSYMs, and updates `gh-pages`.

Important:

- Appcast latest entry must match the intended newest version.
- Feed URL in shipped app must resolve to current appcast location.

## 16. Limitations and Tradeoffs

Behavioral tradeoff while blocking AWDL:

- Apple features that depend on AWDL (for example AirDrop/AirPlay/Handoff) may be unavailable until blocking is disabled.

Other practical limits:

- Automation features depend on system permissions, game metadata, and signed-release packaging.
- Game mode detection depends on permissions and app/game behavior.
- Network conditions and endpoint choice still influence baseline latency.

## 17. Operational Best Practices

Recommended usage:

- Start a Latency Session before a latency-sensitive game or call.
- Use dashboard target auto-select periodically if your network path changes.
- Keep update interval moderate unless actively investigating jitter.
- Use diagnostics export before opening support issues.

## 18. File Map

Main application:

- `PingWarden/PingWarden/PingWardenApp.swift`
- `PingWarden/PingWarden/PingWardenMonitor.swift`
- `PingWarden/PingWarden/DashboardView.swift`
- `PingWarden/PingWarden/PingWardenPreferences.swift`

Helper:

- `PingWarden/PingWardenHelper/main.m`
- `PingWarden/PingWardenHelper/PingWardenMonitor.h`
- `PingWarden/PingWardenHelper/PingWardenMonitor.m`
- `PingWarden/PingWardenHelper/com.amesvt.pingwarden.helper.plist`

Release/update:

- `appcast.xml`
- `PingWarden/PingWarden/release.sh`
- `PingWarden/PingWarden/notarize.sh`

## 19. Related Documentation

- [Quick Start](QUICKSTART.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [Repository Root README](../README.md)
- [Release Notes](../RELEASE_NOTES.md)

## 20. Credits

- [jamestut/awdlkiller](https://github.com/jamestut/awdlkiller)
- [james-howard/AWDLControl](https://github.com/james-howard/AWDLControl), SMAppService and XPC architecture inspiration

## 21. License and Pricing

The source code is MIT, Copyright (c) 2025-2026 Oliver Ames. You can build from source under MIT whether you buy a license or not. See the repository [LICENSE](../LICENSE).

The prebuilt, signed, and notarized app is free to download. Everything except enabling Ping Protection is free to use. Enabling Ping Protection in the prebuilt app requires a one-time $15 license at [Gumroad](https://amesconsulting.gumroad.com/l/pingwarden). One key works on the Macs you own. The app verifies once with Gumroad, then re-checks roughly every 6 hours and at launch; verification is offline-friendly for up to 14 days.

Why a license: After two years of free builds, donations cover only a fraction of the ongoing work — Developer ID signing, Apple notarization, testing across macOS releases, and release engineering. A one-time license for the Ping Protection feature makes that work sustainable without subscriptions, ads, or analytics. The source stays MIT and auditable.

If protection was enabled with an approved helper when you first launched version 4, it remains available for 90 days from that launch. Updates preserve the original deadline. Check the time remaining in **Settings → License**. When the transition ends, enter a license key there to keep protection available. If you donated through [Buy Me a Coffee](https://www.buymeacoffee.com/oliverames) before version 4, email [oliver@ames.consulting](mailto:oliver@ames.consulting) with your receipt and it will be honored as a full license.
