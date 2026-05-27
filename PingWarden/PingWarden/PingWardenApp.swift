//
//  PingWardenApp.swift
//  PingWarden
//
//  Main application entry point and UI for Ping Warden.
//
//  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
//  Licensed under the MIT License.
//

import SwiftUI
import ServiceManagement
import os.log
import Sparkle

private let log = Logger(subsystem: "com.amesvt.pingwarden", category: "App")

// MARK: - Backward Compatible onChange

extension View {
    /// Backward-compatible onChange modifier that works on macOS 13 and later
    /// Uses the new two-parameter closure on macOS 14+, falls back to old API on macOS 13
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            self.onChange(of: value) { newValue in
                action(newValue)
            }
        }
    }
}

@main
struct PingWardenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, SPUUpdaterDelegate {
    private static let appMenuCheckForUpdatesTag = 2201
    // Sparkle feed URL is defined in Info.plist (SUFeedURL) as the single source of truth.

    private struct GameModeSnapshot {
        let userIntentMonitoringEnabled: Bool
        let wasMonitoringActive: Bool
        let quickPauseUntil: Date?
        let quickPauseRestoreState: Bool?
    }

    private var updaterController: SPUStandardUpdaterController?
    private var updaterStartupError: Error?
    
    private var monitoringObserver: NSObjectProtocol?
    private var controlCenterObserver: NSObjectProtocol?
    private var dockIconObserver: NSObjectProtocol?
    private var gameModeObserver: NSObjectProtocol?
    private var menuMetricsObserver: NSObjectProtocol?
    private var windowObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var aboutWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var donationWindow: NSWindow?
    private var gameModeDetector: GameModeDetector?
    private var monitorStateObserverToken: UUID?
    private var gameModeSnapshot: GameModeSnapshot?
    private var quickPauseRestoreState: Bool?
    private var quickPauseTimer: Timer?
    private var quickPauseUntil: Date?
    private var lastToggleTime: Date = .distantPast
    private var menuMetricsPingMonitor: PingMonitor?
    private var menuMetricsTimer: Timer?
    private var menuCurrentPingMs: Double?
    private var menuInterventionCount: Int?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("Ping Warden launching...")

        // Anonymous crash reporting (Sentry). Defaults on but stays limited to
        // crashes only; the Settings privacy toggle is checked before startup.
        CrashReporter.startIfEnabled()

        // Clear any cached Settings window state from prior builds that may have
        // injected fullSizeContentView or other window customizations via onAppear.
        // The SwiftUI Settings scene persists window frames under these keys.
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            if key.contains("NSWindow Frame") && key.contains("Settings") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // Initialize monitoring before Sparkle so first-run UX can be gated on setup state.
        let monitor = PingWardenMonitor.shared

        // Initialize Sparkle updater and start explicitly so failures can be logged clearly.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        updaterController?.updater.clearFeedURLFromUserDefaults()
        if monitor.isHelperRegistered {
            _ = startUpdaterIfNeeded()
        } else {
            log.info("Deferring Sparkle updater start during first-run setup")
        }

        // Check for quarantine issues and help user if needed
        QuarantineHelper.showQuarantineHelpIfNeeded()

        // Set dock icon visibility based on preference
        updateDockIconVisibility()

        // Observe monitor state changes
        monitorStateObserverToken = monitor.addStateObserver { [weak self] in
            self?.updateMenuBarIcon()
            self?.updateMenuItem()
        }

        // Setup menu bar (unless Control Center mode is enabled AND widget is available)
        // Always check if widget is actually available before hiding menu bar
        let widgetAvailable = ControlCenterSupport.isAvailableForCurrentApp()
        if PingWardenPreferences.shared.controlCenterWidgetEnabled && !widgetAvailable {
            log.warning("Control Center widget enabled but not available (requires code signing). Resetting to menu bar.")
            PingWardenPreferences.shared.controlCenterWidgetEnabled = false
        }
        if !PingWardenPreferences.shared.controlCenterWidgetEnabled || !widgetAvailable {
            setupMenuBar()
        }

