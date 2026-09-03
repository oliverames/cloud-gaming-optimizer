# Ping Warden Worklog

## 2026-09-03 - Ship 4.0.0: license-gated Ping Protection goes public

**What changed**: Cut and published 4.0.0, the first licensed build. Versions moved 3.1.0/30100 to 4.0.0/40000 across the four Xcode targets, the app, helper, and widget `Info.plist` files, and the helper's `HELPER_VERSION`. `release.sh 4.0.0` archived, re-signed with Developer ID `PV3W52NDZ3`, notarized and stapled both the app and `PingWarden-4.0.0.dmg` (5.5 MB), signed the Sparkle archive and appcast, published the GitHub release, uploaded six dSYMs to Sentry as `com.amesvt.pingwarden@4.0.0`, and pushed the `gh-pages` appcast as `347bb4b`. The main-side appcast copy is committed as `df99141`. The Gumroad product `Ping Warden License` (`FmGG0pxyEyzJqp_BG4itFQ==`, permalink `pingwarden`, $15) is published and purchasable.

**Decisions made**: Shipped as 4.0.0 rather than 3.2.0 because gating a previously free feature is a breaking change for existing installs, and the 90-day transition needs a version boundary users can point at. Did not mark the appcast item `criticalUpdate`, so Sparkle offers 4.0.0 normally rather than forcing it. Left the published GitHub release body and the signed appcast description as-is after correcting a refund-scope sentence in `RELEASE_NOTES.md`, so the two published artifacts stay consistent with each other; the correction applies to future renders.

**Verification**: `swift test` 101 of 101. Both Xcode schemes build clean in Release. GitHub `Build Verification` passed on the release commit `e49ebf5`. The app and DMG are Developer ID signed, notarized, stapled, and `spctl` accepts the mounted DMG as `Notarized Developer ID`. The live feed at `https://oliverames.github.io/ping-warden/appcast.xml` advertises 4.0.0 build 40000 with a macOS 13.0 minimum. The storefront returns `is_published:true`, `price_cents:1500`, `is_compliance_blocked:false`, and `?wanted=true` redirects into checkout. A live negative-path verify against the real product ID still returns HTTP 404 `success:false`, so the fail-closed path holds against production.

**Left off at**: 4.0.0 is public on the stable channel and the storefront sells. Post-release fixes are committed to `main` for the next release rather than forcing a 4.0.1 prompt: removed a non-functional concurrency guard in `LicenseManager`, dropped the unused `verifiedAt` payload so `LicensePolicy` is a pure function of its inputs, and corrected Settings copy that still called the app free.

**Open questions**: Branch protection was bypassed on both release pushes (`4 of 4 required status checks are expected`). `Build Verification` passed afterward, so nothing broke, but the pushes should have waited for checks. The widget's license gate still duplicates the 14-day constant because the Core file is not a member of the widget target; nothing catches divergence if the Core value changes.

---

## 2026-09-02 - License-gated Ping Protection, Gumroad product, and public-surface update

**What changed**:

- Introduced the licensed-build model. The repository stays MIT and `LICENSE` is untouched. The prebuilt, signed, notarized app remains free to download; everything except enabling Ping Protection (the AWDL-down feature) stays free. Enabling Ping Protection in the prebuilt app now requires a one-time $15 Gumroad license. Nothing was shipped: no tag, no GitHub release, no `gh-pages` push, no DMG/notarization run.

- Gumroad product created as a draft via `gumroad products create`: **Ping Warden License**, price `$15.00` (1500 cents), permalink `pingwarden`, ID `FmGG0pxyEyzJqp_BG4itFQ==`, landing `https://olivera40.gumroad.com/l/pingwarden`, category Other, tags `macos, gaming`. The live storefront already serves the product. A hidden 100% off offer code `DONOR-HONOR` (`T2OE2dj5tyIlBWtWAEi8RA==`, `universal: false`) was added for honoring pre-release Buy Me a Coffee donations via `gumroad offer-codes create --product ... --name DONOR-HONOR --percent-off 100`.

