# Ping Warden bug review, September 4, 2026

Author: Oliver Ames

## Work status

- Complete: Review source, live Gumroad configuration, update feeds, and landing page.
- Complete: Fix confirmed defects and add regression coverage.
- Complete: Verify the app, storefront, landing page, and update behavior before publication.
- In progress: Commit, publish the next release, and verify public artifacts.

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
- First-run setup reports the actual protection state and links directly to License settings. The welcome window opens at 560 by 600 points so ordinary text fits without scrolling.
- Releases require a fresh archive, an unused version, a newer build, authenticated GitHub access, valid license-key buyer content, and matching Sparkle signing keys.
- Both complete feeds are signed and independently verified with the app's public key. Publishing uses an isolated gh-pages checkout and keeps the source checkout on main.
- Release notes must exist before the build. Gumroad publication verifies the uploaded bytes, replaces only Ping Warden DMG embeds, and retains all other buyer content.
- The landing page removes unsupported ratings and refund claims, explains the 14-day offline limit, and makes transition details accessible inline.

### Verification completed before publication

- All 112 core tests passed, including malformed Gumroad responses, explicit non-incrementing verification, legacy transition boundaries, and protection reconciliation without a license.
- Six isolated release-tool tests passed. These cover paid-upgrade boundaries, stable-to-beta synchronization, donor-code removal, build ordering, and preservation of buyer content and license-key blocks.
- Release app and widget built successfully. All shell scripts passed syntax checks and ShellCheck's error-level checks.
- Both prepared feeds passed independent Ed25519 verification. A deliberately altered temporary feed was rejected.
- Gumroad's live product is published at $15 USD with the app's product ID and a licenseKey content block. The exposed unlimited donor code was capped at zero redemptions, with zero prior uses.
- The corrected landing page passed Gumroad's sanitizer preview. Desktop (1440 pixels) and phone (390 pixels) layouts rendered with no horizontal overflow. Transition details opened correctly on the phone layout.
- The live storefront's purchase button reached Gumroad checkout showing Ping Warden License at US$15. No purchase was submitted.
- The Release app's welcome and License windows were launched and visually inspected. The welcome button opened License settings correctly. After refining the welcome layout with a compact header, grouped license controls, and trailing footer actions, a fresh build and relaunch confirmed all content fits with no scroll bar or scroll action.

### Limits and remaining publication checks

- Automatic approval review rejected a proposed customer-key verification test. No customer key was submitted. Successful activation and refund handling are covered by isolated response fixtures, not a real paid-key end-to-end test.
- A real privileged-helper registration and a complete installed-app Sparkle upgrade have not been exercised in this review. Static gate checks, app/widget builds, and live artifact checks do not replace those end-to-end flows.
- Pending: public 4.0.2 DMG, notarization, stable and beta feeds, current Gumroad buyer download, published landing page, and GitHub checks.

## References

- [Sparkle paid upgrades and signed update publication](https://sparkle-project.org/documentation/publishing/)
- [Gumroad license verification implementation](https://github.com/antiwork/gumroad/blob/main/app/controllers/api/v2/licenses_controller.rb)
- [Ping Warden storefront](https://amesconsulting.gumroad.com/l/pingwarden)
