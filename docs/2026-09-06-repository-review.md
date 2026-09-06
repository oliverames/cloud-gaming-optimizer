# Repository review, September 6, 2026

Scope: the whole repository at `9e2d317` after the 4.1.0 release. Payment and
licensing configuration, advertised functionality against the code, the
dashboard graph, dead code, stray files, and a screen-by-screen UI review of
the app. The only changes made during this review are dead-code removals,
each verified by `swift test` and a Release build. No UI was changed; the UI
section is recommendations only.

## 1. Payment and licensing configuration

Verdict: consistent and fail-closed. Nothing here needs a fix.

| Item | App target | Widget target | Match |
| --- | --- | --- | --- |
| Gumroad product ID | `FmGG0pxyEyzJqp_BG4itFQ==` (`LicenseManager:34`) | n/a, widget never verifies | live listing confirms |
| Purchase URL | `amesconsulting.gumroad.com/l/pingwarden` | n/a | live |
| Offline grace | 14 days (`LicensePolicy:64`) | 14 days (`WidgetLicenseGate:22`) | yes |
| Seal payload | `pwlic1\|valid\|verified\|grandfather\|seen\|device` | identical | yes |
| Seal secret | `LicenseStateSeal:25` | `WidgetLicenseGate:24` | byte-identical |
| Defaults keys | five `License*` keys (`LicenseManager:45-49`) | same five | yes |
| Clock rollback | verified > 1 h ahead or seen > 24 h ahead rejects | same thresholds | yes |
| Grandfather window | 90 days, one-shot keychain marker | reads the sealed deadline | yes |
| Device binding | IOPlatformUUID with two fallback markers | same | yes |

The widget duplicates the gate by design because Core files are not members
of the widget target. The duplication is exact today. The one structural risk
remains what `CLAUDE.md` already records: nothing catches divergence, so any
change to the payload, the secret, or the thresholds must touch both files. A
cheap guard would be a SwiftPM test that reads both source files as text and
asserts the secret and payload field list are identical, which would catch
drift without sharing code across targets.

## 2. Advertised functionality against the code

Every claim on the README, the Gumroad listing, and the landing page was
checked against the source. All hold.

| Claim | Evidence |
| --- | --- |
| Holds `awdl0` down the moment macOS raises it | `PingWardenHelper/PingWardenMonitor.m` AF_ROUTE listener and ioctl |
| Live latency and jitter dashboard | `PingMonitor`, `DashboardViewModel.stats`, Swift Charts in `DashboardView:750` |
| GeForce NOW regions as ping targets | `GeForceNOWDiscovery.swift` against `status.geforcenow.com/api/v2/components.json` |
| Game Mode auto-detect | `GameModeDetector`, now frontmost-app plus fullscreen paths (4.1.0) |
| Quick pause for ten minutes | `protectionExperience.pauseForTenMinutes()` (`PingWardenApp:1220`) |
| Control Center widget on macOS 26 | widget target `MACOSX_DEPLOYMENT_TARGET = 26.0` |
| Intel and Apple silicon | release binary is `x86_64 arm64` (`lipo`) |
| Signed updates via Sparkle, beta channel | `SUFeedURL`, `SUPublicEDKey`, `feedURLString(for:)` |
| Diagnostics export | `DiagnosticsExporter.exportSnapshot()` |
| 14-day offline grace | section 1 |
| Intervention counter | `DashboardView:457`, menu item "Wireless Interruptions" |

One wording gap rather than a functional one: the README tagline and the
Gumroad copy now say "cloud gaming", but the menu bar still labels the
counter "Wireless Interruptions" and the dashboard donation card still speaks
in the free-app voice. See section 6.

## 3. The dashboard graph

`DashboardView:750-860` is a Swift Charts chart with dashed latency threshold
rules, the successful-probe series drawn as segmented line plus gradient area
so gaps show as gaps rather than false lines, colour-coded spike points, an
annotated latest point, dashed event rules for session events, and failed
probes drawn as red rules with a point at zero. `PingChartDescriptor`
supplies an `AXChartDescriptor`, so VoiceOver can read the series. Y is
clamped to `0...chartYUpperBound` and X to an explicit `xDomain`.

This is a strong implementation and nothing in it is old code. The
recommendations in section 6 are about what it shows, not how it draws.

## 4. Dead code removed in this review

Eleven symbols had a definition and no reference anywhere in the app, helper,
widget, tests, or scripts. Removed, each verified by the full test suite and a
Release build:

