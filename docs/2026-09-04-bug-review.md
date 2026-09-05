# Ping Warden bug review, September 4, 2026

Author: Oliver Ames

## Work status

- Complete: Review source, live Gumroad configuration, update feeds, and landing page.
- Complete: Fix confirmed defects and add regression coverage.
- Complete: Verify the app, storefront, landing page, and update behavior before publication.
- Complete: Publish and verify 4.0.2.
- Complete: Redesign and publish the native welcome in 4.0.3.
- Pending external result: GitHub macOS checks for c6ddfbc. Local Release/Debug builds and Linux CI passed.

## Confirmed findings

| Finding | Failure | Status |
| --- | --- | --- |
| Protection reconciliation bypasses licensing | Pause expiry or Game Mode reconciliation can enable protection after revocation. | Fixed; regression coverage or build verified |
| Transition expiry is not enforced during a long run | Periodic verification returns early without a stored key. | Fixed; regression coverage or build verified |
| License refresh consumes Gumroad uses | Omitting `increment_uses_count` uses Gumroad's true default. | Fixed; regression coverage or build verified |
| Malformed verification responses revoke cached licenses | HTML or invalid JSON destroys the offline entitlement. | Fixed; regression coverage or build verified |
| Legacy transition migration loses or restarts the window | A 4.0.0 transition is unsealed and its deadline is discarded. | Fixed; regression coverage or build verified |
| Transition status says Licensed | Refunds and retained keys also hide the remaining transition. | Fixed; regression coverage or build verified |
| Paid releases permit silent upgrades from free versions | Feeds lack the Sparkle paid-upgrade boundary at build 40000. | Fixed; regression coverage or build verified |
| Beta feed does not receive stable releases | Users opted into beta cannot reliably reach the latest stable release. | Fixed; empty beta feed now mirrors stable releases |
| Donor coupon disclosed publicly | An unlimited 100% discount appears in release notes and the feed. Live coupon has zero uses. | Restricted to zero redemptions and re-read successfully |
| Gumroad deliverables accumulate | Every release appends its DMG without replacing old content embeds. | Fixed; regression coverage or build verified |
| Landing instructions enable before activation | The license gate rejects the documented setup order. | Fixed; regression coverage or build verified |
| Landing free-feature labels imply free protection | Automation and widget labels omit the protection license requirement. | Fixed; regression coverage or build verified |

## Baseline observations

- At review start, main was clean at a8a9c5c. Latest public release was 4.0.1.
- Gumroad product ID matches the app, price is $15 USD, product is published, shipping and subscriptions are disabled.
- Buyer content contains the 4.0.1 DMG and a `licenseKey` node with activation instructions.
- Latest Build Verification run for main passed before this review.
- Baseline shell syntax checks passed. All 107 baseline core tests passed.

## Review coverage and verification

Source reviews cover licensing, app/widget gates, helper lifecycle, XPC, sessions, pause/Game Mode, dashboard/probes, release scripts, CI, feeds, and the landing page. Reviewer candidates were independently challenged before fixes.

### Additional fixes

- The helper reconnect path respects a newer Off command. The widget starts the app in the background before enabling protection, so the helper retains a durable app connection.
- Verification cannot recreate licensing state after removal. Expiry enforcement checks for a newer successful activation before stopping protection or showing an error.
- A separate one-shot marker protects migration of the unsealed 4.0.0 transition. An invalid existing seal never gets resealed as a legacy grant.
- First-run setup reports the actual protection state and links directly to License settings. The 4.0.2 welcome used a 560 by 600 point window. The final 4.0.3 redesign uses 540 by 640 points and fits ordinary text without scrolling.
- Releases require a fresh archive, an unused version, a newer build, authenticated GitHub access, valid license-key buyer content, and matching Sparkle signing keys.
- Both complete feeds are signed and independently verified with the app's public key. Publishing uses an isolated gh-pages checkout and keeps the source checkout on main.
- Release notes must exist before the build. Gumroad publication verifies the uploaded bytes, replaces only Ping Warden DMG embeds, and retains all other buyer content.
- The landing page removes unsupported ratings and refund claims, explains the 14-day offline limit, and makes transition details accessible inline.

### Verification completed before publication

- All 112 core tests passed, including malformed Gumroad responses, explicit non-incrementing verification, legacy transition boundaries, and protection reconciliation without a license.
- Nine isolated release-tool tests passed. These cover paid-upgrade boundaries, stable-to-beta synchronization, donor-code removal, build ordering, and preservation of buyer content and license-key blocks.
- Release app and widget built successfully. All shell scripts passed syntax checks and ShellCheck's error-level checks.
- Both prepared feeds passed independent Ed25519 verification. A deliberately altered temporary feed was rejected.
- Gumroad's live product is published at $15 USD with the app's product ID and a licenseKey content block. The exposed unlimited donor code was capped at zero redemptions, with zero prior uses.
- The corrected landing page passed Gumroad's sanitizer preview. Desktop (1440 pixels) and phone (390 pixels) layouts rendered with no horizontal overflow. Transition details opened correctly on the phone layout.
- The live storefront's purchase button reached Gumroad checkout showing Ping Warden License at US$15. No purchase was submitted.
- The Release app's welcome and License windows were launched and visually inspected. The welcome button opened License settings correctly. After refining the welcome layout with a compact header, grouped license controls, and trailing footer actions, a fresh build and relaunch confirmed all content fits with no scroll bar or scroll action.