        // Check if this is first launch (helper not registered)
        if !monitor.isHelperRegistered {
            log.info("First launch detected - helper not registered")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showWelcomeWindow()
            }
        } else {
            log.info("Helper already registered")
            if PingWardenPreferences.shared.isMonitoringEnabled && !monitor.isMonitoringActive {
                monitor.startMonitoring()
            }
            // Only consider the donation prompt once setup is finished. Brand
            // new users see the welcome flow on their first launch and the
            // donation ask on the next one — asking before they've used the
            // app would feel like a paywall.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.showDonationPromptIfNeeded()
            }
        }

        // Setup Game Mode detector if enabled
        if PingWardenPreferences.shared.gameModeAutoDetect {
            setupGameModeDetector()
        }

        // Observe preference changes from widget (uses distributed notifications for cross-process)
        monitoringObserver = DistributedNotificationCenter.default().addObserver(
            forName: .awdlMonitoringStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMonitoringStateChange()
        }

        // Observe Control Center mode changes
        controlCenterObserver = NotificationCenter.default.addObserver(
            forName: .controlCenterModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleControlCenterModeChange()
        }

        // Observe dock icon visibility changes
        dockIconObserver = NotificationCenter.default.addObserver(
            forName: .dockIconVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateDockIconVisibility()
        }

        // Observe Game Mode auto-detect changes
        gameModeObserver = NotificationCenter.default.addObserver(
            forName: .gameModeAutoDetectChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleGameModeAutoDetectChange()
        }

        menuMetricsObserver = NotificationCenter.default.addObserver(
            forName: .menuDropdownMetricsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMenuMetricsPreferenceChange()
        }

        handleMenuMetricsPreferenceChange()
        ensureApplicationMenuItems()

        // Observe all window close events so we can update dock icon visibility
        // when the Settings scene window (which we don't own) closes.
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateDockIconVisibility()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Safety net for issue #28: when the menu bar icon is hidden (Control Center mode)
        // and the dock icon is off, re-launching the app is the only way back in.
        // Always open Settings when the app is re-opened with no visible windows.
        if !flag {
            openSettings()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ensureApplicationMenuItems()
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info("Ping Warden terminating...")

        gameModeDetector?.stop()
        quickPauseTimer?.invalidate()
        quickPauseTimer = nil

        if PingWardenMonitor.shared.isMonitoringActive {
            PingWardenMonitor.shared.stopMonitoring()
        }

        if let token = monitorStateObserverToken {
            PingWardenMonitor.shared.removeStateObserver(token)
            monitorStateObserverToken = nil
        }

        if let observer = monitoringObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let observer = controlCenterObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = dockIconObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = gameModeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = menuMetricsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        menuMetricsTimer?.invalidate()
        menuMetricsTimer = nil
        menuMetricsPingMonitor?.stop()
        menuMetricsPingMonitor = nil
    }

    private func updateDockIconVisibility() {
        // The Settings window is owned by the SwiftUI Settings scene. Its title may be
        // "Settings" or the current section name (from .navigationTitle), so we check
        // for any visible titled window that isn't one of our other managed windows.
        let settingsVisible = NSApp.windows.contains { window in
            window.isVisible
                && window !== aboutWindow
                && window !== welcomeWindow
                && window !== donationWindow
                && window.styleMask.contains(.titled)
                && window.level == .normal
                && !(window.className.contains("StatusBar"))
        }
        let aboutVisible = aboutWindow?.isVisible ?? false
        let welcomeVisible = welcomeWindow?.isVisible ?? false
        let donationVisible = donationWindow?.isVisible ?? false

        if PingWardenPreferences.shared.showDockIcon || settingsVisible || aboutVisible || welcomeVisible || donationVisible {
            NSApp.setActivationPolicy(.regular)
            ensureApplicationMenuItems()
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        // Update dock icon visibility when a managed window closes.
        // The Settings window is handled by the global windowObserver.
        if window === aboutWindow || window === welcomeWindow || window === donationWindow {
            if window === donationWindow {
                // The user closed the prompt via the window control rather
                // than a button. Treat it as "Maybe later" so we don't
                // re-prompt within this minor version.
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                if !currentVersion.isEmpty {
                    PingWardenPreferences.shared.donationPromptLastSeenVersion = currentVersion
                }
                donationWindow = nil
            }
            DispatchQueue.main.async { [weak self] in
                self?.updateDockIconVisibility()
            }
        }
    }

    private func setupGameModeDetector() {
        gameModeDetector = GameModeDetector()
        gameModeDetector?.onGameModeChange = { [weak self] isActive in
            self?.handleGameModeStateChange(isActive: isActive)
        }
        gameModeDetector?.start()
        log.info("Game Mode detector started")
    }

    private func handleGameModeAutoDetectChange() {
        if PingWardenPreferences.shared.gameModeAutoDetect {
            // Stop existing detector first to prevent duplicates
            gameModeDetector?.stop()
            setupGameModeDetector()
        } else {
            gameModeDetector?.stop()
            gameModeDetector = nil
            log.info("Game Mode detector stopped")
        }
    }

    private func handleGameModeStateChange(isActive: Bool) {
        log.info("Game Mode state changed: \(isActive)")
        if isActive {
            if gameModeSnapshot == nil {
                gameModeSnapshot = GameModeSnapshot(
                    userIntentMonitoringEnabled: PingWardenPreferences.shared.isMonitoringEnabled,
                    wasMonitoringActive: PingWardenMonitor.shared.isMonitoringActive,
                    quickPauseUntil: quickPauseUntil,
                    quickPauseRestoreState: quickPauseRestoreState
                )
            }

            // Preserve paused state metadata while forcing protection on.
            if quickPauseUntil != nil {
                quickPauseTimer?.invalidate()
                quickPauseTimer = nil
            }

            if !PingWardenMonitor.shared.isMonitoringActive {
                log.info("Game Mode active - enabling AWDL blocking")
                PingWardenMonitor.shared.startMonitoring(persistUserPreference: false)
            }
        } else {
            let snapshot = gameModeSnapshot ?? GameModeSnapshot(
                userIntentMonitoringEnabled: PingWardenPreferences.shared.isMonitoringEnabled,
                wasMonitoringActive: PingWardenMonitor.shared.isMonitoringActive,
                quickPauseUntil: quickPauseUntil,
                quickPauseRestoreState: quickPauseRestoreState
            )
            gameModeSnapshot = nil

            if let pauseUntil = snapshot.quickPauseUntil, pauseUntil > Date() {
                log.info("Game Mode inactive - restoring paused state")
                quickPauseUntil = pauseUntil
                quickPauseRestoreState = snapshot.quickPauseRestoreState ?? snapshot.userIntentMonitoringEnabled
                PingWardenMonitor.shared.stopMonitoring(persistUserPreference: false)
                scheduleQuickPauseTimer()
                updateMenuItem()
                return
            } else {
                clearQuickPauseState()
            }

            if snapshot.wasMonitoringActive && !PingWardenMonitor.shared.isMonitoringActive {
                log.info("Game Mode inactive - restoring AWDL blocking state to enabled")
                PingWardenMonitor.shared.startMonitoring(persistUserPreference: false)
            } else if !snapshot.wasMonitoringActive && PingWardenMonitor.shared.isMonitoringActive {
                log.info("Game Mode inactive - restoring AWDL blocking state to disabled")
                PingWardenMonitor.shared.stopMonitoring(persistUserPreference: false)
            }
        }
    }

    // MARK: - Welcome Window

    private func showWelcomeWindow() {
        if welcomeWindow != nil { return }

        let welcomeView = WelcomeView {
            self.welcomeWindow?.close()
            self.welcomeWindow = nil
            self.updateDockIconVisibility()
            PingWardenMonitor.shared.installAndStartMonitoring()
        } onDismiss: {
            self.welcomeWindow?.close()
            self.welcomeWindow = nil
            self.updateDockIconVisibility()
        }

        let hostingController = NSHostingController(rootView: welcomeView)
        let window = NSWindow(contentViewController: hostingController)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        welcomeWindow = window

        // Show dock icon when welcome window opens
        NSApp.setActivationPolicy(.regular)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ensureApplicationMenuItems()
    }

    // MARK: - Donation Prompt

    private func showDonationPromptIfNeeded() {
        guard donationWindow == nil else { return }

        let prefs = PingWardenPreferences.shared
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

        guard VersionPromptPolicy.shouldPrompt(
            currentVersion: currentVersion,
            lastSeenVersion: prefs.donationPromptLastSeenVersion,
            dismissedPermanently: prefs.donationPromptDismissedPermanently
        ) else {
            return
        }

        log.info("Showing donation prompt for v\(currentVersion, privacy: .public)")

        let view = DonationPromptView(
            onSupport: { [weak self] in
                NSWorkspace.shared.open(DonationPromptView.donationURL)
                prefs.donationPromptLastSeenVersion = currentVersion
                self?.closeDonationWindow()
            },
            onMaybeLater: { [weak self] in
                prefs.donationPromptLastSeenVersion = currentVersion
                self?.closeDonationWindow()
            },
            onDontAskAgain: { [weak self] in
                prefs.donationPromptLastSeenVersion = currentVersion
                prefs.donationPromptDismissedPermanently = true
                self?.closeDonationWindow()
            }
        )

        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        donationWindow = window

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ensureApplicationMenuItems()
    }

    private func closeDonationWindow() {
        donationWindow?.close()
        donationWindow = nil
        updateDockIconVisibility()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        log.debug("Setting up menu bar")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard statusItem?.button != nil else {
            log.error("Failed to create status item button")
            return
        }

        updateMenuBarIcon()
        statusMenu = NSMenu()
        statusMenu?.delegate = self

        // Toggle item
        let toggleItem = NSMenuItem(
            title: PingWardenMonitor.shared.isMonitoringActive ? "Disable Ping Protection" : "Enable Ping Protection",
            action: #selector(toggleMonitoring),
            keyEquivalent: ""
        )
        toggleItem.target = self
        statusMenu?.addItem(toggleItem)

        let pauseItem = NSMenuItem(
            title: "Pause Blocking (10 Minutes)",
            action: #selector(pauseMonitoringForTenMinutes),
            keyEquivalent: ""
        )
        pauseItem.target = self
        pauseItem.tag = 150
        statusMenu?.addItem(pauseItem)

        let resumeItem = NSMenuItem(
            title: "Resume Blocking",
            action: #selector(resumeMonitoringAfterQuickPause),
            keyEquivalent: ""
        )
        resumeItem.target = self
        resumeItem.tag = 151
        statusMenu?.addItem(resumeItem)

        statusMenu?.addItem(NSMenuItem.separator())

        // Status item
        let statusMenuItem = NSMenuItem(title: "Status: Checking...", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        statusMenu?.addItem(statusMenuItem)

        let pingMenuItem = NSMenuItem(title: "Current Ping: --", action: nil, keyEquivalent: "")
        pingMenuItem.tag = 101
        pingMenuItem.isEnabled = false
        statusMenu?.addItem(pingMenuItem)

        let interventionsMenuItem = NSMenuItem(title: "Lag Spikes Blocked: --", action: nil, keyEquivalent: "")
        interventionsMenuItem.tag = 102
        interventionsMenuItem.isEnabled = false
        statusMenu?.addItem(interventionsMenuItem)

        let showMetricsItem = NSMenuItem(
            title: "Show Live Metrics in Menu",
            action: #selector(toggleMenuDropdownMetrics),
            keyEquivalent: ""
        )
        showMetricsItem.tag = 160
        showMetricsItem.target = self
        statusMenu?.addItem(showMetricsItem)

        updateStatusMenuItem()
        updateMenuMetricsMenuItems()
        updateQuickActionMenuItems()
        handleMenuMetricsPreferenceChange()

        statusMenu?.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        statusMenu?.addItem(settingsItem)

        // Check for Updates (Sparkle)
        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = self
        statusMenu?.addItem(updateItem)

        // About
        let aboutItem = NSMenuItem(
            title: "About Ping Warden",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        statusMenu?.addItem(aboutItem)

        statusMenu?.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Ping Warden",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusMenu?.addItem(quitItem)

        self.statusItem?.menu = statusMenu
    }

    private func removeMenuBar() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            statusMenu = nil
        }
        stopMenuMetricsMonitoring()
    }

    @objc private func openSettings() {
        log.info("openSettings called")
        NSApp.setActivationPolicy(.regular)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
        ensureApplicationMenuItems()
    }

    @objc private func showAbout() {
        if let window = aboutWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            ensureApplicationMenuItems()
            return
        }

        let aboutView = AboutView()
        let hostingController = NSHostingController(rootView: aboutView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "About Ping Warden"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.backgroundColor = .clear
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        aboutWindow = window
        
        // Show dock icon when about window opens
        NSApp.setActivationPolicy(.regular)
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ensureApplicationMenuItems()
    }

    @objc private func checkForUpdates() {
        guard startUpdaterIfNeeded() else {
            presentUpdaterStartFailureAlert()
            return
        }

        if let activeFeedURL = updaterController?.updater.feedURL?.absoluteString {
            log.info("Checking Sparkle updates from feed: \(activeFeedURL, privacy: .public)")
        }
        
        updaterController?.updater.checkForUpdates()
    }

    private func startUpdaterIfNeeded() -> Bool {
        guard let updater = updaterController?.updater else {
            return false
        }
        
        do {
            try updater.start()
            updaterStartupError = nil
            return true
        } catch {
            updaterStartupError = error
            log.error("Sparkle updater failed to start: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func ensureApplicationMenuItems() {
        guard NSApp.activationPolicy() == .regular,
              let mainMenu = NSApp.mainMenu,
              let appMenu = mainMenu.items.first?.submenu else {
            return
        }

        if let existingItem = appMenu.items.first(where: { $0.title == "Check for Updates..." }) {
            existingItem.target = self
            existingItem.action = #selector(checkForUpdates)
            existingItem.tag = Self.appMenuCheckForUpdatesTag
            return
        }

        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = self
        updateItem.tag = Self.appMenuCheckForUpdatesTag

        if let settingsIndex = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," || $0.title == "Settings..." }) {
            appMenu.insertItem(updateItem, at: settingsIndex + 1)
        } else if let aboutIndex = appMenu.items.firstIndex(where: { $0.title.hasPrefix("About ") }) {
            appMenu.insertItem(updateItem, at: aboutIndex + 1)
        } else {
            appMenu.insertItem(updateItem, at: min(1, appMenu.items.count))
        }
    }

    private func presentUpdaterStartFailureAlert() {
        let alert = NSAlert()
        alert.messageText = "Unable to Check For Updates"
        
        if let startupError = updaterStartupError as NSError? {
            alert.informativeText = "The updater failed to start.\n\n\(startupError.localizedDescription)\n\nCheck Console logs for details."
        } else {
            alert.informativeText = "The updater failed to start. Check Console logs for details."
        }
        
        alert.alertStyle = .warning
        alert.runModal()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        log.error("Sparkle update cycle aborted: [\(nsError.domain, privacy: .public):\(nsError.code)] \(nsError.localizedDescription, privacy: .public)")
    }
    
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error {
            let nsError = error as NSError
            log.error("Sparkle update cycle finished with error for \(String(describing: updateCheck), privacy: .public): [\(nsError.domain, privacy: .public):\(nsError.code)] \(nsError.localizedDescription, privacy: .public)")
        } else {
            log.info("Sparkle update cycle finished successfully for \(String(describing: updateCheck), privacy: .public)")
        }
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }

        let isMonitoring = PingWardenMonitor.shared.isMonitoringActive
        let symbolName = isMonitoring ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right"
        let accessibilityDesc = isMonitoring ? "Ping Warden: Protected" : "Ping Warden: Not Protected"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDesc)
        image?.isTemplate = true

        button.image = image
        button.toolTip = isMonitoring ? "Ping Protection: Active" : "Ping Protection: Inactive"

        // Accessibility for VoiceOver
        button.setAccessibilityLabel(accessibilityDesc)
        button.setAccessibilityRole(.button)
    }

    private func updateMenuItem() {
        guard let menu = statusMenu else { return }

        let newTitle = PingWardenMonitor.shared.isMonitoringActive ? "Disable Ping Protection" : "Enable Ping Protection"
        menu.items.first?.title = newTitle

        updateStatusMenuItem()
        updateMenuMetricsMenuItems()
        updateQuickActionMenuItems()
    }

    private func updateMenuMetricsMenuItems() {
        guard let menu = statusMenu else { return }

        let showMetrics = PingWardenPreferences.shared.showMenuDropdownMetrics

        if let toggleItem = menu.items.first(where: { $0.tag == 160 }) {
            toggleItem.state = showMetrics ? .on : .off
        }

        if let pingItem = menu.items.first(where: { $0.tag == 101 }) {
            pingItem.isHidden = !showMetrics
            if let ping = menuCurrentPingMs {
                pingItem.title = String(format: "Current Ping: %.0f ms", ping)
            } else {
                pingItem.title = "Current Ping: --"
            }
        }

        if let interventionsItem = menu.items.first(where: { $0.tag == 102 }) {
            interventionsItem.isHidden = !showMetrics
            if let count = menuInterventionCount {
                interventionsItem.title = "Lag Spikes Blocked: \(count)"
            } else {
                interventionsItem.title = "Lag Spikes Blocked: --"
            }
        }
    }

    private func updateQuickActionMenuItems() {
        guard let menu = statusMenu else { return }

        let isMonitoring = PingWardenMonitor.shared.isMonitoringActive
        if let pauseItem = menu.items.first(where: { $0.tag == 150 }) {
            if let pauseUntil = quickPauseUntil, pauseUntil > Date() {
                let remaining = max(1, Int((pauseUntil.timeIntervalSinceNow / 60.0).rounded(.up)))
                pauseItem.title = "Paused (\(remaining)m left)"
            } else {
                pauseItem.title = "Pause Blocking (10 Minutes)"
            }
            pauseItem.isEnabled = isMonitoring
        }

        if let resumeItem = menu.items.first(where: { $0.tag == 151 }) {
            resumeItem.isEnabled = quickPauseUntil != nil && !isMonitoring
        }
    }

    private func updateStatusMenuItem() {
        guard let menu = statusMenu,
              let statusItem = menu.items.first(where: { $0.tag == 100 }) else { return }

        let isMonitoring = PingWardenMonitor.shared.isMonitoringActive
        let installed = PingWardenMonitor.shared.isHelperRegistered

        if !installed {
            statusItem.title = "Status: Not Set Up"
        } else if isMonitoring {
            statusItem.title = "Status: Protected"
        } else {
            statusItem.title = "Status: Not Protected"
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        syncMenuMetricsTargetIfNeeded()
        updateMenuItem()
        refreshMenuInterventionCount()
    }

    @objc private func toggleMonitoring() {
        // Debounce rapid toggles to prevent race conditions
        let now = Date()
        guard now.timeIntervalSince(lastToggleTime) > 0.5 else {
            log.debug("Toggle debounced - too soon since last toggle")
            return
        }
        lastToggleTime = now

        clearQuickPauseState()

        if PingWardenMonitor.shared.isMonitoringActive {
            PingWardenMonitor.shared.stopMonitoring()
        } else {
            PingWardenMonitor.shared.startMonitoring()
        }
    }

    @objc private func toggleMenuDropdownMetrics() {
        PingWardenPreferences.shared.showMenuDropdownMetrics.toggle()
    }

    @objc private func pauseMonitoringForTenMinutes() {
        guard PingWardenMonitor.shared.isMonitoringActive else { return }

        quickPauseRestoreState = PingWardenPreferences.shared.isMonitoringEnabled
        quickPauseUntil = Date().addingTimeInterval(10 * 60)
        PingWardenMonitor.shared.stopMonitoring(persistUserPreference: false)
        scheduleQuickPauseTimer()
        updateMenuItem()
    }

    @objc private func resumeMonitoringAfterQuickPause() {
        let shouldRestore = quickPauseRestoreState ?? PingWardenPreferences.shared.isMonitoringEnabled
        clearQuickPauseState()

        if shouldRestore && !PingWardenMonitor.shared.isMonitoringActive {
            PingWardenMonitor.shared.startMonitoring(persistUserPreference: false)
        }
        updateMenuItem()
    }

    private func scheduleQuickPauseTimer() {
        quickPauseTimer?.invalidate()
        guard let pauseUntil = quickPauseUntil else { return }

        quickPauseTimer = Timer.scheduledTimer(withTimeInterval: max(0, pauseUntil.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            self?.resumeMonitoringAfterQuickPause()
        }
    }

    private func clearQuickPauseState() {
        quickPauseTimer?.invalidate()
        quickPauseTimer = nil
        quickPauseUntil = nil
        quickPauseRestoreState = nil
    }

    private func handleMenuMetricsPreferenceChange() {
        guard statusItem != nil else {
            stopMenuMetricsMonitoring()
            return
        }

        if PingWardenPreferences.shared.showMenuDropdownMetrics {
            startMenuMetricsMonitoring()
        } else {
            stopMenuMetricsMonitoring()
        }
        updateMenuMetricsMenuItems()
    }

    private func startMenuMetricsMonitoring() {
        let target = menuMetricsTarget()

        if let monitor = menuMetricsPingMonitor {
            if monitor.server != target.host || monitor.port != target.port || !monitor.isMonitoring {
                monitor.stop()
                monitor.start(server: target.host, port: target.port, interval: 2)
            }
        } else {
            let monitor = PingMonitor()
            monitor.onPingResult = { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.menuCurrentPingMs = result.success ? result.latencyMs : nil
                    self.updateMenuMetricsMenuItems()
                }
            }
            menuMetricsPingMonitor = monitor
            monitor.start(server: target.host, port: target.port, interval: 2)
        }

        refreshMenuInterventionCount()

        if menuMetricsTimer == nil {
            menuMetricsTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.syncMenuMetricsTargetIfNeeded()
                self?.refreshMenuInterventionCount()
            }
            if let menuMetricsTimer {
                RunLoop.main.add(menuMetricsTimer, forMode: .common)
            }
        }
    }

    private func stopMenuMetricsMonitoring() {
        menuMetricsTimer?.invalidate()
        menuMetricsTimer = nil
        menuMetricsPingMonitor?.stop()
        menuMetricsPingMonitor = nil
        menuCurrentPingMs = nil
        menuInterventionCount = nil
    }

    private func syncMenuMetricsTargetIfNeeded() {
        guard PingWardenPreferences.shared.showMenuDropdownMetrics,
              let monitor = menuMetricsPingMonitor else { return }

        let target = menuMetricsTarget()
        guard monitor.server != target.host || monitor.port != target.port else { return }

        menuCurrentPingMs = nil
        monitor.stop()
        monitor.start(server: target.host, port: target.port, interval: 2)
    }

    private func refreshMenuInterventionCount() {
        guard PingWardenPreferences.shared.showMenuDropdownMetrics else { return }

        PingWardenMonitor.shared.getInterventionCount { [weak self] count in
            DispatchQueue.main.async {
                guard let self else { return }
                self.menuInterventionCount = count
                self.updateMenuMetricsMenuItems()
            }
        }
    }

    private func menuMetricsTarget() -> (host: String, port: UInt16) {
        let defaultTarget = ("8.8.8.8", UInt16(53))
        guard let rawTargetID = UserDefaults.standard.string(forKey: "DashboardSelectedPingTargetID"),
              let separatorIndex = rawTargetID.lastIndex(of: ":") else {
            return defaultTarget
        }

        let hostPart = String(rawTargetID[..<separatorIndex])
        let portPart = String(rawTargetID[rawTargetID.index(after: separatorIndex)...])
        guard !hostPart.isEmpty, let port = UInt16(portPart) else {
            return defaultTarget
        }

        return (hostPart, port)
    }

    private func handleMonitoringStateChange() {
        let shouldMonitor = PingWardenPreferences.shared.isMonitoringEnabled
        let isMonitoring = PingWardenMonitor.shared.isMonitoringActive

        if shouldMonitor && !isMonitoring {
            PingWardenMonitor.shared.startMonitoring()
        } else if !shouldMonitor && isMonitoring {
            PingWardenMonitor.shared.stopMonitoring()
        }

        updateMenuBarIcon()
        updateMenuItem()
    }

    private func handleControlCenterModeChange() {
        // Control Center widgets require proper code signing to work
        // For unsigned/ad-hoc signed apps, always keep menu bar visible
        let isProperlySignedForControlCenter = ControlCenterSupport.isAvailableForCurrentApp()

        if PingWardenPreferences.shared.controlCenterWidgetEnabled && isProperlySignedForControlCenter {
            // Safety invariant (H2): never remove the menu bar if the dock icon is also hidden,
            // as this would leave the user with no way to access the app.
            if !PingWardenPreferences.shared.showDockIcon {
                log.info("Control Center mode enabled — forcing dock icon on to prevent lockout")
                PingWardenPreferences.shared.showDockIcon = true
            }
            removeMenuBar()
        } else {
            // Reset preference if widget isn't available
            if PingWardenPreferences.shared.controlCenterWidgetEnabled && !isProperlySignedForControlCenter {
                log.warning("Control Center widget not available (requires code signing). Reverting to menu bar.")
                PingWardenPreferences.shared.controlCenterWidgetEnabled = false
            }
            if statusItem == nil {
                setupMenuBar()
            }
        }
    }

}