| Symbol | File | Note |
| --- | --- | --- |
| `currentPingMs` | `PingMonitor.swift` | superseded by `NetworkStatistics` |
| `getHistory(lastMinutes:)` | `PingMonitor.swift` | dashboard reads `snapshot.history` |
| `getStatistics()` | `PingMonitor.swift` | stats flow through `onStatsUpdate` |
| `NetworkStatistics.qualityColor` | `PingMonitor.swift` | `Quality.color` unused after this |
| `isDaemonInstalled()` | `PingWardenMonitor.swift` | commented "Legacy check" |
| `isDaemonVersionCompatible()` | `PingWardenMonitor.swift` | commented "Legacy check", v2.x era |
| `isHelperConnected` | `PingWardenMonitor.swift` | duplicate of `isMonitoring` path |
| `needsApproval` | `PingWardenMonitor.swift` | status read elsewhere directly |
| `startForGameMode()` / `stopForGameMode()` | `ProtectedSessionCoordinator.swift` | Game Mode now routes through `setGameModeActive` |
| `updateCustomTarget(...)` | `DashboardViewModel.swift` | no edit UI calls it |

Kept on purpose, with a reason:

- The App Group migration in `PingWardenPreferences:64-95` and the legacy
  grandfather key migration in `LicenseManager:250-275` are one-shot upgrade
  paths for installs older than 4.0.0. They are live code until the last 3.x
  install has upgraded, which the Sparkle logs can tell you. Revisit after
  4.2.
- `PingMonitor`'s "legacy single-owner" `start()`/`stop()` are still called
  by the dashboard.
- `script/build_and_run.sh` looked stray beside `scripts/`, but
  `.codex/environments/environment.toml` runs it, so it stays.
- `PING_WARDEN_3_SPEC.md` is a historical spec, last touched 2026-09-04. It
  is not wrong, but it describes 3.0 and sits at the repo root beside the
  README. Moving it to `docs/` is a tidy-up, not a cleanup, and is left for
  you.

## 5. Stray files and documentation

- Two READMEs: the root `README.md` (public, product-facing) and
  `PingWarden/README.md` (399 lines, technical). Both were touched on
  2026-09-05, so they are not stale, but two READMEs invite drift. The
  technical one could become `docs/ARCHITECTURE.md` with the root README
  linking to it.
- `PingWarden/TROUBLESHOOTING.md` (2026-07-13) already uses the "Ping
  Protection" wording and does not mention donations or the old name.
- All seven files in `scripts/` are referenced by `release.sh`, `notarize.sh`,
  or CI. None is orphaned.
- `docs/` holds five dated review files from the last two weeks. They are
  the audit trail and should stay.

## 6. UI review, screen by screen

Method: a Debug build from a scratch copy with every `com.amesvt.pingwarden`
identifier renamed to `com.amesvt.pingwardenreview`, so it ran beside the
real install without touching its preferences, licence cache, or keychain.
Screens were captured by window ID at 980 × 700 and, for the dashboard, at
980 × 1232. The build is unsigned and ran from a scratch path, so the helper
could not register, the widget could not load, and the licensed and
protected states were not visible. Those limits are listed at the end.

Nothing below was changed. Items are ordered by how much they matter, and the
first one is a correctness problem I introduced with 4.1.0 rather than a
taste call.

### 6.1 Automation, Game Mode row: now says the wrong thing

`PingWardenApp.swift:2129-2132`. The row shows a "Needs Permission" badge and
the caption "Turn on protection and record a local latency session while a
recognized game is fullscreen". Since 4.1.0 neither is true: detection works
from the frontmost app with no permission, and fullscreen is no longer
required. A user who declines Screen Recording now sees a badge telling them
the feature is unavailable when it is working. Recommended: drop the badge
when the toggle is on and the frontmost path is active, show a softer
"Fullscreen detection off" note only when the permission is absent, and
change the caption to "Turn on protection and record a latency session while
a game is running". This is the one item I would ship in 4.1.1.

### 6.2 Donate appears in four places beside a $15 product

The status menu ("Donate to Ping Warden…", `PingWardenApp:772`), General
Settings ("Support Development / Donate…"), the About window's first link,
and a line inside the dashboard's Latency Session card
(`DashboardView:422-430`). The General row explains the pre-4.0 honouring
rule well, so keep that one. Recommended: remove the dashboard line, which
sits between the session stats and the history disclosure and reads as a
free-app leftover; replace the menu item with "Buy a License…" while
unlicensed and nothing while licensed; and put "Buy a License" ahead of
"Donate" in About.

### 6.3 Three different icons for one app

The app icon is the orange-and-grey arrows. The About window shows a blue
`antenna.radiowaves.left.and.right.slash` glyph (`PingWardenApp:2693`). The
status item uses `antenna.radiowaves.left.and.right` with and without the
slash (`PingWardenApp:801`). Welcome and General use the real icon. The
About glyph is the one to change, since it is the only place a user sees a
picture that is not on their Dock or Gumroad page. The status item is a
template symbol by necessity and is fine.

