# Ping Warden Full Documentation

This document is the detailed technical and operational guide for Ping Warden.

For quick setup, see [Quick Start](QUICKSTART.md). For issue recovery, see [Troubleshooting](TROUBLESHOOTING.md).

## 1. Overview

Ping Warden is a macOS latency-stability tool that keeps AWDL from reactivating during latency-sensitive work.

AWDL (Apple Wireless Direct Link) is used by Apple ecosystem features such as AirDrop, AirPlay, and Handoff. On some networks and workflows, AWDL interface transitions can correlate with sudden latency jumps. Ping Warden provides a controlled, user-friendly way to keep AWDL suppressed when desired, while retaining the ability to restore normal behavior instantly.

Primary goals:

- Keep latency stable for gaming, cloud streaming, and calls.
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
- Protected Session lifecycle and local recap history.
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
- Automation
- Advanced

### 8.1 Dashboard

Provides real-time latency visibility and tuning controls.

Cards include:

- Protected Session:
  - Start and end a measured game or call.
  - Review duration, median, p95, jitter, packet loss, and interventions.
  - Share a privacy-scrubbed text recap.

- Network Quality:
  - Current ping, average, best, worst, jitter, packet loss, AWDL state.
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
- Control Center Widget mode (macOS 26+, signed release builds only).

### 8.4 Advanced

Tools:

- Test the registered helper and signed XPC connection.
- Open Console logs.
- Export Diagnostics bundle.
- Re-register Helper.
- Uninstall flow.

## 9. Menu Bar and App Menu Integration

Menu bar:

- Primary AWDL toggle actions.
- Start or end a Protected Session.
- Optional live metrics in dropdown.
- Settings, About, Support, and update actions.

App menu (frontmost app state):

- `Check for Updates...` is injected/ensured when app is active with regular activation policy.
- This complements the status item update command.

## 10. Sparkle Update System

Update stack:

- Framework: Sparkle 2.9.4.
- Feed URL: `https://oliverames.github.io/ping-warden/appcast.xml`.
- Signature model: EdDSA (`SUPublicEDKey` in app plist).
- Signed feeds and pre-extraction archive verification are required.

Operational details:

- App clears stale user-default feed overrides at startup.
- Updater delegate provides canonical feed URL.
- Manual update checks available from both menu entry points.

Release wiring:

- `PingWarden/PingWarden/release.sh` signs artifacts and updates `appcast.xml`.
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

- Start a Protected Session before a latency-sensitive game or call.
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

## 21. License

MIT License. Copyright (c) 2025-2026 Oliver Ames.
