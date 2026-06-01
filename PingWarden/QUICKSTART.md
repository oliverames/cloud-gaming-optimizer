# Quick Start Guide

## 🚀 Get Started in 3 Steps

### 1️⃣ Install

1. [Download the DMG](https://github.com/oliverames/ping-warden/releases/latest)
2. Open the DMG
3. Drag `Ping Warden.app` to Applications
4. Launch from Applications or Spotlight

---

### 2️⃣ First Launch

1. Click **"Set Up Now"**
2. **Approve** in System Settings → Login Items
3. ✅ Done!

---

### 3️⃣ Use It

Click the antenna icon `📡` in your menu bar to:
- Toggle AWDL blocking
- View status
- Adjust settings

**Icon meanings:**
- `📡` with slash = Blocking (low latency) ✅
- `📡` no slash = Allowing (AirDrop works) 

---

## 🎮 Gaming Setup

For automatic activation during games:

1. Open **Settings** → **Automation**
2. Enable **"Game Mode Auto-Detect"**
3. Grant **Screen Recording** permission
4. Done! It activates automatically when you game

---

## 🎛️ Control Center Setup (Optional)

For quick toggle from Control Center:

1. Settings → Automation → Enable "Control Center Widget"
2. System Settings → Control Center
3. Scroll to "Ping Warden"
4. Add to menu bar or Control Center

Requires macOS 26 or newer and a signed Ping Warden release build.

---

## 📊 Verify It's Working

### Quick Test

1. Enable blocking (menu bar icon should show slash)
2. Settings → Advanced → "Run Test"
3. All tests should **PASS** with <1ms response time

### Real-World Test

**Before:**
```bash
ping -c 10 8.8.8.8
# Check for occasional 100-300ms spikes
```

**After enabling Ping Warden:**
```bash
ping -c 10 8.8.8.8
# Spikes should be gone! Stable <10ms pings
```

---

## 🆘 Need Help?

- 📖 [Full README](README.md)
- 🔧 [Troubleshooting Guide](TROUBLESHOOTING.md)
- 🐛 [Report an Issue](https://github.com/oliverames/ping-warden/issues)

---

## 💡 Pro Tips

1. **Launch at login** - Settings → General → Enable "Launch at Login"
2. **Hide dock icon** - Settings → General → Disable "Show Dock Icon"
3. **Manual toggle** - Useful when a fullscreen app is not marked as a game
4. **Check status** - Menu bar icon shows current state at a glance

---

**That's it! Enjoy lag-free gaming and calls! 🎮📞**
