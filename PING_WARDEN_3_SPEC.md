# Ping Warden 3.0 Product and Engineering Specification

## Product promise

Ping Warden 3 turns protection into measurable latency sessions. It keeps the
existing always-available menu bar protection, then adds a session workflow that
shows what happened without claiming that every wireless intervention prevented
a specific latency spike.

## Release sequence

1. Stabilize the update and release chain before any 3.0 beta is distributed.
2. Build the 3.0 architecture behind tested local models and services.
3. Validate the complete experience in signed Release builds.
4. Publish one stable 3.0 release only after every gate in this document passes.

## User experience

### Guided setup

- Explain that Ping Protection temporarily disables AirDrop, AirPlay, and
  Handoff while active.
- Let the user defer setup without becoming stranded.
- Show a persistent Finish Setup action whenever the helper is unavailable.
- Verify helper registration and response before declaring setup complete.
- Keep crash reporting off by default for new installations and explain the
  preference in plain language.

### Protected sessions

- A user can start and stop a session manually from the dashboard and menu.
- Game Mode can start and stop a session automatically.
- Starting a session enables Ping Protection if needed and remembers whether it
  should be restored afterward.
- A session records only local operational metrics: start/end time, sample
  count, successful/failed samples, median, p95, jitter, and helper intervention
  count delta.
- Hostnames, IP addresses, game names, and raw samples are not written into
  session history.
- Session history is bounded and stored locally.

### Session recap

- Show duration, median latency, p95, jitter, packet loss, and wireless
  interventions.
- Describe interventions as wireless interruptions blocked, not guaranteed lag
  spikes prevented.
- Provide a privacy-scrubbed text share/export action.
- Offer support only after demonstrated use and outside active gameplay.

### Support

- A contextual support prompt requires completed setup and either three
  completed sessions or a meaningful intervention threshold.
- Apply a cooldown after dismissal and a longer suppression after the user opens
  the support link.
- Never prompt during launch, an active session, an error, or update activity.
- Keep permanent opt-out and never gate features.
- Provide persistent Support Ping Warden actions in the menu, Settings, and
  About window.

## Architecture

### Telemetry

- One shared telemetry service owns probe scheduling, DNS/address caching,
  cancellation, history, and rolling statistics.
- Dashboard and menu surfaces subscribe to the same stream.
- UI receives immutable snapshots; slow settings and target state do not share
  the high-frequency observation path.
- DNS and connect work have one end-to-end deadline and can be cancelled.
- A bounded ring buffer replaces repeated full-array filtering.

### Sessions

- `ProtectedSessionCoordinator` is the main-actor owner of current session state.
- Foundation-only `ProtectedSession`, `ProtectedSessionSummary`, and policy
  helpers remain unit-testable through SwiftPM.
- `ProtectedSessionStore` persists a bounded JSON history with atomic writes and
  owner-only permissions.

### Widget and privileged control

- The widget connects directly to the privileged helper over XPC.
- The helper validates the widget's Developer ID/Team ID and bundle identifier.
- Shared defaults are display state only; distributed notifications are
  invalidation hints only and never authorize a privileged state change.
- Release helpers fail closed when signature validation fails.

### Updates and releases

- The release command creates its own archive and validates the staged artifact.
- Staged app, helper, widget, release arguments, appcast, and DMG metadata must
  agree before signing or publishing.
- The DMG is mounted read-only and its nested signatures, Team ID, entitlements,
  Hardened Runtime, Gatekeeper result, notarization ticket, and versions are
  checked on every release path.
- Sparkle archives and the appcast are signed.
- Stable and beta marketing versions use numeric `CFBundleVersion` values.

## Performance gates

Capture before and after measurements from signed Release builds for:

- idle app with default settings;
- live menu metrics;
- Game Mode detection with no game active;
- fullscreen activation and deactivation;
- dashboard at one-second sampling with a full history window;
- normal and impaired DNS;
- cancelled automatic endpoint selection.

Record CPU, memory, wakeups, probe duration, main-thread work, and SwiftUI update
cost. Product copy may use a numeric performance claim only when this benchmark
is reproducible.

## Public release gates

- All SwiftPM and Xcode tests pass from a clean checkout.
- Full Release app and helper analysis pass with no actionable warnings.
- Swift concurrency warnings are resolved.
- Accessibility checks cover VoiceOver labels, keyboard navigation, reduced
  motion, increased contrast, and maximum supported text size.
- Update tests pass from the last public 2.x version on macOS 13, 15, and 26.
- Signed app and DMG pass strict nested signing, Gatekeeper, notarization, and
  stapling checks.
- GitHub required checks, dependency alerts, security scanning, immutable
  releases, funding links, and community files are enabled.
- Stable appcast, GitHub release, release assets, dSYMs, and source tag all refer
  to the same commit and version.
- A clean-machine install, first-run setup, protection toggle, session, recap,
  update check, and uninstall flow are manually verified.

## Non-goals

- No silent behavioral analytics.
- No remote storage of latency sessions.
- No paywall or donor-only feature tier.
- No claim that an intervention proves a particular latency spike was avoided.
- No Mac App Store migration in 3.0.

## Validation record

Pre-release validation on July 12, 2026 used the public 2.4.3 app and a 3.0.0
universal Release build on the same Mac. Each app was launched alone and sampled
24 times at half-second intervals. The first four seconds were excluded from the
steady-state comparison.

| Idle metric | 2.4.3 | 3.0.0 | Change |
| --- | ---: | ---: | ---: |
| Average CPU | 2.112% | 1.837% | -13.02% |
| Average resident memory | 93.31 MiB | 95.68 MiB | +2.54% |
| Average threads | 12.50 | 8.56 | -31.50% |

The full-window sample, which includes startup, showed 3.0.0 using 13.30% more
average CPU and 3.78% more resident memory. This result prevents a startup-speed
claim in product copy. For a long-running menu bar app, the steady-state CPU and
thread reductions are the relevant improvement, while the small memory increase
is accepted for the bounded session model and shared telemetry service.

A 15-second Time Profiler recording of the live 3.0 dashboard at two-second
sampling reported zero potential hangs. The trace was deleted after the result
was recorded because process traces can include inherited environment metadata.
No numeric performance claim appears in product copy.
