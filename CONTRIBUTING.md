# Contributing to Ping Warden

Bug reports and focused pull requests are welcome. Ping Warden includes a privileged helper, so changes that cross the app-to-helper boundary need especially careful review.

## Before writing code

Open an issue for a large feature or architecture change. For a small bug fix, a pull request with a clear reproduction is enough.

Keep macOS 13 compatibility unless the issue explicitly changes the supported versions. User-facing language should say "Ping Protection" rather than "AWDL monitoring."

## Build and test

Run the core test suite from the repository root:

```bash
swift test
```

Build the complete unsigned Release app:

```bash
xcodebuild build \
  -project PingWarden/PingWarden.xcodeproj \
  -scheme PingWarden \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

For this project, test helper registration with a Release build copied to `/Applications`. Builds launched from Xcode are suitable for UI work, but they do not exercise the project's helper registration flow.

Add focused tests for behavior that can run without AppKit or root privileges. For helper, XPC, signing, packaging, or update changes, include the exact manual validation you performed.

## Pull requests

Keep each pull request to one logical change. Explain the user-visible result, list the tests you ran, and call out changes to the privileged helper, XPC authorization, entitlements, diagnostics, or update delivery.

Do not commit credentials, private signing keys, provisioning profiles, notarization data, exported diagnostics, or personal network information.