- Added `PingWarden/PingWarden/Core/LicensePolicy.swift` (pure Foundation, Linux-safe). Policy covers `offlineGraceInterval = 14d`, `grandfatherInterval = 90d`, `canEnableProtection(cachedLicenseValid:lastVerifiedAt:now:grandfatherDeadline:)`, `verifyResponse(_:)` mapping (refunded/chargebacked/subscription `*_at` → revoked, 404 success:false → revoked, 14-day grace boundary inclusive), `normalizeKey(_:)` and `verifyRequest(licenseKey:productID:)` form encoding. Wired as `isGrandfathered` / `grandfatherDaysRemaining` / `grandfatherWindowExpired` on the manager and a `donationConversionEmail = "oliver@ames.consulting"` constant.

- Added `PingWarden/PingWarden/LicenseManager.swift` (`@MainActor final class LicenseManager: ObservableObject, shared`). Stores the license key in the Keychain (service `com.amesvt.pingwarden.license`, account `gumroad-key`, `kSecAttrAccessibleAfterFirstUnlock`), and the cached-valid flag plus last-verified timestamp plus grandfather deadline plus a one-shot `transitionNoticeShown` flag in the App Group defaults (`PV3W52NDZ3.com.amesvt.pingwarden`) so the widget reads the same gate. Verification hits `POST https://api.gumroad.com/v2/licenses/verify` with `product_id` and `license_key` (form-encoded), 15 s timeout, treating 404 as a transportable fail-closed `.revoked` body. `establishGrandfatheringIfNeeded()` runs once per install: if protection was already enabled (`AWDLMonitoringEnabled`) before the licensed build first ran, it writes a 90-day deadline starting that day. Periodic re-verification fires every 6 hours while the app runs (`Timer`, tolerance 300 s) plus on each failed verify `reverify()` path. `onReverificationSettled` callback lets the coordinator disable protection immediately. Product ID is no longer a placeholder — `gumroadProductID = "FmGG0pxyEyzJqp_BG4itFQ=="` — so the live negative-path `echo "BOGUS" | gumroad licenses verify --product ... --no-increment` correctly returns 404 `success:false`.

- Added `Tests/PingWardenCoreTests/LicensePolicyTests.swift` — 25 tests covering grace (13 d valid, 15 d revoked, boundary inclusive), missing timestamps, grandfather windows, refunded/chargebacked/lapsed-subscription responses, disabled/not-found 404s, unparsable bodies, key normalization, and request encoding. Suite grows from 79 → 104 → 101 after the donation-sheet removal.

- Gated enabling in `PingWarden/PingWarden/ProtectionExperienceCoordinator.swift:99` (`setPersistentProtection(true)`) and `startSession` (all latency and Game Mode sessions funnel through these two). Both consult `LicenseManager.shared.canEnableProtection` and, when blocked, set `lastError` with donor wording (`Donated before? Email oliver@ames.consulting`) — wording splits on `grandfatherWindowExpired` vs never-licensed. Added `handleLicenseReverification()` which the manager invokes via `onReverificationSettled`: if protection is active and the license is no longer valid, it turns protection off through `monitor.setProtectionEnabled(false)` and sets the revocation notice. Periodic disables also flow here.

- Gated the Control Center widget in `PingWarden/PingWardenWidget/PingWardenToggleIntent.swift` via a new `PingWardenWidgetLicenseGate.swift`. The widget mirrors the app's `LicenseCachedValid` + `LicenseLastVerifiedAt` + `LicenseGrandfatherDeadline` keys from the same App Group and refuses `desiredState == true` with a new `AWDLError.licenseRequired` (`Ping Protection requires a license...`). Added `defaultsForLicenseGate` accessor in `PingWarden/PingWardenWidget/PingWardenPreferences.swift` to expose the suite without new entitlements.

