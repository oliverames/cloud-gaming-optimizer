# Troubleshooting

Start with the checks below. Ping Warden includes its own helper repair, diagnostics snapshot, and removal-preparation flows, so Terminal cleanup should not be the first step.

## Ping Protection says "Not Set Up"

### Check helper approval

1. Open **System Settings > General > Login Items & Extensions**. Older macOS releases may label this page **Login Items**.
2. Find Ping Warden under the background items or extensions section.
3. Turn it on if it is disabled.
4. Quit and reopen Ping Warden.

macOS can report that approval is required as an "Operation not permitted" registration result. This is expected until you approve the helper in System Settings.

### Repair the helper connection

1. Open **Settings > Advanced**.
2. Click **Repair** under Repair Helper Connection.
3. Approve Ping Warden in System Settings if macOS asks.
4. Return to the app and run **Settings > Advanced > Run Test**.

### Reinstall safely

Use the app's removal flow before deleting the application. It stops Ping Protection, restores AWDL, unregisters the helper and Launch at Login, clears Ping Warden's local data, and reveals the app in Finder.

1. Open **Settings > Advanced > Prepare to Remove** and confirm.
2. Move `/Applications/Ping Warden.app` to the Trash in Finder.
3. Download a fresh DMG from the [latest release](https://github.com/oliverames/ping-warden/releases/latest).
4. Drag Ping Warden to Applications and complete setup again.

If the app cannot open far enough to run its uninstall flow, do not delete LaunchDaemon files or shared containers by hand. [Open a bug report](https://github.com/oliverames/ping-warden/issues/new?template=bug_report.md) so the helper can be recovered without leaving AWDL in the wrong state.

## Ping Protection is active, but latency still spikes

Ping Warden addresses AWDL-related interruptions. Internet congestion, a busy router, VPN software, Location Services scans, and the remote service itself can also affect latency.

1. Open the dashboard and confirm that Ping Protection is active.
2. Open **Settings > Advanced** and run the helper test.
3. Check that the AWDL interface exists:

   ```bash
   ifconfig awdl0
   ```

4. Temporarily disable other network-control tools or VPN software, then test again.
5. Compare the dashboard against a target close to the service you are using. A public DNS target may not reflect the path to a game server.

If the helper test fails, re-register the helper. If it passes, export diagnostics and include the approximate time of the spike in the bug report.

## CPU or energy use is higher than expected

Use Activity Monitor's CPU and Energy tabs to confirm that Ping Warden is the process using resources.

1. Close the dashboard and compare usage. Faster dashboard update intervals perform more probes and chart updates.
2. Turn off **Game Mode Auto-Detect** under **Settings > Automation** and compare again.
3. Quit and reopen Ping Warden.
4. Export diagnostics and report the macOS version, app version, selected ping interval, and whether the dashboard was open.

Do not use a fixed CPU percentage as the only test. Activity Monitor readings vary with the Mac, selected interval, open windows, and current network state.

## Game Mode auto-detect does not work

### Check that the game is frontmost

Since 4.1.0, detection works from the frontmost app and needs no permission. Bring the game to the front and wait a few seconds; the menu bar status changes when protection engages. Detection is skipped while the Mac is on Ethernet.

### Optional: Screen Recording access

Screen Recording only adds detection of a fullscreen game sitting behind other windows. To enable it, open **Settings > Automation** and click **Enable Fullscreen Detection…**, or open **System Settings > Privacy & Security > Screen Recording** and turn on access for Ping Warden. Ping Warden reads only window metadata and never records or uploads the screen.

### Check the game

Automatic detection depends on the app metadata used by macOS Game Mode. Some fullscreen apps and games do not declare `LSApplicationCategoryType` or `LSSupportsGameMode`. Use the menu bar toggle when a title is not detected.

## The Control Center widget does not appear

The widget requires [macOS Tahoe 26](https://support.apple.com/en-us/122868) or newer and a signed Ping Warden release build.

1. Install the latest signed release from GitHub rather than a local debug build.
2. Open **Settings > Automation** and turn on **Hide Menu Bar Icon**.
3. Open **System Settings > Control Center**.
4. Find Ping Warden and add it to Control Center or the menu bar.

If the setting says **Unavailable**, confirm the macOS version and reinstall the signed release.

## The menu bar icon or Settings window stops updating

1. Turn Ping Protection off and back on.
2. Quit and reopen Ping Warden.
3. Confirm that the processes are present:

   ```bash
   pgrep -fl 'Ping Warden|PingWardenHelper'
   ```

4. Open **Settings > Advanced**, run the helper test, and export diagnostics if the problem continues.

## The app crashes on launch

1. Confirm that the Mac is running macOS 13 Ventura or newer:

   ```bash
   sw_vers
   ```

2. Open Console and search for the `Ping Warden` and `PingWardenHelper` processes.
3. Look for a Ping Warden crash report under **Crash Reports** in Console.
4. Reinstall the latest signed release. If the app can open Settings first, use **Settings > Advanced > Prepare to Remove** before reinstalling.

Do not clear the app's preferences or shared container before collecting diagnostics. That state can explain the crash and makes the report more useful.

## AirDrop, AirPlay, or Handoff does not work

These features depend on AWDL and are expected to be unavailable while Ping Protection is active.

- Choose **Turn Off Ping Protection** to restore them until you turn protection on again.
- Choose **Pause for 10 Minutes** if you need them briefly.
- If they remain unavailable after protection is off, quit Ping Warden and check the interface:

  ```bash
  ifconfig awdl0
  ```

Report the issue if `awdl0` does not return to an active state.

## Uninstall Ping Warden

1. Open **Settings > Advanced > Prepare to Remove** and confirm.
2. Wait for Ping Warden to quit.
3. Move `/Applications/Ping Warden.app` to the Trash in Finder.
4. Confirm that AWDL has returned:

   ```bash
   ifconfig awdl0
   ```

The built-in flow is important because deleting the app alone does not reliably unregister its privileged helper.

## Collect useful diagnostics

1. Open **Settings > Advanced**.
2. Click **Create Snapshot** under Diagnostics Snapshot.
3. Review the text file before sharing it. It contains app and macOS versions, helper state, relevant settings, an AWDL status snapshot, and only the selected target category. Custom hostnames and IP addresses are redacted.
4. Note the approximate time of the problem and what Ping Warden was doing.
5. Attach the file to a [bug report](https://github.com/oliverames/ping-warden/issues/new?template=bug_report.md).

For a short read-only log sample, run:

```bash
log show --last 15m --predicate 'subsystem == "com.amesvt.pingwarden" OR process == "PingWardenHelper"' --info
```

Do not post unrelated Console output, account names, or network details that are not needed to reproduce the problem.

## Other sources of Wi-Fi latency

Location Services can ask macOS to scan nearby Wi-Fi networks. If the dashboard still shows spikes while Ping Protection is active, compare a test with Location Services disabled under **System Settings > Privacy & Security > Location Services**. You can also disable access for individual apps and system services instead of turning it off globally.

Ping Warden does not block Location Services scans.

## Known limitations

- Ping Warden requires macOS 13 Ventura or newer.
- Ping Protection temporarily disables AWDL-dependent features.
- Game Mode detection requires compatible app metadata; Screen Recording access is optional and only adds fullscreen games behind other windows.
- The Control Center widget requires macOS 26 or newer and a signed release build.
- Ping Warden addresses AWDL-related interruptions, not every source of network latency.