### 6.4 The dashboard's default window hides the chart

The dashboard needs about 1,230 points to show its six cards. At the default
980 × 700 the user sees the Latency Session card, Network Quality, and the
first 60 points of Ping History; the chart, the Latency Timeline, the Ping
Protection card, and Connection Settings are all below the fold with no
visual cue that they exist. Recommended: either a taller default and
minimum height when the Dashboard section is selected, or reorder so Network
Quality and the chart lead and the session card follows, since the chart is
the thing the free tier exists to show.

### 6.5 Welcome window

Clean and correctly priced. Three notes. The tagline "A quieter connection,
right from your menu bar" and the first benefit "Reduce wireless
interruptions" (`WelcomeView:83-96`) never say cloud gaming, GeForce NOW, or
stutter, so the first screen a buyer sees after reading the Gumroad page
speaks a different language from it. The primary action "Set Up Ping
Warden" renders as a plain grey button while "Enter or Buy a License…" is a
blue link, so the eye lands on the link; `.buttonStyle(.borderedProminent)`
on the setup button would fix the hierarchy. And there is roughly 150 points
of empty space between the licence link and the setup footer at the fixed
540 × 640 size.

### 6.6 Settings sidebar mixes a destination with sections

"Dashboard" is the first sidebar row of the Settings window and selecting it
swaps the content pane to the dashboard, so one window titled by its
section serves as both preferences and the live view. It works, and the
menu bar's "Open Dashboard…" lands in the same place, but the window then
reads "Dashboard" in the title bar with a settings sidebar beside it.
Recommended: leave the mechanism, but visually separate the Dashboard row
from the four settings rows with a section gap, and consider naming the
window "Ping Warden" rather than the selected section.

### 6.7 License section

Correct and honest. The "Donated Before?" card says "before this release",
which drifted the moment 4.0.1 shipped; the Gumroad copy already says
"before version 4". The price is not shown on this screen at all, so a user
who arrives here from the welcome link sees "Buy a License…" without the
number; "$15, once, for the Macs you own" beside the button would close
that. The lower 60 percent of the pane is empty, which is fine for a
settings pane but leaves room for "What the license covers" if you want it.

### 6.8 Latest session stats carry no judgement

The Latency Session card shows P95 713 ms and Probe Failures 56.2% in the
same neutral weight as a healthy 35 ms median. The Network Quality card
below it colours its numbers; the session card does not. Recommended: apply
the same `LatencyPalette` colouring to Median, P95, and Probe Failures in the
session summary so a bad session looks bad at a glance.

### 6.9 Connection Settings live on the dashboard

The Ping Server picker and custom targets sit at the bottom of the
dashboard, below the fold, while every other preference lives in Settings.
That placement made sense when the dashboard was the only window. Now that
Settings has Automation and Advanced, a "Targets" section there would match
where users look, and the dashboard could keep a one-line "Pinging
Cloudflare DNS (Global) · Change" link.

### 6.10 Small things

- "Wireless Interruptions" as the menu bar counter label, and "Show Live
  Metrics in Menu" as its toggle, versus "Menu Dropdown Metrics" for the
  same toggle in General Settings. Pick one name.
- "Status: Not Set Up" is a disabled menu item; consider making it the
  first item so the menu opens on state.
- General's "How It Works" paragraph is accurate and good; it is the
  clearest explanation of AWDL in the product and could be reused on the
  welcome screen.
- Advanced is the best-organised pane in the app and needs nothing.
- The About window credits `james-howard/AWDLControl` for the SMAppService
  and XPC architecture. Keep it; it is correct and it reads well beside the
  "formerly AWDL Control" line on the README.

### Not reviewed, and why

- The licensed state of every screen (green seal, days remaining, offline
  grace note), the protected state of the dashboard, the transition window
  "Ping Warden Is Moving to a License", and the Screen Recording and helper
  approval alerts. The review build cannot register a helper or verify a
  key without touching your real keychain and Gumroad use count.
- The Control Center widget, which needs a signed build.
- Dark appearance and Reduce Motion; captures were light mode only.

## 7. One data-location finding

`ProtectedSession.swift:284-289` stores session history at
`~/Library/Application Support/Ping Warden/protected-sessions.json`, keyed
by app name rather than bundle identifier. The review build, under a
different bundle ID, read your real history on first launch. That is
harmless in practice, and `performUninstall` does clear it
(`PingWardenApp:2619`), but it means any second copy of the app shares
history with the first. Moving it under the App Group container would match
where the preferences already live.

## Changes made during this review

- `e069697`: removed twelve unreferenced symbols (section 4).
- This document.
