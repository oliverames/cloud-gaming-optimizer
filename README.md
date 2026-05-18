<p align="center">
  <img src="PingWarden/PingWarden/AppIcon.icon/Assets/network-error-svgrepo-com.svg" width="80" height="80" alt="Ping Warden">
</p>

<h1 align="center">Ping Warden</h1>

<p align="center">
  <strong>Eliminate AWDL latency spikes on macOS for cloud gaming, competitive play, and live calls.</strong>
</p>

<p align="center">
  <code>sub-millisecond kernel response</code> &bull;
  <code>macOS 13+</code> &bull;
  <code>Developer ID signed</code> &bull;
  <code>Apple notarized</code>
</p>

<p align="center">
  <a href="https://github.com/oliverames/ping-warden/releases/latest"><img src="https://img.shields.io/github/v/release/oliverames/ping-warden?style=flat-square&color=f5a542&label=Download" alt="Download"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-f5a542?style=flat-square" alt="License"></a>
  <a href="https://www.buymeacoffee.com/oliverames"><img src="https://img.shields.io/badge/Buy_Me_a_Coffee-support-f5a542?style=flat-square&logo=buy-me-a-coffee&logoColor=white" alt="Buy Me a Coffee"></a>
</p>

<p align="center">
  <a href="#install">Install</a> &bull;
  <a href="#how-it-works">How It Works</a> &bull;
  <a href="#privacy">Privacy</a> &bull;
  <a href="#documentation">Documentation</a> &bull;
  <a href="#build-from-source">Build</a>
</p>

---

Ping Warden controls Apple Wireless Direct Link (AWDL), the protocol behind AirDrop, AirPlay, and Handoff that introduces sudden latency spikes during latency-sensitive activities. The app is Developer ID signed, Apple notarized, and updates over Sparkle with EdDSA-signed binaries.

## How It Works

Running `sudo ifconfig awdl0 down` from a script seems like a simple fix, but it doesn't solve the problem. macOS brings AWDL back up automatically, often within seconds. You might think you could write a polling script that takes AWDL down whenever it pops back up. The approach still introduces ping spikes during the seconds AWDL spools up. In some cases it makes things worse, because AWDL performs a channel scan each time it comes up, causing additional latency. Reducing the polling interval to 0.5 seconds doesn't fix it either.

Ping Warden takes a different approach. Instead of polling and reacting after AWDL is already up, the privileged helper daemon listens to kernel route and interface events through `AF_ROUTE` sockets. When macOS signals that AWDL is coming up, the helper counters the transition in sub-millisecond time, before the system can initiate its channel scan. The latency spike never occurs, rather than being shortened.

Other benefits over manual approaches:

- **One-time setup.** Approve the helper once during install. The app runs in the background after that, with no repeated `sudo` prompts.
- **Live visibility.** The dashboard shows real-time ping quality, intervention counts, jitter, and history, so you can verify the protection is working.
- **Safe controls.** Explicit enable and disable with proper lifecycle handling, plus a one-click diagnostics export for support.

## Install

1. Download the latest DMG from [Releases](https://github.com/oliverames/ping-warden/releases/latest) and drag Ping Warden to `/Applications`.
2. Launch the app and click **Set Up Now**.
3. Approve the helper in System Settings when prompted.
4. Toggle Ping Protection from the menu bar icon.

For detailed first-run instructions, see the [Quick Start Guide](PingWarden/QUICKSTART.md).

## Privacy

Ping Warden operates at the network layer on your Mac. The app has no telemetry, no analytics, and no network calls home for usage data. Two narrow exceptions:

- **Sparkle update checks** read the appcast feed at `oliverames.github.io/ping-warden/appcast.xml` to detect new versions. Sparkle sends a standard `User-Agent` and no other identifying information.
- **Crash reports** are on by default so bugs you don't see still get fixed. The data is anonymized: no IP address, no usage telemetry, no information about your ping targets, no app-lifecycle session events. Toggle off under Settings → Advanced → Privacy if you'd rather not send anything.

The source is open under MIT, so the data posture is verifiable by reading the code.

## Other Sources of WiFi Latency

AWDL is the most aggressive source of WiFi latency on Macs, but it isn't the only one.

### Location Services

macOS Location Services uses WiFi scanning to determine your geographic position. The `locationd` process periodically scans nearby networks, which can cause latency spikes similar to AWDL, especially when apps like Maps query your location.

To mitigate, disable Location Services entirely under System Settings → Privacy & Security → Location Services, or selectively disable it for apps that don't need it (check System Services at the bottom of the list).

Ping Warden focuses specifically on AWDL because it's the most common and aggressive source of WiFi latency spikes. Location Services scans are typically less frequent but can still contribute to occasional jitter.

### Will Apple Fix This in Hardware?

There has been speculation that Apple's newer in-house WiFi chips might mitigate this issue by using a separate radio for AWDL scanning, similar to how some devices handle background tasks without interrupting the main connection.

As of early 2026, there's no evidence that Apple has implemented dedicated AWDL radio hardware in Macs. Research presented at [RIPE 91 (October 2025)](https://www.theregister.com/2025/10/23/apple_airdrop_awdl_latency_research/) confirmed that M4 Macs and iPads still exhibit the same channel-hopping behavior that causes latency spikes. iPhones running the same iOS version don't always show the same rhythmic jitter pattern, which suggests possible differences in how the mobile chips handle AWDL, though this hasn't been confirmed as a hardware solution.

The fundamental constraint is that AWDL uses specific "social" WiFi channels (6 for 2.4 GHz, 44 and 149 for 5 GHz). If your network runs on different channels, the radio must hop between channels to listen for AirDrop requests, causing the latency spikes. Until Apple dedicates separate hardware to AWDL or changes how the protocol works, software-level blocking remains the most effective solution.

## Documentation

- [Quick Start](PingWarden/QUICKSTART.md): installation and first-run setup
- [Full Documentation](PingWarden/README.md): architecture, features, and operational details
- [Troubleshooting](PingWarden/TROUBLESHOOTING.md): common issues and recovery steps
- [Release Notes](RELEASE_NOTES.md): version-by-version changelog

## Build From Source

```bash
git clone https://github.com/oliverames/ping-warden.git
cd ping-warden/PingWarden
open PingWarden.xcodeproj
```

Build and run from Xcode with signing configured for all targets. The Foundation-only core helpers also ship as a SwiftPM target. Run `swift test` from the repo root to exercise the 33-test core suite.

## Credits

- [jamestut/awdlkiller](https://github.com/jamestut/awdlkiller) for AWDL monitoring inspiration
- [james-howard/AWDLControl](https://github.com/james-howard/AWDLControl) for the SMAppService and XPC architecture pattern

## License

MIT License. Copyright (c) 2025-2026 Oliver Ames.

---

<p align="center">
  <a href="https://www.buymeacoffee.com/oliverames">
    <img src="https://img.shields.io/badge/Buy_Me_a_Coffee-support-f5a542?style=for-the-badge&logo=buy-me-a-coffee&logoColor=white" alt="Buy Me a Coffee">
  </a>
</p>

<p align="center">
  <sub>
    Built by <a href="https://ames.consulting">Oliver Ames</a> in Vermont
    &bull; <a href="https://github.com/oliverames">GitHub</a>
    &bull; <a href="https://linkedin.com/in/oliverames">LinkedIn</a>
    &bull; <a href="https://bsky.app/profile/oliverames.bsky.social">Bluesky</a>
  </sub>
</p>