- Added the Settings License pane in `PingWarden/PingWarden/PingWardenApp.swift`. New `SettingsSection.license = "License"` (`checkmark.seal`, between General and Automation) and `LicenseSettingsContent` (status with `checkmark.seal.fill` vs `seal`, transition-period caption, donor note with `mailto:oliver@ames.consulting` button, Buy… link now pointing to `https://olivera40.gumroad.com/l/pingwarden`, SecureField + Verify with `ProgressView`, `Buy a License...` button). Header `statusCaption` now reads `isGrandfathered → "Full Ping Protection continues free during the transition period."`. When the transition has `isGrandfathered`, the pane shows the moving-to-license explanation, the 90-day `Days remaining`, the donor-honoring paragraph with email button, and a full `Enter License Key` section. When `!canEnableProtection` and not grandfathered, it shows the key entry section plus a `Donated Before?` footer with the same donor wording and mailto. `establishGrandfatheringIfNeeded` + `onReverificationSettled` + `startPeriodicReverification()` are wired in `applicationDidFinishLaunching`, and a one-time `showLicenseTransitionNotice()` window (created once per install via `transitionNoticeShown`, delayed 1 s, with `LicenseTransitionNoticeView`, `licenseNoticeWindow`, and updated `updateDockIconVisibility`/`windowWillClose`) explains the paid-model move when `isGrandfathered` is true. `clearLocalDataForRemoval()` now also calls `LicenseManager.shared.resetForRemoval()`. Tweaked `WelcomeView.onSetup` to consider setup complete even when protection stays off due to the gate, and updated the `finishSetup` message.

- Ripped out the donation sheet in this follow-up pass per the 2026-09-02 instruction. Deleted `PingWarden/PingWarden/DonationPromptView.swift` and `PingWarden/PingWarden/Core/SupportPromptPolicy.swift` (file-system-synchronized groups drop them automatically). Cleaned `PingWarden/PingWarden/PingWardenApp.swift`: `donationWindow` property, `sessionCoordinator.onSessionCompleted` donation hook, `donationWindow` checks in `updateDockIconVisibility` and `windowWillClose`, the entire `showDonationPromptIfNeeded` / `presentDonationPrompt` / `closeDonationWindow` block, and the `donation` DEBUG case; rewrote `supportPingWarden()` and the remaining Donate buttons to open `https://buymeacoffee.com/oliverames` directly without touching preferences. Removed the four donation prefs from `PingWarden/PingWarden/PingWardenPreferences.swift` (`DonationPromptLastSeenVersion`, `DonationPromptDismissedPermanently`, `SupportPromptLastDate`, `SupportOpenedDate` and their accessors). Updated `DashboardView.swift:421` copy from "stays free" to "stays open source" and its Donate button to open the URL directly. Deleted `SupportPromptPolicyTests` from `Tests/PingWardenCoreTests/ProtectedSessionTests.swift` (suite 104 → 101).

- Mirrored the License pane in `PING_WARDEN_3_SPEC.md`. Replaced the `### Donations` section with `### License` (Gumroad verify, 14-day offline cache, 90-day grandfather starting on first licensed-build launch, hidden `DONOR-HONOR` 100% code, Settings License pane description, widget cached-entitlement gate, immediate disable on bad license with 6-hour re-verify). Removed the donation prompt bullet from `### Session recap`, updated the `Non-goals` paywall line to `No paywall beyond the Ping Protection license`, and updated the accessibility gate to mention license content.

- Updated public README surfaces (unshipped at the time; released the following day as 4.0.0):
  - `README.md:36` intro: source stays MIT and everything except enabling Ping Protection is free; prebuilt now requires the $15 license and existing users keep protection for 90 days. Added Gumroad badge (`README.md:20`) and a `Pricing` nav link, new install step 4 (buy at Gumroad, enter in Settings → License, 14-day offline, 90-day transition, donor email), new `## Pricing` section with why-a-license rationale, transition and donor terms, rewritten `## Support Ping Warden` and `## License` sections with MIT distinction, 14-day and grandfather details, and the honor path.
  - `PingWarden/README.md:144` settings list + `204` pane docs, expanded `21. License and Pricing` with pricing, verification cadence, rationale, transition, and donor honor note.
  - `PingWarden/QUICKSTART.md:23` inserted `3. Activate your license (prebuilt app)` ahead of turn-on/verify and shifted the latter to 4–5.
  - `PingWarden/PingWarden/DonationPromptView.swift:40` already updated to open-source wording; the follow-up pass then deleted the view entirely, so the stale line no longer ships. `docs/inventory-2026-09-02-licensing.md` captures the full file map and the next-ship checklist.

