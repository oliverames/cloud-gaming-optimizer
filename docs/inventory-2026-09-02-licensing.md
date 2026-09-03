# Licensing Follow-up Inventory — 2026-09-02

## Headline

- Public README surfaces now match the licensed build. The source stays MIT and everything except enabling Ping Protection in the prebuilt app is free. Enabling now requires a one-time $15 Gumroad license (https://olivera40.gumroad.com/l/pingwarden), with a 90-day grandfather window and a donor-honor path.

## What was changed in this pass (public surfaces)

- **README.md** — Intro now states MIT source + licensed prebuilt gate. Added Gumroad badge, Pricing nav link, install step 4 (activate in Settings → License, 14-day offline grace, 90-day transition, donor email), new `## Pricing` section with why-a-license rationale, donor note, and rewritten `## Support Ping Warden` and `## License` sections. All copy uses your consulting email as conversion path.

- **PingWarden/README.md** — Added `License` to Settings sections list, added 8.5 License pane docs, expanded `21. License and Pricing` with pricing, verification cadence, rationale, transition, and donor honor note.

- **PingWarden/QUICKSTART.md** — Inserted step 3 Activate your license and shifted turn-on/verify to steps 4–5, with Gumroad link, offline grace, transition, and donor note.

- **PingWarden/PingWarden/DonationPromptView.swift:40** — `Ping Warden stays free either way.` → `Ping Warden stays open source either way.` to avoid contradicting the new gate.

## Previous licensing code changes (not re-shipped in this pass)

- `PingWarden/PingWarden/Core/LicensePolicy.swift` — Pure Foundation policy (offlineGrace 14d, grandfather 90d), Gumroad response mapping, key normalization, request building.

- `PingWarden/PingWarden/LicenseManager.swift` — Keychain storage, App Group cache, grandfather seeding on first licensed-build launch when protection was already enabled, 6-hour reverify, fail-closed verify path. Product ID now live: `FmGG0pxyEyzJqp_BG4itFQ==` (permalink `pingwarden`, draft).

- `PingWarden/PingWarden/ProtectionExperienceCoordinator.swift` — Gates on `setPersistentProtection(true)` and `startSession`; grandfather-expiry vs never-licensed wording split; revocation disables protection immediately.

- `PingWarden/PingWarden/PingWardenApp.swift` — License settings pane (status, transition messaging with `isGrandfathered`, donor note with mailto, Buy link), welcome/setup handling, App Store launch notice window shown once per install, `transitionNoticeShown` flag, Support section copy, settings license nav.

- `PingWarden/PingWardenWidget/PingWardenWidgetLicenseGate.swift` + `PingWardenPreferences` + `PingWardenToggleIntent` — Widget reads same cached entitlement, throws `licenseRequired` when unlicensed.

## Shipping status

> **Superseded 2026-09-03.** Everything below described the pre-release state. Ping Warden 4.0.0 shipped on 2026-09-03: GitHub release `v4.0.0`, notarized `PingWarden-4.0.0.dmg`, appcast published to `gh-pages` (`347bb4b`) and committed on `main` (`df99141`), Sentry release `com.amesvt.pingwarden@4.0.0`, and the Gumroad product published and purchasable. See the 2026-09-03 WORKLOG entry.

## What was deliberately left alone at the time (pre-ship)

- **No release cut, no push to `main` or `gh-pages`, no `appcast.xml` bump, no DMG/notarization run.** Per the 2026-09-02 instruction; all of this ran on 2026-09-03.

- `LICENSE` — Stays MIT verbatim. The gate applies to the prebuilt binary only; source license does not change.

- `appcast.xml` — Historical release notes inside the appcast keep their original Buy Me a Coffee lines. No retroactive rewrite of shipped release notes.

- `PING_WARDEN_3_SPEC.md` — Internal spec still mentions Donate actions; left for you to decide if spec should track the licensed model. Not a public surface.

- Menu bar `Support Ping Warden` (cup icon) and About donate button — Kept as-is. They still open the Buy Me a Coffee URL; the docs now explain that post-release donations do not activate protection.

## Audit of remaining public surfaces (2026-09-02)

- `rg` scan for `free|MIT|donate|Buy Me` across README, QUICKSTART, TROUBLESHOOTING, PingWarden/README returned consistent copy after this pass. No surviving `remains free and open source whether you donate or not` lines.

- `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` — No licensing claims to update.

- `RELEASE_NOTES.md` — Historical entries left alone by intent. Next release notes should carry the same three facts as the READMEs: 90-day clock starts on first launch of the licensed build, license at the permalink above, pre-release donors honored at your consulting email.

- `PingWarden/README.md` table `What Ping Warden includes` — Ping Protection row still says `Keeps awdl0 down with an event-driven privileged helper`. Intentionally left: the table describes what the feature does, the pricing section describes the gate. No contradiction.

## Follow-up that still needs a decision (parked)

- **Offer code vs manual license for donors.** The product is draft and `gumroad products publish` plus a 100%-off offer code (e.g., `DONOR-THANKYOU`, hidden) would give you a private URL to honor donor receipts without hand-minting keys. Create it when ready; no public visibility until you share it.

- **Spec doc.** If you want `PING_WARDEN_3_SPEC.md` to mention the License settings pane as a first-class surface, add it to the `Provide persistent ... actions in the menu, Settings, and` line.

- **Donation prompt eligibility after licensing.** `SupportPromptPolicy` still shows the sheet based on sessions/interventions. Licensed users will still see it. If you want it suppressed for licensed installs, gate `showDonationPromptIfNeeded` on `!canEnableProtection` or similar. Low priority before ship.

## Verification

- `swift test` — 104 tests pass (including 25 new LicensePolicy tests).
- `xcodebuild -project PingWarden.xcodeproj -scheme PingWarden` Release — BUILD SUCCEEDED.
- `xcodebuild -scheme PingWardenWidget` Release — BUILD SUCCEEDED.
- Live Gumroad negative-path verify (bogus key against `FmGG0pxyEyzJqp_BG4itFQ==`) — returns 404 `success:false` as `LicensePolicy` expects (fail-closed).

## File map for this pass

- `README.md:36`, `:20`, `:24`, `:72`, `:94`, `:119`, `:149` — licensing, pricing, donor honor
- `PingWarden/README.md:144`, `:204`, `:385` — settings list, pane docs, pricing
- `PingWarden/QUICKSTART.md:23` — activation step
- `PingWarden/PingWarden/DonationPromptView.swift:40` — open-source wording

## Next ship checklist (when you say go)

1. Create and verify a real purchase with the live product (check key arrives by email, verify in Settings → License).
2. Decide on DonationPrompt suppression for licensed installs (optional).
3. Decide on offer code for donor conversions (optional but makes your email promise operational).
4. Draft `RELEASE_NOTES.md` top entry with the same pricing/transition/donor copy.
5. Publish product (`gumroad products publish`) and cut the release.
