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

The full stable release is prepared for version 4.0.4, build 40004. Public artifact, Sparkle, and Gumroad verification will be recorded after publication.