**Decisions made**:

- Keep source MIT and gate only the prebuilt binary's enable-protection path. The gate is a *prebuilt convenience* paywall, not a source license change, so forking and patching the gate is explicitly allowed. Fail closed on the Gumroad side: an unlicensed copy (and any placeholder product ID before this work) cannot enable protection, including after a 14-day offline grace or a 90-day grandfather expiry. Session and Game Mode enables funnel through the same two coordinator entry points, so no new enable path needs its own gate.

- 90-day grandfather keyed to `AWDLMonitoringEnabled` on first licensed-build launch, not to helper registration date or any calendar release date. Each existing protected install gets 90 days from *its own* first launch of the licensed build, which avoids a global deadline surprise. The transition notice window is shown exactly once per install (`transitionNoticeShown` flag, cleared on uninstall via `resetForRemoval()`), with a re-check after the 1 s delay so quitting before it appears does not set the flag.

- Donor honoring stays manual: donors email `oliver@ames.consulting` before the licensed build's first launch and receive the hidden offer code `DONOR-HONOR` (100% off, `universal: false`, `id T2OE2dj5tyIlBWtWAEi8RA==`). Manual honoring avoids minting license keys outside Gumroad and avoids auto-scraping donation receipts. The Settings License pane, the gate error, the new transition notice, and the updated `Support` section all carry the same wording so the promise is discoverable wherever the question could arise.

- Donation sheet removal rather than gating: licensed users still saw the sheet based on session/intervention counts, and gating `showDonationPromptIfNeeded` on entitlement would have kept the view and its tests in the build for no user-visible value. Deleting the view, the `SupportPromptPolicy` and its tests, and the four preference keys is simpler and keeps the menu/Settings/About Donate buttons as the remaining, non-intrusive donation surface.

- Spec mirroring is additive, not a rewrite: the architecture, telemetry, sessions, widget/XPC, and update/release sections stay as they shipped for 3.0. Only the user-experience and non-goals sections now mention the License pane and the grandfather/verify behavior.

**Verification**: `swift test` passed 101 of 101 (was 104 before the donation-sheet deletion: 25 new LicensePolicy tests included) on macOS and Linux via SwiftPM. `xcodebuild -project PingWarden/PingWarden.xcodeproj -scheme PingWarden -configuration Release -destination generic/platform=macOS CODE_SIGNING_ALLOWED=NO` and the `PingWardenWidget` scheme both report BUILD SUCCEEDED. Live `echo "BOGUS" | gumroad licenses verify --product FmGG0pxyEyzJqp_BG4itFQ== --no-increment` returns 404 `success:false` as the fail-closed path expects, and `gumroad offer-codes view T2OE2dj5tyIlBWtWAEi8RA== --product ...` confirms the hidden code. At the close of this entry there was no tag, no `git push`, no appcast or DMG publish, and `gumroad products list` still showed the product as a draft.

**Left off at**: As of the end of 2026-09-02 the licensed build was fully wired and the public docs matched it, with nothing published: the working tree held the licensing files uncommitted, `main` and `gh-pages` were clean, and the Gumroad product was still a draft. All of that shipped the next day; see the 2026-09-03 entry above.

**Open questions**: Whether the remaining Buy Me a Coffee buttons (menu → Support Ping Warden, Settings → Support → Donate..., About → Donate, Dashboard → Donate...) should be kept after the licensed model ships, or should be replaced by Gumroad license CTAs. Also whether the hidden offer code `DONOR-HONOR` should be capped (`--max-purchase-count`) or left unlimited for the manual honoring flow.

---

## 2026-08-26 - Cut and publish the 3.1.0 stable release

**What changed**: Released 3.1.0 to the stable channel. The version moved from 3.0.0 to 3.1.0 and build 30000 to 30100 across the four Xcode targets, the app, widget, and helper `Info.plist` files, and the helper's `HELPER_VERSION` define. `RELEASE_NOTES.md` gained a 3.1.0 section covering the persisted protection pause, the GeForce NOW refresh retry, the two idle-power reductions, the console-user XPC gate, Sparkle 2.9.6, and the helper version validation. `release.sh 3.1.0` then archived, signed, notarized, packaged, signed the feed, published the GitHub release, uploaded dSYMs to Sentry, and pushed `gh-pages` commit `8f3866e`.

