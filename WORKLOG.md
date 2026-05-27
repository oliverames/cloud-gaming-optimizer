# Ping Warden Worklog

## 2026-05-27 - 2.4.0 cycle: accessibility, Liquid Glass, beta channel

**What changed**:
- Accessibility audit pass across Dashboard, Settings, Welcome, About,
  and Donation surfaces. `LatencyPalette` now uses adaptive light/dark
  variants (light variants pass WCAG AA against `.regularMaterial`;
  previous palette scored 1.62–3.94:1 in light mode). Seven hero font
  sizes wrapped in `@ScaledMetric` so they scale with system Dynamic
  Type; decorative icons marked `.accessibilityHidden(true)`.
  `StatusBadge` extracted to replace three identical 1.71:1 inline
  pills. `PingGraphCard` now exposes both a summary `accessibilityValue`
  and a full `AXChartDescriptor` for rotor navigation. `MetricRow`,
  `LatencyTimelineCard` rows, `CustomServersCard` `TextField`s, and the
  trash button all got combined accessibility labels (placeholders are
  NOT labels in VoiceOver).
- Liquid Glass adoption gated on `@available(macOS 26, *)`.
  `dashboardCardStyle()` switches from `.regularMaterial` to
  `glassEffect(.regular, in: shape)` on macOS 26; the six dashboard
  cards are wrapped in a single `GlassEffectContainer` so they sample
  each other's refraction correctly (scattering across multiple
  containers produces inconsistent visuals). Inner `.quaternary`
  chrome on InterventionsCard and the Welcome info banner moved to a
  shared `InnerCalloutBackground` ViewModifier. SettingsView's
  manual NSToolbar config drops `showsBaselineSeparator` on macOS 26.
- Sparkle beta channel infrastructure. `PingWardenPreferences.betaChannelEnabled`
  (default false) routes Sparkle to `appcast-beta.xml` via a new
  `SPUUpdaterDelegate.feedURLString(for:)` override. Toggle lives in
  Settings → Advanced → Updates. `release.sh` accepts `BETA_CHANNEL=1`
  (matching the existing `CRITICAL_UPDATE=1` env-flag pattern) and
  writes to `appcast-beta.xml` instead of the stable appcast. Empty
  `appcast-beta.xml` pre-created on `gh-pages` (commit 137ed68) so
  opted-in users don't 404 before the first beta ships.
- AX5 defense-in-depth: `MetricRow`'s label column uses
  `@ScaledMetric(relativeTo: .caption)` so "Packet Loss"/"Average"
  don't truncate at large sizes; StatusCard's `currentPingBlock` and
  InterventionsCard's `interventionCountBlock` wrap their hero HStacks
  in `ViewThatFits` so the unit drops below when the card can't fit
  horizontally.