// MARK: - Welcome View

struct WelcomeView: View {
    let onSetup: () -> Void
    let onDismiss: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                Group {
                    if #available(macOS 14.0, *) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: heroIconSize, weight: .thin))
                            .foregroundStyle(.tint)
                            .symbolEffect(.pulse, options: .repeating)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: heroIconSize, weight: .thin))
                            .foregroundStyle(.tint)
                    }
                }
                .accessibilityHidden(true)

                Text("Welcome to Ping Warden")
                    .font(.largeTitle)
                    .fontWeight(.bold)
            }
            .padding(.top, 40)
            .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(
                    icon: "bolt.fill",
                    title: "Eliminate Latency Spikes",
                    description: "Blocks Apple's background wireless services (AirDrop, etc.) from causing 100-300ms lag spikes"
                )

                FeatureRow(
                    icon: "gamecontroller.fill",
                    title: "Perfect for Gaming",
                    description: "Keep your connection stable during competitive play"
                )

                FeatureRow(
                    icon: "cpu",
                    title: "Zero Performance Impact",
                    description: "<1ms response time, 0% CPU when idle"
                )
            }
            .padding(.horizontal, 32)

            Spacer()

            HStack(spacing: 12) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.secondary)

                Text("Setup requires a one-time system approval in System Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 32)

            HStack(spacing: 12) {
                Button("Later") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Set Up Now") {
                    onSetup()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        .frame(width: 480, height: 520)
        .background(.regularMaterial)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            SettingsContentView(section: selectedSection)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .frame(minWidth: 600, minHeight: 450)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard let window = NSApp.windows.first(where: {
                    $0.title.contains("Settings")
                }) else { return }

                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
                window.toolbarStyle = .unified
                window.styleMask.remove(.fullSizeContentView)
                if window.toolbar == nil {
                    let toolbar = NSToolbar(identifier: "SettingsToolbar")
                    toolbar.displayMode = .iconOnly
                    window.toolbar = toolbar
                }
                window.toolbar?.showsBaselineSeparator = true
            }
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case general = "General"
    case automation = "Automation"
    case advanced = "Advanced"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "chart.xyaxis.line"
        case .general: return "gearshape"
        case .automation: return "sparkles"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

struct SettingsContentView: View {
    let section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.rawValue)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 6)

            Divider()
                .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch section {
                    case .dashboard:
                        DashboardSettingsContent()
                    case .general:
                        GeneralSettingsContent()
                    case .automation:
                        AutomationSettingsContent()
                    case .advanced:
                        AdvancedSettingsContent()
                    }
                }
                .padding(.top, 8)

                Spacer(minLength: 20)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // No explicit .background here: on macOS 26 the Settings scene
        // already renders with the system Liquid Glass material, and an
        // opaque windowBackgroundColor on top would obscure it. On
        // macOS 13-25 the inherited scene background continues to look
        // correct without us setting one explicitly.
    }
}

