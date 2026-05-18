# Ping Warden Worklog

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