### Limits and remaining publication checks

- Automatic approval review rejected a proposed customer-key verification test. No customer key was submitted. Successful activation and refund handling are covered by isolated response fixtures, not a real paid-key end-to-end test.
- A real privileged-helper registration and a complete installed-app Sparkle installation have not been exercised in this review. The installed 3.1.0 app did fetch 4.0.2 and render the paid-upgrade disclosure before installation. Its already-downloaded 4.0.1 offer retained old cached notes until that obsolete version was skipped; new feed metadata cannot replace an already-cached offer.
- 4.0.2 was published on September 4, 2026, at 20:52 UTC from commit 2675048. The public DMG is 5,778,500 bytes and matches SHA-256 `a9231ee131d0806dcce36132413c8ac34615a6ee351c088c910fe1b3f7543a40`.
- The downloaded app passed bundle/signature validation and Gatekeeper accepted its Notarized Developer ID. The downloaded DMG's stapled ticket validated.
- Both live feeds advertise 4.0.2 / 40002 with paid boundary 40000 and pass signature verification. GitHub Build Verification passed for the release commit (run 33918212513).
- Sentry received all six app/helper/widget debug companions for both architectures, and its release was finalized.
- Gumroad offers exactly one embedded versioned app download, 4.0.2, with activation text and its license-key block preserved. The uploaded bytes match the local release. Initial upload metadata was temporarily incomplete, so publication stopped before replacing content, then succeeded on retry. The publisher now waits a bounded period for metadata, with regression tests for delayed metadata, timeout, and same-size stale bytes.
- The corrected landing page and description are published. Older 4.0.0 public release notes no longer expose the donor code.

## References

- [Sparkle paid upgrades and signed update publication](https://sparkle-project.org/documentation/publishing/)
- [Gumroad license verification implementation](https://github.com/antiwork/gumroad/blob/main/app/controllers/api/v2/licenses_controller.rb)
- [Ping Warden storefront](https://amesconsulting.gumroad.com/l/pingwarden)

## Native welcome follow-up

The welcome is a transient utility window, not a settings form. It uses the shipped app icon, system typography and colors, concise benefit rows, and standard buttons. The price remains visible before setup. Helper approval details appear next to setup actions.

| Element | Behavior and accessibility |
| --- | --- |
| App icon and introduction | Decorative icon excluded from VoiceOver; text wraps at larger sizes. |
| Benefit rows | Each icon/title/description reads as one accessible item. |
| License link | Opens the existing License settings pane. No key or billing data is collected in onboarding. |
| Primary setup action | Native button with Return as the default shortcut; uses the existing helper/setup callback. |
| Not Now | Native secondary action; Escape closes the transient welcome. |
| Large text | Content and actions scroll together when accessibility sizes need more space. |

Reference: [Apple onboarding guidance](https://developer.apple.com/design/human-interface-guidelines/onboarding) calls for a brief, optional introduction. This design applies that guidance to the existing utility and keeps its setup behavior intact.

The follow-up was visually verified in Release/light and Debug/dark appearances. The minimum-size accessibility layout, Escape dismissal, and license navigation were checked. All text fits on the first welcome screen without scrolling. The view is now in `WelcomeView.swift`; setup instructions include the Settings fallback. Version 4.0.3 / 40003 was subsequently published and verified below.

### 4.0.3 publication verification

- Published September 4, 2026, at 21:09 UTC from `c6ddfbc`. All nine release steps completed, including Sentry and Gumroad.
- Public DMG: 5,768,408 bytes, SHA-256 `5183f2477fffe14bd8e132153378b8928c9d7f1cfa3af13f8282c6ac0b51165a`. Downloaded bytes match the release artifact. Bundle validation, Gatekeeper, and the stapled ticket pass.
- Both public feeds show 4.0.3 / 40003, minimumAutoupdateVersion 40000, and valid feed signatures. The installed 3.1.0 app fetched this version and displayed the price and transition notice before installation. No upgrade was installed on the user's Mac.
- Gumroad's buyer document offers the 4.0.3 DMG and retains activation instructions and the license-key block. The uploaded bytes match. The corrected setup guide is published and visually verified.
- Core coverage remains 112 passing tests; nine release-tool tests pass. Release and Debug app builds pass. Linux CI passed for c6ddfbc, while macOS runner jobs remained queued at this observation.

### Documentation follow-up

Both READMEs and Quick Start now identify the donor cutoff as version 4 and describe the approved-helper requirement and original transition deadline. The root privacy section and detailed License section disclose that activation and refresh send the key and product ID to Gumroad over HTTPS. The detailed guide also describes both update feeds, the paid-upgrade boundary, and replacement of the Gumroad download. These descriptions were checked against the release code, and all relative links in the three guides resolve.

At 21:28 UTC on September 4, 2026, the release's Linux tests and shell lint had passed. Its macOS build and security analysis were running. An obsolete dependency analysis was cancelled after confirming that its commit had been superseded.

### September 5 follow-through

The queued release and documentation checks subsequently passed, including macOS Build Verification and CodeQL. The second landing pass is published and documented in [the September 5 review](2026-09-05-landing-review.md).

After Oliver specifically requested verification of a new purchase, Gumroad accepted its issued key with non-incrementing verification against the app's product ID. This extends the earlier fixture-only activation evidence with a real paid-key server check. It does not establish inbox delivery, download completion, or activation on the buyer's Mac.
