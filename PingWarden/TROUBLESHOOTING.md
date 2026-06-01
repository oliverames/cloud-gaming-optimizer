# Troubleshooting Guide

This guide covers common issues and their solutions.

## Helper Installation Issues

### ❌ Helper not registering / "Not Set Up" status

**Solution 1: Manual approval**

1. Open System Settings
2. Go to "Login Items & Extensions" (or just "Login Items" on older macOS)
3. Look for "PingWardenHelper" or "Ping Warden" in the list
4. Enable it if it's disabled
5. Restart Ping Warden

**Solution 2: Re-register**

1. Open Ping Warden Settings
2. Go to "Advanced" tab
3. Click "Re-register Helper"
4. Approve in System Settings if prompted

**Solution 3: Clean reinstall**

1. Quit Ping Warden
2. Open Terminal and run:
   ```bash
   # Remove app
   rm -rf "/Applications/Ping Warden.app"
   
   # Remove preferences
   defaults delete com.amesvt.pingwarden.app
   rm -rf ~/Library/Preferences/com.amesvt.pingwarden.app.plist
   rm -rf ~/Library/Group\ Containers/group.com.amesvt.pingwarden.app
   
   # Reinstall
   # (use one of the installation methods from README.md)
   ```

### ❌ "Operation not permitted" when registering helper

**Cause:** This is normal! It means the helper needs approval.

**Solution:**
1. System Settings will automatically open (or click "Open System Settings")
2. Look for "PingWardenHelper" or "Ping Warden"
3. Toggle it ON
4. Close System Settings
5. The app will detect approval automatically

---

## Runtime Issues

### ❌ AWDL blocking not working / Ping still spikes

**Diagnosis:**

1. Check menu bar icon:
   - Should show `📡` with slash when blocking
   - Should show `📡` without slash when allowing

2. Check status in Settings → General:
   - Should show "Blocking AWDL" (green) when enabled

3. Test helper response (Settings → Advanced → "Run Test"):
   - All tests should PASS
   - Response time should be <1ms

**Solutions:**

If tests fail:

1. **Re-register helper** (Settings → Advanced → "Re-register...")
2. **Check Console.app** for errors:
   ```
   - Open Console.app
   - Filter by "awdlcontrol"
   - Look for errors (red messages)
   ```
3. **Verify AWDL interface exists**:
   ```bash
   ifconfig awdl0
   ```
   - If this shows "no such device", your Mac may not have AWDL
   - This is rare but can happen on some Mac models

4. **Check for conflicting software**:
   - VPN software that modifies network interfaces
   - Other AWDL control tools
   - Network monitoring tools

### ❌ High CPU usage

**Normal:** 0% when idle, <0.1% when actively blocking AWDL

**If higher:**

1. Check Game Mode auto-detect:
   - If enabled, it scans for fullscreen apps every 2 seconds
   - Without Screen Recording permission, this may be inefficient
   - Try disabling in Settings → Automation

2. Check for errors in Console.app (filter by "awdlcontrol")

3. Try re-registering helper (Settings → Advanced)

### ❌ App crashes on launch

**Solution:**

1. Check Console.app for crash logs:
   - Look for `Ping Warden` or `PingWardenHelper` crashes
   
2. Try safe mode launch:
   ```bash
   # Reset all preferences
   defaults delete com.amesvt.pingwarden.app
   
   # Relaunch
   open "/Applications/Ping Warden.app"
   ```

3. Check macOS version:
   - Requires macOS 13.0 (Ventura) or later

---

## Feature-Specific Issues

### ❌ Game Mode auto-detect not working

**Requirements:**
- Screen Recording permission granted
- The fullscreen app must declare Apple's game metadata in its Info.plist

**Solutions:**

1. **Grant Screen Recording permission**:
   - System Settings → Privacy & Security → Screen Recording
   - Enable "Ping Warden"
   - Restart Ping Warden

2. **Check if game is detected as a game**:
   - Not all fullscreen apps trigger Game Mode
   - Only apps with a game `LSApplicationCategoryType` or `LSSupportsGameMode = true`
   - Use manual toggle for non-game fullscreen apps

3. **Test with known games**:
   - Try with Steam games
   - Try with Mac App Store games