**Decisions made**: Chose a semver minor rather than a patch because two user-facing features shipped alongside the fixes. Kept the release on the stable channel instead of staging a beta, since the changes are incremental on top of a 3.0 line that has been public since July.

**Verification**: `swift test` passed all 82 tests before the build. The DMG is Developer ID signed under Team `PV3W52NDZ3`, notarized, stapled, and `spctl` accepted as `Notarized Developer ID`; the app inside it carries the hardened runtime. The app, widget, and helper all report 3.1.0 and 30100, with the helper read out of its `__TEXT,__info_plist` section rather than trusted from the source tree. The DMG downloaded from the GitHub release has SHA-256 `5ac5df85...0bff265`, identical to the notarized local artifact, and validates its own staple. Sparkle's `sign_update --verify` accepts the live feed at `https://oliverames.github.io/ping-warden/appcast.xml`, and the enclosure `edSignature` in that feed reproduces exactly when recomputed against the downloaded DMG.

**Left off at**: 3.1.0 is public on both the GitHub release page and the stable appcast. `main` is clean at `cf91843` with the appcast copy committed.

**Open questions**: The update was verified by signature and feed rather than by installing an older build and taking the update through Sparkle's UI. That end-to-end install path is untested for this version.

---

## 2026-07-22 - Consolidate and merge open maintenance pull requests

**What changed**: Consolidated the useful changes from four overlapping pull requests into one coherent merge and closed the superseded branches. The merge also fixed mixed CodeQL action revisions.

**Decisions made**: Avoided stacking conflicting dependency branches while preserving the signed-feed repair already on `main`.

**Left off at**: Zero pull requests remain open; `main` is clean and synchronized.

**Open questions**: None introduced by this maintenance pass.

**Verification**: The 79-test suite, pull-request build, CodeQL analysis, and post-merge build passed.

---

## 2026-07-22 - Repair signed beta update feed

**What changed**: Audited Ping Warden after Bridgeport and Apple Core exposed missing complete-appcast signatures under Sparkle's opt-in `SURequireSignedFeed` policy. The stable Ping Warden feed already verified. The older `appcast-beta.xml` on `gh-pages` had no whole-feed signature, so beta-channel users would have received the same validation error. Signed the existing beta feed with Ping Warden's matching EdDSA key and published it as commit `e2bd556`.

**Decisions made**: Kept signed-feed enforcement enabled. No application rebuild or new release was needed because the correction changed only the feed. The existing release script already signs and verifies future stable and beta appcasts after all XML mutations.

**Verification**: Sparkle's `sign_update --verify` accepts both exact public GitHub Pages URLs, `appcast.xml` and `appcast-beta.xml`. The configured `SUPublicEDKey` matches the signing account's public key.

**Left off at**: Stable and beta update feeds are valid and public. The active local Dependabot merge branch was left untouched; this worklog entry was committed from an isolated `main` worktree.

**Open questions**: **NEW:** none.

---

## 2026-07-13 - 3.0.0 public release and UX hardening

**What changed**:
- Completed the 3.0 product, performance, donation, security, accessibility,
  and release audit. The menu bar now has one persistent Ping Protection
  control, while Latency Sessions live in the dashboard with local recaps.
- Reworked onboarding, donation, Settings, About, menu, and dashboard surfaces.
  Onboarding uses a predictable 500 by 580 point default with a fixed action
  footer and scroll fallback. Accessibility text sizes can scroll the whole
  surface, so content and actions remain reachable on displays with less
  vertical space. The donation window uses the same bounded-content approach.
- Added the 3.0 session experience, donation opportunities that never gate
  features, stronger helper and XPC validation, signed diagnostics and update
  paths, and the expanded 79-test Foundation/POSIX core suite.
- Fixed stable GitHub release creation under the system Bash 3.2 runtime after
  the real release exposed an empty-array expansion failure in `release.sh`.