// MARK: - Settings Components

private let settingsLog = Logger(subsystem: "com.amesvt.pingwarden", category: "Settings")

struct SettingsGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Use system material (translucent on macOS 13+, Liquid Glass on
        // macOS 26+) instead of an opaque unemphasizedSelectedContent fill.
        // Single line cascades through every SettingsGroup that General
        // and Automation still use until those views migrate to Form/Section.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 20)
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    let description: String?
    let content: Content

    init(_ title: String, description: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        let accessibilityText = if let description {
            "\(title), \(description)"
        } else {
            title
        }
        
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if let description = description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 12)
    }
}

struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }
}

/// Small pill badge ("Beta", "Unavailable", etc.) with WCAG AA contrast.
/// White text on a darker-tinted fill passes >=4.5:1 in both light and dark
/// mode without depending on the parent background. Replaces the previous
/// `.opacity(0.2)` pattern which scored 1.71:1 in light mode (text was nearly
/// invisible to low-vision users).
struct StatusBadge: View {
    enum Tint {
        case beta
        case unavailable
    }

    let text: String
    let tint: Tint

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(fillColor, in: Capsule())
            .accessibilityLabel(voiceOverLabel)
    }

    private var fillColor: Color {
        switch tint {
        case .beta: return Color(red: 0.65, green: 0.35, blue: 0.0)
        case .unavailable: return Color(red: 0.40, green: 0.40, blue: 0.40)
        }
    }

    private var voiceOverLabel: String {
        switch tint {
        case .beta: return "\(text) — beta feature"
        case .unavailable: return "\(text)"
        }
    }
}