### ❌ Control Center widget not appearing

**Requirements:**
- macOS 26 or newer
- Signed Ping Warden release build with the widget extension embedded

**Solutions:**

1. Open Settings → Automation
2. Enable "Control Center Widget"
3. Go to System Settings → Control Center
4. Scroll to find "Ping Warden"
5. Add it to Control Center or menu bar

If Settings shows "Unavailable," install a signed release build from the project release page. Local debug builds do not satisfy the Developer ID signing check used before Ping Warden hides the menu bar icon.

---

## Performance Issues

### ❌ Menu bar icon not updating

**Solution:**

1. Toggle monitoring off and on again
2. Quit and restart the app
3. Check if helper is running:
   ```bash
   # Should show PingWardenHelper process
   ps aux | grep PingWardenHelper
   ```

### ❌ Settings window won't open

**Solution:**

1. Try clicking Settings menu item again (wait a few seconds)
2. If still stuck, quit and restart the app
3. Check Console.app for errors

---

## Uninstallation

### Complete removal

1. **Using the app:**
   - Settings → Advanced → "Uninstall..."
   - This unregisters the helper and quits

2. **Manual removal:**
   ```bash
   # Stop and remove helper (if running)
   sudo launchctl remove com.amesvt.pingwarden.helper 2>/dev/null || true
   
   # Remove app
   rm -rf "/Applications/Ping Warden.app"
   
   # Remove preferences
   defaults delete com.amesvt.pingwarden.app
   rm -rf ~/Library/Preferences/com.amesvt.pingwarden.app.plist
   rm -rf ~/Library/Group\ Containers/group.com.amesvt.pingwarden.app
   
   # Remove login item
   # Go to System Settings → Login Items
   # Remove "Ping Warden" if present
   ```

3. **Verify AWDL is restored:**
   ```bash
   ifconfig awdl0
   # Should show "UP" in the flags
   ```

---

## Getting More Help

### Collect diagnostic information

Before reporting an issue, collect this information:

1. **macOS version:**
   ```bash
   sw_vers
   ```

2. **App version:**
   - About Ping Warden → Version number

3. **Helper status:**
   - Settings → General → Status

4. **Console logs:**
   - Open Console.app
   - Filter by "awdlcontrol"
   - Export last 100 lines

5. **AWDL status:**
   ```bash
   ifconfig awdl0
   ```

### Report an issue

Include the above diagnostic information when opening a GitHub issue.

### Quick reference commands

```bash
# Check if app is running
ps aux | grep "Ping Warden"

# Check if helper is running
ps aux | grep PingWardenHelper

# Check AWDL interface status
ifconfig awdl0

# View logs in real-time
log stream --predicate 'subsystem == "com.amesvt.pingwarden.app"' --level debug

# Reset all preferences
defaults delete com.amesvt.pingwarden.app
```

---

## Other Sources of Latency

### Location Services

macOS Location Services uses WiFi scanning to determine geographic position. The `locationd` process periodically scans nearby networks, which can cause latency spikes similar to AWDL.

**To check if Location Services is causing issues:**
```bash
# Watch wifi.log for location-triggered scans
tail -F /var/log/wifi.log
```

**Mitigations:**
1. Disable Location Services entirely: System Settings → Privacy & Security → Location Services
2. Selectively disable for apps that don't need it (check System Services at the bottom of the list)
3. In browsers like Chrome, disable location access: Settings → Privacy and Security → Site Settings → Location

Note: Ping Warden focuses specifically on AWDL because it's the most common and aggressive source of WiFi latency spikes. Location Services scans are typically less frequent but can still contribute to occasional jitter.

---

## Known Limitations

1. **Game Mode detection** - Only works with apps marked as games
2. **Screen Recording permission** - Required for Game Mode detection
3. **Control Center widget** - Requires macOS 26 or newer and a signed release build
4. **macOS 13.0+** - Older macOS versions not supported (SMAppService requirement)
5. **AWDL availability** - Some Mac models may not have AWDL interface
6. **Location Services** - Ping Warden does not currently block Location Services WiFi scans (see above for manual mitigations)

---

**Still having issues?** Open an issue on GitHub with your diagnostic information!