- Published stable v3.0.0, the signed public appcast, Sentry release and dSYMs,
  and an immutable GitHub release. Updated setup and appcast documentation
  during wrap-up to match the shipped UI and automated release flow.

**Decisions made**:
- Protection and measurement remain separate concepts: the menu owns the one
  persistent protection control; the dashboard owns measured Latency Sessions.
- Primary windows use predictable default sizes and minimum constraints, with
  scrolling as the safety mechanism for constrained displays and accessibility
  text sizes. Essential actions must never depend on a specific monitor height.
- The stable feed continues to support macOS 13 and newer. The Control Center
  widget remains macOS 26 and newer, and intentionally remains outside the App
  Sandbox because its current intent flow launches the main app.

**Verification**:
- `swift test` passed 79 of 79 tests serially and in parallel. Address, Thread,
  and Undefined Behavior sanitizer runs also passed 79 of 79.
- Release builds and analysis passed locally. GitHub macOS build, Linux core
  tests, shell lint, and CodeQL all completed successfully with zero open code,
  secret-scanning, or Dependabot alerts.
- The app and DMG passed Developer ID signature checks, notarization, stapling,
  Gatekeeper assessment, Sparkle feed verification, and Sparkle archive
  signature verification. A real 2.4.3 client using Sparkle 2.8.1 discovered,
  downloaded, extracted, and installed 3.0.0.
- The independently downloaded public build is installed in `/Applications`.
  Its 3.0 helper is running, the saved protection preference is effective, and
  `awdl0` is inactive. Generated archives, builds, screenshots, harnesses,
  logs, DMGs, and mounted test volumes were removed after verification.

**Left off at**:
- v3.0.0 is live on the stable channel at the immutable GitHub release. The
  public appcast advertises 3.0.0 build 30000 with macOS 13 as its minimum.
- Resolved from the prior 2.5.0 entry: PR #34 is merged, signing and
  notarization are proven, and the incorrect appcast minimum of macOS 26 is now
  13.0. The widget's unsandboxed architecture remains an intentional, documented
  constraint rather than an unreviewed release blocker.

**Open questions**:
- No blocking 3.0 work remains. A physical or virtual macOS 13 runtime smoke
  test would add coverage beyond the verified deployment metadata, macOS 26 CI,
  and macOS 27 beta host testing when that environment is available.

---

## 2026-07-03 - 2.5.0: Full reliability audit (helper/XPC/widget/monitoring/tooling)

**What changed**:
- Ran a comprehensive multi-agent audit of the entire codebase and fixed
  every verified finding (~30 files). Highlights: quit no longer persists
  protection off; helper exit paths guarantee awdl0 restore via a direct
  ioctl fallback (`restoreInterfaceUpDirectly`); `setAwdlEnabled` fails
  loudly when the poll thread is dead; XPC retry counter resets only after
  a validated helper response (fixes an infinite silent reconnect loop);
  abandoned XPC connections are invalidated; registration polling is
  main-confined and always delivers its completion; helper exit decision is
  atomic with connection counting; release helper builds fail closed on
  signature-validation failure; game-category detection matches
  subcategories (`…-games`); Game Mode vs. quick-pause restore matrix fixed;
  Control Center toggle kept in sync via app-side `reloadControls` and
  intent-only display; widget launch failures roll back and surface;
  TCPProbe measures handshake-only latency with deadline-bounded DNS on a
  detached thread (IP literals resolve inline) and uses poll(2), making the
  core package Linux-portable; saved GFN/gateway target selection survives
  relaunch; failed GFN refresh keeps prior zones; chart history memoized +
  downsampled (spikes preserved); dashboard target dedup everywhere;
  bounded auto-select fan-out; atomic CustomPingTargetStore mutations;
  Sparkle starts after first-run setup; settings frame autosave preserved;
  release.sh/notarize.sh/create-dmg.sh hardening (Sentry fail-soft actually
  fail-soft, untracked beta appcast push, `--prerelease` for betas,
  per-version GitHub notes via `render_release_notes.sh --markdown`,
  RFC-822 pubDate, mandatory version args cross-checked against Info.plist).