// MARK: - General Settings Content

struct GeneralSettingsContent: View {
    @StateObject private var monitorState = MonitoringStateStore()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showDockIcon = PingWardenPreferences.shared.showDockIcon
    @State private var showMenuDropdownMetrics = PingWardenPreferences.shared.showMenuDropdownMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // AWDL Status Group
            SettingsGroup {
                SettingsRow("Ping Protection", description: "Block wireless interference that causes lag spikes") {
                    Toggle("", isOn: Binding(
                        get: { monitorState.isMonitoring },
                        set: { newValue in
                            if newValue {
                                PingWardenMonitor.shared.startMonitoring()
                            } else {
                                PingWardenMonitor.shared.stopMonitoring()
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!monitorState.isHelperRegistered)
                }

                SettingsDivider()

                SettingsRow("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if monitorState.isMonitoring && monitorState.interventionCount > 0 {
                    SettingsDivider()
                    
                    SettingsRow("Lag Spikes Blocked") {
                        HStack(spacing: 8) {
                            Text("\(monitorState.interventionCount)")
                                .font(.headline)
                                .foregroundStyle(.green)
                            Text("blocked")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Button {
                                PingWardenMonitor.shared.resetInterventionCount { success in
                                    if success {
                                        monitorState.refresh()
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Reset counter")
                        }
                    }
                }
            }

            SettingsSectionHeader(title: "APP")

            SettingsGroup {
                SettingsRow("Launch at Login", description: "Start Ping Warden when you log in") {
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                                launchAtLogin = newValue
                            } catch {
                                settingsLog.error("Failed to update login item: \(error.localizedDescription)")
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                SettingsDivider()

                SettingsRow("Show Dock Icon", description: "Display app icon in the Dock") {
                    Toggle("", isOn: $showDockIcon)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChangeCompat(of: showDockIcon) { newValue in
                            PingWardenPreferences.shared.showDockIcon = newValue
                        }
                }

                SettingsDivider()

                SettingsRow("Menu Dropdown Metrics", description: "Show current ping and protection events in the menu") {
                    Toggle("", isOn: $showMenuDropdownMetrics)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChangeCompat(of: showMenuDropdownMetrics) { newValue in
                            PingWardenPreferences.shared.showMenuDropdownMetrics = newValue
                        }
                }
            }

            SettingsSectionHeader(title: "HOW IT WORKS")

            SettingsGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Label("No Password Prompts", systemImage: "checkmark.shield")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text("AWDL (Apple Wireless Direct Link) powers AirDrop, AirPlay, and Handoff. When it activates, it briefly takes over your Wi-Fi radio, causing lag spikes. Ping Warden uses a background helper to block these interruptions. The helper requires a one-time system approval and runs while the app is open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
            }
        }
        .onAppear {
            monitorState.startObserving()
        }
        .onDisappear {
            monitorState.stopObserving()
        }
    }

    private var statusColor: Color {
        if !monitorState.isHelperRegistered { return .gray }
        return monitorState.isMonitoring ? .green : .orange
    }

    private var statusText: String {
        if !monitorState.isHelperRegistered { return "Not Set Up" }
        return monitorState.isMonitoring ? "Protected" : "Not Protected"
    }
}

// MARK: - Automation Settings Content

struct AutomationSettingsContent: View {
    @State private var gameModeAutoDetect = PingWardenPreferences.shared.gameModeAutoDetect
    @State private var controlCenterEnabled = PingWardenPreferences.shared.controlCenterWidgetEnabled
    @State private var showingControlCenterConfirm = false

    private var isControlCenterAvailable: Bool {
        ControlCenterSupport.isAvailableForCurrentApp()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsRow("Game Mode Auto-Detect", description: "Automatically enable blocking when a game is fullscreen") {
                    HStack(spacing: 8) {
                        StatusBadge(text: "Beta", tint: .beta)
                        Toggle("", isOn: $gameModeAutoDetect)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChangeCompat(of: gameModeAutoDetect) { newValue in
                                PingWardenPreferences.shared.gameModeAutoDetect = newValue
                            }
                    }
                }
            }

            SettingsSectionHeader(title: "INTERFACE")

            SettingsGroup {
                SettingsRow("Control Center Widget", description: isControlCenterAvailable ? "Use Control Center instead of menu bar" : "Requires code-signed app (Developer ID)") {
                    HStack(spacing: 8) {
                        if isControlCenterAvailable {
                            StatusBadge(text: "Beta", tint: .beta)
                        } else {
                            StatusBadge(text: "Unavailable", tint: .unavailable)
                        }
                        Toggle("", isOn: $controlCenterEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!isControlCenterAvailable)
                            .onChangeCompat(of: controlCenterEnabled) { newValue in
                                if newValue {
                                    showingControlCenterConfirm = true
                                } else {
                                    PingWardenPreferences.shared.controlCenterWidgetEnabled = false
                                }
                            }
                    }
                }
            }

            if isControlCenterAvailable && controlCenterEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("To add the widget: System Settings → Control Center → scroll to Ping Warden")
                    Text("To access settings later, search for \"Ping Warden\" in Spotlight (Cmd+Space) or find it in your Applications folder.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.top, 8)
            } else if !isControlCenterAvailable {
                Text("Control Center widgets require the app to be signed with a Developer ID certificate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }
        }
        .confirmationDialog(
            "Hide Menu Bar Icon?",
            isPresented: $showingControlCenterConfirm,
            titleVisibility: .visible
        ) {
            Button("Hide Menu Bar Icon") {
                PingWardenPreferences.shared.controlCenterWidgetEnabled = true
            }
            Button("Cancel", role: .cancel) {
                controlCenterEnabled = false
            }
        } message: {
            Text("The menu bar icon will be hidden. To access settings later, search for \"Ping Warden\" in Spotlight (Cmd+Space) or find it in your Applications folder.")
        }
    }
}

// MARK: - Advanced Settings Content

struct AdvancedSettingsContent: View {
    @State private var showingReinstallConfirm = false
    @State private var showingUninstallConfirm = false
    @State private var showingTestResults = false
    @State private var testResults = ""
    @State private var showingDiagnosticsExportResult = false
    @State private var diagnosticsExportMessage = ""
    @State private var crashReportingEnabled = PingWardenPreferences.shared.isCrashReportingEnabled

    var body: some View {
        Form {
            Section("Privacy") {
                Toggle(isOn: $crashReportingEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send Crash Reports")
                        Text("Anonymous crash reports help us fix bugs. No IP address, no usage data, no ping targets. Applies after restart.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChangeCompat(of: crashReportingEnabled) { newValue in
                    PingWardenPreferences.shared.isCrashReportingEnabled = newValue
                }
            }

            Section("Diagnostics") {
                LabeledContent {
                    Button("Run Test") { runHelperTest() }
                        .buttonStyle(.bordered)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Test Helper Response")
                        Text("Verify the helper is responding quickly (password required)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Button("Open Console") { openConsoleApp() }
                        .buttonStyle(.bordered)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("View Logs")
                        Text("Open Console.app to view logs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Button("Export") { exportDiagnostics() }
                        .buttonStyle(.bordered)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Export Diagnostics")
                        Text("Create a support snapshot on Desktop")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Maintenance") {
                LabeledContent {
                    Button("Re-register\u{2026}") { showingReinstallConfirm = true }
                        .buttonStyle(.bordered)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Re-register Helper")
                        Text("Re-register if experiencing issues")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Button("Uninstall\u{2026}") { showingUninstallConfirm = true }
                        .buttonStyle(.bordered)
                        .tint(.red)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Uninstall")
                        Text("Unregister helper and quit app")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Re-register Helper?",
            isPresented: $showingReinstallConfirm,
            titleVisibility: .visible
        ) {
            Button("Re-register") {
                PingWardenMonitor.shared.installAndStartMonitoring()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will re-register the helper with the system. May help if you're experiencing connection issues.")
        }
        .confirmationDialog(
            "Uninstall Ping Warden?",
            isPresented: $showingUninstallConfirm,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                performUninstall()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will unregister the helper and quit. You can also just drag the app to Trash.")
        }
        .alert("Helper Test Results", isPresented: $showingTestResults) {
            Button("OK") {}
        } message: {
            Text(testResults)
        }
        .alert("Diagnostics Export", isPresented: $showingDiagnosticsExportResult) {
            Button("OK") {}
        } message: {
            Text(diagnosticsExportMessage)
        }
    }

    private func runHelperTest() {
        // Run health check on background thread to avoid UI freeze
        DispatchQueue.global(qos: .userInitiated).async {
            let healthCheck = PingWardenMonitor.shared.performHealthCheck()

            DispatchQueue.main.async {
                if !healthCheck.isHealthy {
                    self.testResults = "Health Check Failed:\n\(healthCheck.message)"
                    self.showingTestResults = true
                    return
                }

                // Run the actual test script
                self.runTestScript()
            }
        }
    }

    private func runTestScript() {
        // Use single quotes in shell script to avoid escaping issues
        let testScript = """
        echo 'Testing AWDL helper response time...'
        for i in 1 2 3 4 5; do
            ifconfig awdl0 up 2>/dev/null
            sleep 0.001
            if ifconfig awdl0 2>/dev/null | grep -q 'UP'; then
                echo "Test $i: FAILED - AWDL still UP after 1ms"
            else
                echo "Test $i: PASSED - AWDL brought down in <1ms"
            fi
        done
        echo ''
        echo 'Final AWDL status:'
        ifconfig awdl0 2>/dev/null | head -1
        """

        // Base64 encode the script to safely pass it through AppleScript
        guard let scriptData = testScript.data(using: .utf8) else {
            testResults = "Error: Could not encode test script"
            showingTestResults = true
            return
        }
        let base64Script = scriptData.base64EncodedString()

        let appleScript = """
        do shell script "echo '\(base64Script)' | base64 -d | sh" with administrator privileges
        """

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", appleScript]

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            do {
                try task.run()
                // Read pipe before waitUntilExit to avoid deadlock if the process
                // fills the pipe buffer (the process blocks on write, we block on wait).
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? "No output"

                DispatchQueue.main.async {
                    self.testResults = output
                    self.showingTestResults = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.testResults = "Test error: \(error.localizedDescription)"
                    self.showingTestResults = true
                }
            }
        }
    }

    private func openConsoleApp() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
    }

    private func exportDiagnostics() {
        DispatchQueue.global(qos: .utility).async {
            let result = DiagnosticsExporter.exportSnapshot()
            DispatchQueue.main.async {
                guard let result else {
                    diagnosticsExportMessage = "Failed to export diagnostics snapshot."
                    showingDiagnosticsExportResult = true
                    return
                }

                NSWorkspace.shared.activateFileViewerSelecting([result.fileURL])
                diagnosticsExportMessage = "Diagnostics exported to:\n\(result.fileURL.path)"
                showingDiagnosticsExportResult = true
            }
        }
    }

    private func performUninstall() {
        settingsLog.info("Performing uninstall...")

        // Stop monitoring and disconnect XPC
        PingWardenMonitor.shared.stopMonitoring()

        // Reset ALL App Group preferences to prevent lockout or stale state on reinstall
        // (issue #28). These persist in ~/Library/Group Containers/ and survive app deletion.
        let prefs = PingWardenPreferences.shared
        prefs.controlCenterWidgetEnabled = false
        prefs.showDockIcon = false
        prefs.isMonitoringEnabled = false
        prefs.effectiveMonitoringEnabled = false
        prefs.lastKnownState = "unknown"
        prefs.gameModeAutoDetect = false
        prefs.showMenuDropdownMetrics = false
        prefs.donationPromptLastSeenVersion = nil
        prefs.donationPromptDismissedPermanently = false
        // Crash reporting key is cleared (not set false) so that on
        // reinstall the registered default (true) re-applies.
        prefs.defaults.removeObject(forKey: "CrashReportingEnabled")

        // Drop any user-defined ping servers so a reinstall starts clean.
        CustomPingTargetStore(userDefaults: prefs.defaults).save([])

        // Unregister the helper with SMAppService
        do {
            let helperService = SMAppService.daemon(plistName: "com.amesvt.pingwarden.helper.plist")
            try helperService.unregister()
            settingsLog.info("Helper unregistered successfully")
        } catch {
            settingsLog.warning("Helper unregister: \(error.localizedDescription)")
        }

        // Quit the app - macOS will handle cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - About View

struct AboutView: View {
    @Environment(\.openURL) private var openURL

    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 64

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: heroIconSize, weight: .thin))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Ping Warden")
                .font(.title)
                .fontWeight(.semibold)
                .padding(.top, 16)

            Text("Version \(version) (\(build))")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

            Spacer()

            VStack(spacing: 6) {
                Text("<1ms response time")
                Text("0% CPU when idle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()

            Divider()

            VStack(spacing: 12) {
                Text("Credits")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    Link("jamestut/awdlkiller", destination: URL(string: "https://github.com/jamestut/awdlkiller") ?? URL(fileURLWithPath: "/"))
                        .font(.caption)

                    Text("AF_ROUTE monitoring concept")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                VStack(spacing: 4) {
                    Link("james-howard/AWDLControl", destination: URL(string: "https://github.com/james-howard/AWDLControl") ?? URL(fileURLWithPath: "/"))
                        .font(.caption)

                    Text("SMAppService + XPC architecture")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 12)

            Text("© 2025-2026 Oliver Ames")
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .padding(.bottom, 16)
        }
        .frame(width: 280, height: 400)
        .background(.regularMaterial)
    }
}

// MARK: - Game Mode Detector

/// Detects when macOS Game Mode is active by monitoring for fullscreen games.
/// Only apps that are categorized as games (via LSApplicationCategoryType or LSSupportsGameMode
/// in their Info.plist) will trigger game mode detection, preventing false positives from
/// non-game fullscreen apps like productivity apps or browsers.
///
/// Note: This feature requires Screen Recording permission on macOS 10.15+.
/// Without this permission, CGWindowListCopyWindowInfo won't return window names or owner info.
class GameModeDetector {
    private var timer: Timer?
    private var isGameModeActive = false
    private var hasLoggedPermissionWarning = false
    private let log = Logger(subsystem: "com.amesvt.pingwarden", category: "GameMode")
    /// Cache of pid → isGame to avoid re-reading Info.plist every 2 seconds.
    /// Entries are evicted via `appDidTerminateObserver` so the cache cannot
    /// outgrow the set of currently-running apps for the session.
    private var gameCheckCache: [pid_t: Bool] = [:]
    private var appDidTerminateObserver: NSObjectProtocol?

    var onGameModeChange: ((Bool) -> Void)?

    deinit {
        stop()
    }

    func start() {
        // Ensure we're on the main thread for timer scheduling
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.start()
            }
            return
        }

        // Check for Screen Recording permission on first start
        if !hasScreenRecordingPermission() {
            log.warning("Screen Recording permission not granted - Game Mode detection may not work correctly")
            if !hasLoggedPermissionWarning {
                hasLoggedPermissionWarning = true
                // Only show alert once per app session
                showScreenRecordingPermissionAlert()
            }
        }

        // Check immediately
        checkGameModeStatus()

        // Then check periodically (every 2 seconds) on main run loop
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkGameModeStatus()
        }
        // Ensure timer continues during UI interactions
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }

        // Evict cache entries when their PID terminates so the cache cannot
        // grow unbounded over a long-running session. macOS reuses PIDs, so
        // keeping stale entries would also poison the cache after rollover.
        if appDidTerminateObserver == nil {
            appDidTerminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else {
                    return
                }
                self?.gameCheckCache.removeValue(forKey: pid)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        gameCheckCache.removeAll()

        if let observer = appDidTerminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appDidTerminateObserver = nil
        }

        // Reset state
        if isGameModeActive {
            isGameModeActive = false
            onGameModeChange?(false)
        }
    }

    /// Check if Screen Recording permission is granted
    /// CGWindowListCopyWindowInfo requires this permission on macOS 10.15+ to get window names
    private func hasScreenRecordingPermission() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    /// Show alert explaining Screen Recording permission is needed
    private func showScreenRecordingPermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Screen Recording Permission Needed"
            alert.informativeText = "Game Mode auto-detect requires Screen Recording permission to detect fullscreen games.\n\nGrant access in System Settings → Privacy & Security → Screen Recording."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // Open System Preferences/Settings to Screen Recording
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func checkGameModeStatus() {
        let isFullscreen = isAnyAppFullscreen()

        if isFullscreen != isGameModeActive {
            isGameModeActive = isFullscreen
            log.info("Game Mode detected: \(isFullscreen)")
            onGameModeChange?(isFullscreen)
        }
    }

    private func isAnyAppFullscreen() -> Bool {
        // Get the main display bounds
        guard let mainScreen = NSScreen.main else { return false }
        let screenFrame = mainScreen.frame

        // Get list of windows on screen
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for window in windowList {
            // Skip windows that aren't at the standard window level or above
            guard let layer = window[kCGWindowLayer as String] as? Int32,
                  layer >= 0 else {
                continue
            }

            // Get window bounds
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"] else {
                continue
            }

            let windowFrame = CGRect(x: x, y: y, width: width, height: height)

            // Check if window covers the full screen
            if windowFrame.width >= screenFrame.width && windowFrame.height >= screenFrame.height {
                // Get owner name and PID
                guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                      let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t else {
                    continue
                }

                // Skip system apps that commonly go fullscreen
                let systemApps = ["Finder", "Dock", "Window Server", "SystemUIServer", "Control Center", "Notification Center"]
                if systemApps.contains(ownerName) {
                    continue
                }

                // Check if this app is marked as a game
                if isAppAGame(pid: ownerPID) {
                    log.debug("Fullscreen game detected: \(ownerName)")
                    return true
                } else {
                    log.debug("Fullscreen app '\(ownerName)' is not a game, ignoring")
                }
            }
        }

        return false
    }

    /// Checks if an app is categorized as a game by examining its Info.plist.
    /// Results are cached per-PID to avoid repeated disk I/O on the 2-second timer.
    private func isAppAGame(pid: pid_t) -> Bool {
        if let cached = gameCheckCache[pid] {
            return cached
        }
        let result = isAppAGameUncached(pid: pid)
        gameCheckCache[pid] = result
        return result
    }

    private func isAppAGameUncached(pid: pid_t) -> Bool {
        // Get the running application from PID
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundleURL = app.bundleURL else {
            log.debug("Could not get bundle for PID \(pid)")
            return false
        }

        // Load the bundle to access Info.plist
        guard let bundle = Bundle(url: bundleURL),
              let infoPlist = bundle.infoDictionary else {
            log.debug("Could not load Info.plist for bundle: \(bundleURL.lastPathComponent)")
            return false
        }

        // Check LSApplicationCategoryType for game category
        if let categoryType = infoPlist["LSApplicationCategoryType"] as? String {
            if categoryType.hasPrefix("public.app-category.games") {
                log.debug("App \(bundleURL.lastPathComponent) has game category")
                return true
            }
        }

        // Check LSSupportsGameMode flag
        if let supportsGameMode = infoPlist["LSSupportsGameMode"] as? Bool, supportsGameMode {
            log.debug("App \(bundleURL.lastPathComponent) supports Game Mode")
            return true
        }

        return false
    }
}
// MARK: - Previews

#Preview("General Settings") {
    GeneralSettingsContent()
        .frame(width: 450, height: 400)
        .background(.regularMaterial)
}

#Preview("Automation Settings") {
    AutomationSettingsContent()
        .frame(width: 450, height: 300)
        .background(.regularMaterial)
}

#Preview("Advanced Settings") {
    AdvancedSettingsContent()
        .frame(width: 450, height: 350)
        .background(.regularMaterial)
}

#Preview("About View") {
    AboutView()
}

#Preview("Welcome View") {
    WelcomeView(onSetup: {}, onDismiss: {})
}
