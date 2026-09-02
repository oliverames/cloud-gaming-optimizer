# Quick start

Ping Protection keeps Apple's AWDL network interface offline. While it is active, AirDrop, AirPlay, Handoff, and other nearby-device features may be unavailable. You can turn protection off at any time or pause it for 10 minutes from the menu bar.

## Install and verify

### 1. Install Ping Warden

1. [Download the latest DMG](https://github.com/oliverames/ping-warden/releases/latest).
2. Open the DMG and drag Ping Warden to Applications.
3. Launch Ping Warden from Applications or Spotlight.

### 2. Approve the helper

1. Click **Set Up and Turn On Protection** in the welcome window.
2. Approve Ping Warden in System Settings when macOS asks.
3. Return to Ping Warden after the approval is complete.

The helper needs one-time approval because changing the AWDL interface requires elevated access.

### 3. Activate your license (prebuilt app)

Ping Protection in the prebuilt app requires a one-time $15 license. Buy it at [Gumroad](https://olivera40.gumroad.com/l/pingwarden), then open **Settings → License** and enter the key. The app verifies once and then works offline for up to 14 days. Existing users who had protection enabled before this release keep protection for a 90-day transition starting on first launch of the licensed build; check the time remaining in **Settings → License**. If you donated through [Buy Me a Coffee](https://www.buymeacoffee.com/oliverames) before this release, email [oliver@ames.consulting](mailto:oliver@ames.consulting) with your receipt and it will be honored as a full license.

### 4. Turn on Ping Protection

Open the menu bar menu and choose **Turn On Ping Protection**. If you haven't activated a license (and you aren't in the transition period), the app will point you to **Settings → License**. The menu bar icon will show that protection is active.

### 5. Verify the connection

Open the dashboard and confirm that Ping Protection is active. Leave it open during a normal game or call to compare live latency, jitter, and probe failures. The intervention count increases whenever macOS tries to reactivate AWDL and Ping Warden blocks it.

For a helper health check, open **Settings > Advanced** and click **Run Test**.

## Automatic protection for games

1. Open **Settings > Automation**.
2. Turn on **Game Mode Auto-Detect**.
3. Grant Screen Recording access when macOS asks, then restart Ping Warden if prompted.

Ping Warden turns protection on for recognized fullscreen games and restores your previous state when the game closes. Some games do not declare the metadata that macOS uses for Game Mode; use the menu bar toggle for those titles.

## Control Center widget

The Control Center widget requires [macOS Tahoe 26](https://support.apple.com/en-us/122868) or newer and a signed release build.

1. Open **Settings > Automation** and turn on **Hide Menu Bar Icon**.
2. Open **System Settings > Control Center**.
3. Find Ping Warden and add it to Control Center or the menu bar.

## Everyday controls

- Choose **Pause for 10 Minutes** when you need AirDrop, AirPlay, or Handoff briefly.
- Start a **Latency Session** from the dashboard when you want a beginning-to-end recap for one game or call.
- Turn on **Launch at Login** under **Settings > General** if you want protection available after every restart.
- Use **Settings > Advanced > Diagnostics Snapshot** to create a local troubleshooting file you can review before sharing.

## Get help

- Read the [Troubleshooting guide](TROUBLESHOOTING.md).
- Read the [full documentation](README.md).
- [Report a bug](https://github.com/oliverames/ping-warden/issues/new?template=bug_report.md) with the exported diagnostics attached after you review it.
