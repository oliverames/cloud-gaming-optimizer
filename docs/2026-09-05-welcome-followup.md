# Welcome follow-up, September 5, 2026

Version 4.0.4 fixes an introduction that repeated when someone chose to leave helper setup incomplete. The layout from 4.0.3 remains unchanged.

## Finding and fix

Startup treated an unregistered helper as a first launch. As a result, choosing **Not Now**, closing the welcome, or opening License settings caused the welcome to return at the next launch. This also affected people using only the free dashboard.

The app now remembers that the welcome has appeared. Automatic presentation checks both this marker and the current helper state. Explicit setup actions remain available from the menu bar and **Settings → General → Finish Setup**. The existing app-data removal path clears the marker with the other preferences.

This follows [Apple's onboarding guidance](https://developer.apple.com/design/human-interface-guidelines/onboarding), read on September 5, 2026: introductions should be optional, should not repeat after dismissal, and should leave setup accessible later. Apple Developer access worked during this review.

## Verification before publication

- All 117 core tests passed, including five new tests for first presentation, persistence across state instances, registered helpers, app-data removal, and preservation of protection intent.
- All nine release-tool tests passed. Release and notarization scripts passed shell syntax checks, and all three bundle property lists passed validation.
- Built the full Debug app from an isolated source copy with separate app, helper, widget, preferences, and keychain identities. The production source differs only in those test identities.
- Launched the rendered welcome at its normal 540 by 640 point size. The icon, introduction, benefits, price, primary action, and **Not Now** control fit without scrolling.
- Chose **Not Now**, confirmed the persistent presentation marker, quit the test process, and launched a new process. The welcome did not repeat. Settings and the free dashboard remained available, with **Finish Setup** visible.
- Reviewed the explicit menu setup path in source. Privileged helper registration was not exercised in this isolated test. The installed app, its license, and its protection settings were not changed.
- Updated both READMEs, Quick Start, and release notes. The update notes retain the price, free features, original transition deadline, and donor instructions for users upgrading from a free version.

## Publication

The full stable [4.0.4 release](https://github.com/oliverames/ping-warden/releases/tag/v4.0.4), build 40004, was published at 16:56 UTC on September 5, 2026. The public tag points to the tested source commit `2b3c46a731d3391888a90ba2df95e5cfdfe08942`.

Checks completed by 16:58 UTC:

- Downloaded the public GitHub DMG independently. It is 5,771,634 bytes and exactly matches the release artifact. SHA-256: `9918cfb97dbc14a77bb84a942776302606119f7cdf6f5d55c86fde33cf2334fa`.
- Mounted the public DMG read-only. The app reports 4.0.4 / 40004. Its complete signature verifies, Gatekeeper accepts it as Notarized Developer ID, and the app and DMG have valid stapled notarization tickets. The signer is Oliver Ames, team `PV3W52NDZ3`.
- Both public Sparkle feeds advertise 4.0.4 / 40004, preserve paid-upgrade boundary 40000 and the $15 disclosure, and point to the verified download. Independently verified both complete feed signatures and the DMG signature against the app's public key. Public feed bytes match both committed feed copies.
- Gumroad is published at US$15. Its buyer content embeds only `PingWarden-4.0.4.dmg` and retains one license-key block. The publisher downloaded and checked the Gumroad file against the release artifact before replacing the old embed, then reread the resulting content.
- Sentry processed the archive's debug information, uploaded four missing files, and finalized `com.amesvt.pingwarden@4.0.4` with the correct source revision.
- GitHub Build Verification passed for the release source, including the complete macOS app, Linux core tests, and shell checks. CodeQL analysis was still running at this observation.

The landing page and checkout copy from the [earlier September 5 review](2026-09-05-landing-review.md) remain published. No buyer message was sent, and no additional customer-key verification was needed for this welcome-only change.
