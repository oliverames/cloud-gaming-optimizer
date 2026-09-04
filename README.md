<p align="center">
  <img src="PingWarden/PingWarden/AppIcon.icon/Assets/network-error-svgrepo-com.svg" width="80" height="80" alt="Ping Warden">
</p>

<h1 align="center">Ping Warden</h1>

<p align="center">
  <strong>Stop AWDL from reactivating during latency-sensitive games and calls.</strong>
</p>

<p align="center">
  <code>event-driven protection</code> &bull;
  <code>macOS 13+</code> &bull;
  <code>Intel and Apple silicon</code> &bull;
  <code>signed and notarized</code>
</p>

<p align="center">
  <a href="https://github.com/oliverames/ping-warden/releases/latest"><img src="https://img.shields.io/github/v/release/oliverames/ping-warden?style=flat-square&color=f5a542&label=Download" alt="Download"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-f5a542?style=flat-square" alt="License"></a>
  <a href="https://amesconsulting.gumroad.com/l/pingwarden"><img src="https://img.shields.io/badge/Gumroad-license-f5a542?style=flat-square" alt="Buy license on Gumroad"></a>
  <a href="https://www.buymeacoffee.com/oliverames"><img src="https://img.shields.io/badge/Buy_Me_a_Coffee-donate-f5a542?style=flat-square&logo=buy-me-a-coffee&logoColor=white" alt="Donate on Buy Me a Coffee"></a>
</p>

<p align="center">
  <a href="#install-approve-and-verify">Install</a> &bull;
  <a href="#pricing">Pricing</a> &bull;
  <a href="#how-it-works">How it works</a> &bull;
  <a href="#privacy">Privacy</a> &bull;
  <a href="#documentation">Documentation</a> &bull;
  <a href="#build-from-source">Build</a>
</p>

---

Ping Warden is an open source (MIT) macOS menu bar app for latency-sensitive games, calls, and cloud streaming. The source stays MIT and everything except enabling Ping Protection is free. Ping Protection watches Apple Wireless Direct Link (AWDL), the interface used by AirDrop, AirPlay, Handoff, and other nearby-device features, and keeps that interface down while it is active. The prebuilt app requires a one-time $15 license to enable Ping Protection; existing users who had protection enabled keep it for a 90-day transition.

<p align="center">
  <img src="docs/images/ping-warden-3-dashboard.png" width="920" alt="Ping Warden 3 dashboard showing a Latency Session, live latency, jitter, probe failures, and ping history">
</p>

## The tradeoff

Ping Protection temporarily makes AirDrop, AirPlay, Handoff, and other AWDL-dependent features unavailable on your Mac. Turn protection off when you need them, or use the 10-minute pause from the menu bar. Ping Warden restores AWDL when protection stops and during its removal flow.

That tradeoff is the point of the app. You choose when a latency-sensitive game or call matters more than nearby-device features.

## Why this exists

Running `sudo ifconfig awdl0 down` once is not enough because macOS can bring AWDL back up within seconds. A timer-based script reacts after the interface is already active, which still leaves time for channel switching to affect the connection.

## How it works

Ping Warden uses a privileged helper that waits for kernel route and interface events. When macOS tries to raise `awdl0` while Ping Protection is on, the helper takes it back down and increments an intervention counter. The dashboard puts that counter next to live latency, jitter, probe failures, and history so you can see what happened on your own network.

## Install, approve, and verify

### 1. Get the app