- General + Automation settings migrated from custom
  `SettingsGroup`/`Row`/`Divider`/`SectionHeader` infrastructure to
  native `Form { Section { Toggle / LabeledContent } }` (matches
  AdvancedSettingsContent's pattern from 2.3.x). Deleted the four
  unused custom components — net -77 lines.
- MARKETING_VERSION bumped 2.3.4 → 2.4.0 across 4 pbxproj entries
  and 3 Info.plist files (main app, helper, widget).
- CLAUDE.md Release Process section documents `BETA_CHANNEL=1`.
- Added `#Preview`s for Dashboard at AX5 and forced-light so future
  layout/contrast regressions are visible in Xcode's preview canvas.

**Decisions made**:
- Hero fonts treated as **content** (scaling) rather than decoration
  (fixed) — content-bearing 48pt numbers scale with `@ScaledMetric`;
  decorative 56/64/44pt icons scale too but are
  `.accessibilityHidden(true)`. Decision recorded via AskUserQuestion.
- `GlassEffectContainer` wrapping the six dashboard cards on macOS 26
  is in scope for 2.4.0 (not deferred). The morphing effect is the
  signature Liquid Glass visual.
- macOS 13 deployment target stays. `@available(macOS 26, *)` gates
  for everything Liquid Glass-specific. Bumping the floor would have
  cut off a meaningful chunk of the ~300-install base.
- For chart accessibility, both summary `accessibilityValue` AND
  `AXChartDescriptor` are provided. The summary is for "quick read";
  the descriptor enables rotor navigation through individual samples.

**Left off at**:
- All code committed and pushed across 7 commits (6 on `main`, 1 on
  `gh-pages`). Working tree clean.
- `MARKETING_VERSION = 2.4.0` in source but no release artifact yet.
- Next planned ship: `BETA_CHANNEL=1 bash release.sh 2.4.0-beta.1 …`
  (after archiving via Xcode UI per the standing archive blocker
  workaround).

**Open questions**:
- Visual verification on macOS 26 — needed before promoting any 2.4.0
  build to the stable appcast. Specifically the morphing glass effect
  between cards and the adaptive light palette against the new glass.
- Whether the new `#Preview("Dashboard — Dynamic Type AX5")` shows
  any layout overflow on macOS 26's renderer. Math says it fits in
  typical Settings widths but the canvas closes the loop cheaply.
- README user-facing mention of the beta channel — defer until the
  first 2.4.0 build actually ships, otherwise the docs are ahead of
  the user-visible feature.

**Verified**:
- `xcodebuild Debug` against MacOSX26.5.sdk: BUILD SUCCEEDED at every
  commit boundary, zero warnings in PingWarden code.
- `swift test`: 33/33 passing at every commit boundary.
- WCAG contrast math verified with python: all four
  `LatencyPalette` colors plus both `StatusBadge` variants pass AA
  (≥4.5:1) against light/dark × material/glass backgrounds.
- `grep` confirmed the four deleted custom Settings components had
  zero call sites before deletion.

---

# 2026-05-19 - v2.3.4 release polish and packaging cleanup

- Removed `notarize.sh` and `release.sh` from the main app target's shipped
  resources by adding them to the Xcode file-synchronized membership
  exceptions.
- Added `LSApplicationCategoryType=public.app-category.utilities` to the app
  Info.plist so the Release build no longer ships without a macOS category.
- Tightened primary UI copy around "Ping Protection" in Settings, Dashboard,
  and the Control Center widget.
- Fixed a Dashboard state mismatch where the interventions card could say
  protection was active while the app was off or not set up.
- Bumped app/helper/widget plist versions, Xcode `MARKETING_VERSION`, and
  helper runtime `HELPER_VERSION` to 2.3.4.
- Verified with `swift test`, unsigned Release Xcode build, app bundle
  resource inspection, Info.plist inspection, and manual computer-control
  testing of first launch plus Settings General, Dashboard, Automation, and
  Advanced.

# 2026-05-19 - v2.3.3 first-launch and Settings polish

- Reproduced and fixed the Settings titlebar overlap by pinning the Settings
  section header outside the scroller and removing Dashboard's nested
  `ScrollView`.
- Deferred Sparkle updater startup when the privileged helper is not registered
  so new users see Ping Warden's welcome/setup flow before any update prompt.
- Hardened the gh-pages appcast commit path in `release.sh` to disable GPG
  signing for non-interactive release automation.
- Fixed release preflight so `release.sh` accepts App Store Connect API-key
  notarization credentials, matching `notarize.sh`, when the keychain profile
  is not present.
- Added a GitHub release preflight and explicit `--target` so future release
  tags cannot silently point at the stale remote default branch when the local
  release commit has not been pushed.
- Verified with `swift test`, unsigned Release Xcode build, and manual
  computer-control testing of first launch, Settings Dashboard scroll, Add
  Server cancel, Automation, and Advanced.

## 2026-05-18 - v2.3.2 stability beta pass

**What changed**:
- Fixed target metadata wiring: helper now uses `PingWardenHelper/Info.plist`;
  widget now uses `PingWardenWidget/Info.plist` and
  `PingWardenWidget.entitlements`. A Release build before this change produced
  a widget `.appex` with `CFBundlePackageType=APPL` and no `NSExtension`
  dictionary even though `xcodebuild` succeeded.
- Bumped app/helper/widget plist versions, Xcode `MARKETING_VERSION`, and
  helper runtime `HELPER_VERSION` to 2.3.2.
- Hardened XPC reconnect handling so stale invalidation callbacks from a
  replaced connection cannot clear the fresh `_xpcConnection`.
- Added PingMonitor session IDs and in-flight gating so stale probes are
  dropped after target changes and slow probes cannot queue unbounded work.
- Made the helper control pipe write end non-blocking and guarded helper
  connection-count underflow.
- Added `RELEASE_NOTES.md` v2.3.2 entry and tightened README privacy wording.

**Audit notes**:
- Unused/stale candidates: `PingWardenHelper/Info.plist` and
  `PingWardenWidget/Info.plist` existed but were not actually wired into the
  Xcode targets before this pass. `PingWardenApp.swift` remains oversized
  (2,200+ lines) and still mixes app delegate lifecycle, menu construction,
  settings views, welcome/about views, and game detection.
- Code feel: the project is real in the low-level helper/core paths, but some
  UI/app-delegate code still reads like accumulated AI-assisted code because of
  oversized files, issue-number comments, and defensive explanatory comments
  around straightforward UI.

---

## 2026-05-18 (continued) - v2.3.1 prep round 2: default-on, UI modernization, archive blocker

**What changed**:
- Flipped crash reporting from opt-in to **on by default** via
  `UserDefaults.register()` in PingWardenPreferences. Existing v2.3.0
  users picking up v2.3.1 get crash reports enabled on first launch;
  explicit user toggles persist. README and v2.3.1 release notes updated
  to reflect the new posture. `enableAutoSessionTracking = false` so the
  README's "no usage telemetry" claim remains accurate.
- AdvancedSettingsContent refactored from hand-rolled
  SettingsGroup/SettingsRow to native `Form { Section { ... } }
  .formStyle(.grouped)` with `LabeledContent` rows. Inherits System
  Settings appearance on macOS 13-25 and Liquid Glass automatically on
  macOS 26+. Tap-to-toggle on the whole label area, addressing the one
  accessibility nit. General + Automation views still use the legacy
  chrome; queued for v2.3.2.
- Dashboard cards (StatusCard, PingGraphCard, LatencyTimelineCard,
  InterventionsCard, ServerSelectionCard, CustomServersCard) and the
  legacy SettingsGroup now use `.regularMaterial` instead of an opaque
  `unemphasizedSelectedContentBackgroundColor` fill. Translucent on all
  versions, Liquid Glass on macOS 26+. Two one-line changes cascade
  through all six dashboard cards and the General/Automation settings.
- Sentry project-side privacy hardening via API: `scrubIPAddresses=true`,
  `dataScrubber=true`, `dataScrubberDefaults=true` on the ping-warden
  project. Belt-and-braces with the SDK-side `sendDefaultPii=false`.
- `~/.claude/settings.json` env: added
  `XCODEBUILDMCP_ENABLED_WORKFLOWS=coverage,macos,project-discovery,session-management,simulator,ui-automation,utilities,workflow-discovery`.
  Default config only loads simulator tools; this adds the macOS
  workflow so future sessions can drive `xcodebuild archive` for macOS
  apps through XcodeBuildMCP rather than direct Bash.

**Decisions made**:
- AdvancedSettingsContent migrated to Form/Section first (most visible,
  has the new Privacy section). General/Automation deferred to v2.3.2.
- Crash reporting default flipped from off to on, with strong privacy
  posture preserved (anonymous, no IP, no targets, no sessions). The
  data utility outweighs the cost given how restrictive the data is.
- Sentry session tracking (`enableAutoSessionTracking`) left at false
  rather than reframing the README, on the theory that "no usage
  telemetry" is the cleaner promise.

**Left off at**:
- Six commits pushed since v2.3.0 (`f9413ff` through `566df00`).
  Working tree clean.
- v2.3.1 release pipeline ready. Info.plist at 2.3.1 across app, helper,
  and widget. RELEASE_NOTES.md v2.3.1 section in place. release.sh
  hardened (sentry-cli + op + token preflight) and CRITICAL_UPDATE=1
  flag wired.
- **Archive still blocked**. `xcodebuild archive` from CLI fails because
  the project uses CODE_SIGN_STYLE=Manual with an empty
  PROVISIONING_PROFILE_SPECIFIER, and the App Groups capability
  requires a profile. Local Provisioning Profiles directory is empty.
  Three resolution paths surfaced; user chose path 2 (enable macOS
  workflow in XcodeBuildMCP). settings.json env updated. After
  `/reload-plugins` or a fresh session, the macOS workflow tools should
  load and the archive can run through MCP.

**Open questions**:
- Will `/reload-plugins` cause XcodeBuildMCP to re-read its env, or does
  the MCP server cache its workflow allowlist at process start? If the
  latter, a full session restart is needed before we can call the new
  macOS tools. Unknown until tested.
- Even after MCP loads `macos` tools, can `archive_mac` produce a
  notarizable Developer ID archive without the provisioning profile, or
  does it hit the same App Groups blocker xcodebuild does? If so, the
  next escalation is editing the project's PROVISIONING_PROFILE_SPECIFIER
  to a known profile name, which the user would need to provide.
- General/Automation Form/Section migration deferred to v2.3.2.
- Token rotation still pending after v2.3.1 ships and crashes flow.

---

## 2026-05-18 - Team-product polish: crash reporting, embedded release notes, README refresh

**What changed**:
- Added opt-in Sentry crash reporting end-to-end. New `CrashReporter.swift`
  guarded by `#if canImport(Sentry)`; preference key
  `isCrashReportingEnabled` (default off) in `PingWardenPreferences`; UI
  toggle under Settings → Advanced → PRIVACY; `performUninstall` resets
  the key. Sentry SPM dep added directly to `project.pbxproj` (6 surgical
  inserts mirroring the Sparkle pattern) and `Package.resolved`
  refreshed. Sentry.framework now embedded in the app bundle, build
  succeeds, 33 Core tests still pass. release.sh has a new Step 6 that
  pulls the auth token from 1Password via `op read`, uploads dSYMs from
  `/tmp/PingWarden-${VERSION}.xcarchive/dSYMs`, creates and finalizes a
  Sentry release, and continues fail-soft on individual sentry-cli
  failures so a network blip doesn't strand gh-pages mid-publish.
- Built `scripts/render_release_notes.sh` to extract a version's section
  from `RELEASE_NOTES.md`, render via `gh api /markdown`, and wrap with
  brand-matched inline CSS (BMC orange `#f5a542`, light + dark mode).
  release.sh wires it into the appcast description CDATA. v2.3.0
  retroactively rendered and pushed to gh-pages, so v2.2.x users see the
  styled notes when Sparkle next offers them the update.
- Hardened release.sh:
    - Pre-flight check now enforces `sentry-cli`, `op`, and a readable
      vault token before notarization begins. The previous in-line
      "warn and continue" paths would have silently shipped without
      dSYM upload if tooling went missing.
    - `CRITICAL_UPDATE=1` env flag injects `<sparkle:criticalUpdate/>`
      into the appcast item. To be used for v2.3.1 because it lands
      observability everyone needs to be on.
- Refreshed README per the readme-style skill: imperative tagline,
  live-version Download badge (`shields.io/github/v/release/...`), new
  Privacy section documenting the opt-in Sentry posture, "How It Works"
  replacing "Why Not Just Run `sudo ifconfig awdl0 down`?", em dashes
  removed throughout. Same length, 49+/40- in diff.

**Decisions made**:
- Sentry SDK linked into the main `PingWarden` target only; the
  Objective-C helper daemon is NOT instrumented. Helper crashes will
  not appear in Sentry. Acceptable for v1 because the helper is small
  and well-tested; revisit if XPC-side incidents start showing up.
- Sentry token vaulted as `op://Development/PingWarden Sentry API Token/credential`.
  DSN is embedded in `CrashReporter.swift` (public-by-design, not a secret).
  Token is a User Auth Token (`sntryu_*`); rotate to an Org Auth Token
  later if CI/CD use ever happens.
- Privacy posture in `CrashReporter.swift`: `sendDefaultPii = false`,
  `tracesSampleRate = 0.0`, `enableNetworkTracking = false`,
  `enableNetworkBreadcrumbs = false` (the last one matters specifically
  because a TCP-probe app would otherwise leak target hostnames into
  crash payloads). `beforeSend` re-checks the opt-in preference as
  defense-in-depth.
- Sentry as enrichment, not a release gate. GitHub release publishes
  before the Sentry step; a Sentry network failure must not abort the
  script before gh-pages updates. Subshell with `set +e` localizes the
  relaxed error handling so the rest of release.sh keeps `set -e`'s
  strictness.
- Landing page workstream deferred. Skipping gh-pages branch reuse for
  marketing pages.

**Left off at**:
- Ready to ship v2.3.1 with `CRITICAL_UPDATE=1 ./release.sh 2.3.1 ../../RELEASE_NOTES.md`.
- Three manual user-side prep steps before that release:
    1. Bump `PingWarden/PingWarden/Info.plist` `CFBundleShortVersionString` to `2.3.1`.
    2. Add a `# Ping Warden 2.3.1` section at the top of `RELEASE_NOTES.md`.
    3. Sentry → Project Settings → Security & Privacy → enable
       "Prevent Storing of IP Addresses" as the wire-level backstop to
       the `sendDefaultPii = false` setting.

**Open questions**:
- Token rotation hygiene. The Sentry User Auth Token transited chat
  history when it was first shared this session. Once v2.3.1 ships and
  a real crash arrives in Sentry, revoke that token and replace via
  `op item edit "PingWarden Sentry API Token" --vault Development credential="$NEW"`.
  release.sh reads via `op://` so the rotation is invisible to the
  release pipeline.
- Helper-daemon crash reporting. Deferred. Different bundle, runs as
  root, and Sentry would need careful handling around keychain/network
  defaults in a privileged daemon context. Revisit if main-app crashes
  reveal cross-process incidents the XPC logs don't capture.
- Landing page (workstream #2). Pre-requisite is screenshots that don't
  exist yet. Deferred.

---
