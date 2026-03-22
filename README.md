# Ping Warden

Ping Warden is a macOS app that keeps your connection stable by preventing AWDL-driven latency spikes.

AWDL (Apple Wireless Direct Link) powers AirDrop, AirPlay, and Handoff, but it can introduce sudden ping spikes during cloud gaming, competitive play, and voice/video calls. Ping Warden gives you one-click control over that behavior.

<p align="center">
  <a href="https://github.com/oliverames/ping-warden/releases/latest"><img src="https://img.shields.io/badge/Download-Latest_Release-f5a542?style=flat-square" alt="Download"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-f5a542?style=flat-square" alt="License"></a>
  <a href="https://www.buymeacoffee.com/oliverames"><img src="https://img.shields.io/badge/Buy_Me_a_Coffee-support-f5a542?style=flat-square&logo=buy-me-a-coffee&logoColor=white" alt="Buy Me a Coffee"></a>
</p>

## Download

[Download the latest release](https://github.com/oliverames/ping-warden/releases/latest) (macOS 13.0+)

Developer ID signed, notarized, with Sparkle for automatic updates.

## Why Not Just Run `sudo ifconfig awdl0 down`?

A one-time shell command might seem like a simple fix, but it doesn't actually solve the problem.

**The core issue:** macOS will bring AWDL back up automatically—often within seconds. You might think you could write a script that checks status every few seconds and takes AWDL down whenever it pops back up. This approach still introduces ping spikes during the seconds AWDL spools up. In some cases, it makes things *worse* because AWDL performs a channel scan each time it comes up, causing additional latency. Even reducing the polling interval to 0.5 seconds doesn't truly solve the problem.

**Why Ping Warden is different:** Instead of polling and reacting after AWDL is already up, Ping Warden's helper daemon listens to kernel route/interface events via `AF_ROUTE` sockets. When macOS signals that AWDL is coming up, the helper immediately counters the transition (sub-millisecond response) before the system can initiate its channel scan. This prevents the latency spike from ever occurring, rather than just shortening its duration.

Other benefits over manual approaches:

- **No repeated sudo prompts:** One-time approval during setup, then background operation.
- **Visibility:** Live dashboard shows ping quality, history, jitter, and intervention counts.
- **Safe controls:** Explicit enable/disable with proper lifecycle handling and diagnostics.

## Other Sources of WiFi Latency

### Location Services

macOS Location Services uses WiFi scanning to determine your geographic position. The `locationd` process periodically scans nearby networks, which can cause latency spikes similar to AWDL—especially when apps like Maps query your location.

**Mitigations:**
- Disable Location Services entirely: System Settings → Privacy & Security → Location Services
- Or selectively disable it for apps that don't need it (check System Services at the bottom of the list)

Note: Ping Warden focuses specifically on AWDL because it's the most common and aggressive source of WiFi latency spikes. Location Services scans are typically less frequent but can still contribute to occasional jitter.

### Will Apple Fix This in Hardware?

There's been speculation that Apple's newer in-house WiFi chips might mitigate this issue by using a separate radio for AWDL scanning, similar to how some devices handle background tasks without interrupting the main connection.

**Current status:** As of early 2026, there's no evidence that Apple has implemented dedicated AWDL radio hardware in Macs. Research presented at [RIPE 91 (October 2025)](https://www.theregister.com/2025/10/23/apple_airdrop_awdl_latency_research/) confirmed that M4 Macs and iPads still exhibit the same channel-hopping behavior that causes latency spikes. Interestingly, iPhones running the same iOS version don't always show the same rhythmic jitter pattern, suggesting possible differences in how the mobile chips handle AWDL—but this hasn't been confirmed as a hardware solution.

The fundamental constraint is that AWDL uses specific "social" WiFi channels (6 for 2.4GHz, 44/149 for 5GHz). If your network runs on different channels, the radio must hop between channels to listen for AirDrop requests, causing the latency spikes. Until Apple either dedicates separate hardware to AWDL or changes how the protocol works, software-level blocking remains the most effective solution.

## Quick Start

1. Download from [Releases](https://github.com/oliverames/ping-warden/releases/latest) and drag to `/Applications`
2. Launch and click "Set Up Now"
3. Approve the helper in System Settings when prompted
4. Toggle AWDL blocking from the menu bar icon

For detailed setup instructions, see [Quick Start Guide](AWDLControl/QUICKSTART.md).

## Documentation

- [Quick Start](AWDLControl/QUICKSTART.md) — Installation and first-run setup
- [Full Documentation](AWDLControl/README.md) — Architecture, features, and operational details
- [Troubleshooting](AWDLControl/TROUBLESHOOTING.md) — Common issues and recovery steps
- [Release Notes](RELEASE_NOTES.md)

## Build From Source

```bash
git clone https://github.com/oliverames/ping-warden.git
cd ping-warden/AWDLControl
open AWDLControl.xcodeproj
```

Build and run from Xcode with signing configured for all targets.

## Credits

- [jamestut/awdlkiller](https://github.com/jamestut/awdlkiller) — AWDL monitoring inspiration
- [james-howard/AWDLControl](https://github.com/james-howard/AWDLControl) — SMAppService + XPC architecture inspiration

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