Buy the [Ping Warden License on Gumroad](https://amesconsulting.gumroad.com/l/pingwarden). The signed, notarized DMG is attached to the purchase, so it is in your receipt and your Gumroad library, and the license key arrives in the same email. Open the DMG, drag Ping Warden to `/Applications`, and launch the copy in Applications.

Want to try the free features first? The same build is on [Releases](https://github.com/oliverames/ping-warden/releases/latest). Everything except enabling Ping Protection works without a key, and any official build accepts the key from a later purchase.

### 2. Activate your license

Open **Settings → License** and enter the key from your receipt. The app verifies once with Gumroad and then works offline for up to 14 days. Existing users who had protection enabled before this release keep Ping Protection for a 90-day transition with no action needed. If you donated through Buy Me a Coffee before this release, email [oliver@ames.consulting](mailto:oliver@ames.consulting) with your receipt and it will be honored as a full license.

### 3. Approve the helper

In the welcome window, click **Turn On Ping Protection** after activation. If you already closed it, open **Settings → General** and click **Finish Setup**. Approve Ping Warden in System Settings when macOS asks. This one-time approval lets the app control wireless sharing.

### 4. Turn on Ping Protection and verify it

Enable **Ping Protection** from the menu bar. Without a key (and outside the transition window) the app points you back to **Settings → License** instead of turning protection on. Open the dashboard and confirm that protection is active. The dashboard shows live latency and counts each time the helper blocks macOS from reactivating AWDL.

The [Quick Start guide](PingWarden/QUICKSTART.md) covers first-run setup and the optional automation features.

## What Ping Warden includes

| Feature | What it does |
|---------|--------------|
| Ping Protection | Keeps `awdl0` down with an event-driven privileged helper |
| Live dashboard | Tracks latency, jitter, probe failures, history, and helper interventions |
| Game Mode auto-detect | Turns protection on for recognized fullscreen games after you grant Screen Recording access |
| Quick pause | Restores nearby-device features for 10 minutes, then returns to your previous protection state |
| Control Center widget | Provides a system toggle on macOS 26 or newer in signed release builds |
| Diagnostics export | Creates a local support snapshot that you can review before sharing |
| Automatic updates | Uses Sparkle and signed update metadata to deliver new releases |

Apple added third-party Mac controls to Control Center in [macOS Tahoe 26](https://developer.apple.com/videos/play/wwdc2025/278/?time=536), which is why the widget has a newer requirement than the rest of the app.

Ping targets include common public services, discovered GeForce NOW regions, your network gateway, and targets you add yourself.

## Pricing

Ping Warden stays open source under MIT. You can build from source, inspect it, and modify it under MIT whether you pay or not. The prebuilt, signed, and notarized app is free to download and everything except enabling Ping Protection is free to use.

**Why a license:** After two years of free builds, donations cover only a fraction of the ongoing work — Developer ID signing, Apple notarization, testing across macOS releases, and release engineering. A one-time $15 license for the Ping Protection feature makes that work sustainable without subscriptions, ads, or analytics. The tradeoff that defines this app stays exactly the same, and the source stays auditable under MIT.

Enabling Ping Protection in the prebuilt app requires that license at [Gumroad](https://amesconsulting.gumroad.com/l/pingwarden). One key works on the Macs you own. The app verifies once with Gumroad, then re-checks roughly every 6 hours while it runs and once at launch; verification is offline-friendly for up to 14 days.

**Transition for existing users:** If Ping Protection was enabled on this Mac before the licensed build first ran, it keeps working for a 90-day transition starting on that first launch. Check the time remaining in **Settings → License**. When the transition ends, enter a license key to keep protection available. The app shows a one-time notice on first launch of the licensed build to explain the change.

**Donors:** If you supported Ping Warden through [Buy Me a Coffee](https://www.buymeacoffee.com/oliverames) before this release, email [oliver@ames.consulting](mailto:oliver@ames.consulting) with your receipt and it will be honored as a full license.

## Privacy

Latency history, protection state, settings, and intervention counts stay on your Mac. Ping Warden does not send usage analytics.

The app makes a few narrow outbound requests:

- Sparkle checks the public appcast for updates.
- The dashboard checks `status.geforcenow.com` to discover GeForce NOW target hostnames.
- Anonymous crash reporting is off by default. If you opt in under **Settings > Advanced > Privacy**, reports exclude IP addresses, ping targets, network breadcrumbs, performance traces, and app-lifecycle tracking.
- TCP latency probes connect only to the target you select or ask Ping Warden to choose.

Diagnostics exports are written locally. Ping Warden never uploads them for you.

## Support Ping Warden

The source stays MIT and you can build it yourself whether you buy anything or not. The prebuilt, signed, and notarized app is free to download and everything except enabling Ping Protection is free to use.

If you supported Ping Warden on [Buy Me a Coffee](https://www.buymeacoffee.com/oliverames) before this release, email [oliver@ames.consulting](mailto:oliver@ames.consulting) with your receipt and I'll honor it as a full license. New licenses are a one-time $15 at [Gumroad](https://amesconsulting.gumroad.com/l/pingwarden) and cover the Macs you own. Donations made after this release still help with signing and testing, but they don't activate Ping Protection — for that, use the Gumroad license.

## Documentation

- [Quick Start](PingWarden/QUICKSTART.md) covers installation and first-run setup.
- [Full documentation](PingWarden/README.md) explains the architecture, settings, and operating model.
- [Troubleshooting](PingWarden/TROUBLESHOOTING.md) provides safe recovery steps and diagnostic commands.
- [Release notes](RELEASE_NOTES.md) record changes by version.
- [GitHub Issues](https://github.com/oliverames/ping-warden/issues) is the place to report a reproducible problem or request a feature.

## Build from source

```bash
git clone https://github.com/oliverames/ping-warden.git
cd ping-warden
swift test
open PingWarden/PingWarden.xcodeproj
```

The app requires macOS 13 or newer. Configure signing for the app, helper, and widget targets before running from Xcode. The full helper-registration flow only works when the built app is installed in `/Applications`; non-helper UI work can run from Xcode.

## Credits

- [jamestut/awdlkiller](https://github.com/jamestut/awdlkiller) provided inspiration for Ping Warden's approach to AWDL control.
- [james-howard/AWDLControl](https://github.com/james-howard/AWDLControl) provided a reference for the SMAppService and XPC architecture.

## License

The source code is MIT, Copyright (c) 2025-2026 Oliver Ames — build it, inspect it, and modify it under MIT whether you buy a license or not. See [LICENSE](LICENSE) for the full terms.

The prebuilt, signed, and notarized app is free to download. Everything except enabling Ping Protection is free to use. Enabling Ping Protection in the prebuilt app requires a one-time $15 license at [Gumroad](https://amesconsulting.gumroad.com/l/pingwarden). One key works on the Macs you own. The app verifies once with Gumroad, then works offline for up to 14 days.

Existing installs that had Ping Protection enabled before this release keep protection for a 90-day transition starting on first launch of the licensed build. Check the time remaining in **Settings → License** and enter a license before it ends to keep protection available. If you donated before this release, email [oliver@ames.consulting](mailto:oliver@ames.consulting) with your receipt and it will be honored as a license.

---

<p align="center">
  <a href="https://www.buymeacoffee.com/oliverames">
    <img src="https://img.shields.io/badge/Buy_Me_a_Coffee-donate-f5a542?style=for-the-badge&logo=buy-me-a-coffee&logoColor=white" alt="Donate on Buy Me a Coffee">
  </a>
</p>

<p align="center">
  <sub>
    Built by Oliver Ames in Vermont
    &bull; <a href="https://github.com/oliverames">GitHub</a>
    &bull; <a href="https://linkedin.com/in/oliverames">LinkedIn</a>
    &bull; <a href="https://bsky.app/profile/oliverames.bsky.social">Bluesky</a>
  </sub>
</p>