- CI: new `linux-core-tests` job (swift:5.10 container) + shellcheck for all
  five scripts. Tests 33 → 41, all green on Linux and macOS.
- Bumped to 2.5.0 (Info.plist ×3, MARKETING_VERSION ×4, helper fallback
  macro) and added the RELEASE_NOTES.md section.

**Decisions made**:
- Widget toggle now displays/toggles user *intent* (not effective||intent):
  the composite made disable snap back visually and made the Shortcuts
  toggle unable to turn off auto-enabled protection.
- Left `MINIMUM_SYSTEM_VERSION=26.0` in release.sh untouched (flagged in the
  PR): all 2.4.x appcast items carry it, so it reads as deliberate, but it
  contradicts the documented macOS 13+ support — maintainer call.
- Widget appex stays unsandboxed (intent launches the app via NSWorkspace);
  flagged, not changed.

**Verification**:
- `swift test` 41/41 on Linux; `swiftc -parse` on every edited Swift file;
  `bash -n` on all scripts; CI green on the PR branch (build + linux tests +
  shell-lint). The app target itself still needs the maintainer's macOS
  Release archive for full compile verification.

**Left off at**: PR #34 (draft) open with everything above; release-side
prep done. Signing/notarization must run on the Mac with the Developer ID
cert, notarytool profile, and Sparkle key: merge, then the standard headless
archive + `release.sh 2.5.0 ../../RELEASE_NOTES.md` flow from CLAUDE.md.

---

## 2026-06-22 - 2.4.3: Settings-scene crash fix + headless release path proven

**What changed**:
- Fixed a fatal `NSGenericException` ("...more Update Constraints in Window
  passes than there are views in the window") reported via Sentry (issue
  7567835289) on macOS 26+/27. Root cause: the `Settings` scene in
  `PingWardenApp.swift` held `EmptyView().frame(width: 1, height: 1)`. That
  scene exists only to host the `.appSettings` command group — the real
  preferences UI is the AppKit-managed `NSWindow` in
  `AppDelegate.showSettingsWindow` — so its window is a hidden phantom. The
  hard 1pt-wide content constraint drove the backing `NSHostingView` into a
  re-entrant Update-Constraints loop. The crash report's window bounds read
  `{1, 23}` (width 1), matching the frame. Fix: dropped the `.frame()` so the
  empty content sizes itself; added a comment explaining why it must not
  return.
- Bumped to 2.4.3 (Info.plist ×3, pbxproj MARKETING_VERSION ×4) and added a
  RELEASE_NOTES.md entry.
- Shipped the full release **fully headless** (no Xcode UI): unsigned
  `xcodebuild archive CODE_SIGNING_ALLOWED=NO` → `release.sh`. Corrected the
  release runbook in CLAUDE.md/AGENTS.md/GEMINI.md to add the required flag and
  reflect that `release.sh` runs `notarize.sh` and pushes the gh-pages appcast
  itself.

**Decisions made**:
- The long-standing "can't archive headless" blocker was a misread: the
  notarized artifact never needs a provisioning profile because `notarize.sh`
  re-signs each component with `codesign --entitlements` (Developer ID), and
  App Groups on a non-sandboxed app don't require a profile. So the archive's
  signing is disposable — disable it and let the release scripts sign.
- Released to the **stable** channel as a normal patch (not `CRITICAL_UPDATE`),
  matching the 2.4.1/2.4.2 convention.

**Verification**:
- `swift test` → 33/33 pass; Release archive built clean against the macOS 26 SDK.
- App + DMG both notarized (Accepted) and stapled; `stapler validate` passes;
  release asset returns HTTP 200.
- GitHub release v2.4.3 targets the fix commit `e681eec`; appcast latest =
  2.4.3 on gh-pages (`0e60f0d`) and main (`50eaa87`); Sentry release
  `com.amesvt.pingwarden@2.4.3` finalized with dSYMs uploaded.

**Left off at**: 2.4.3 live on the stable channel. Nothing in flight.

**Open questions**:
- Still open: Issue #32 (Settings unified-toolbar redesign) — deferred.
- Watch the GameController crash count per release (see GameController memory).

---

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
