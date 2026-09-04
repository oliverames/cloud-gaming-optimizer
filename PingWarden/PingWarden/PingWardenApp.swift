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
            // Intentionally empty, and intentionally WITHOUT a fixed .frame().
            //
            // This Settings scene exists only to host the app-settings command
            // group below — the real preferences UI is an AppKit-managed
            // NSWindow (see AppDelegate.showSettingsWindow), so this scene's
            // window is a hidden phantom that is never presented.
            //
            // The previous `EmptyView().frame(width: 1, height: 1)` pinned that
            // phantom window's content to a 1pt-wide hard constraint. On
            // macOS 26+ that degenerate geometry drives the backing
            // NSHostingView into a re-entrant Update-Constraints-in-Window loop
            // and crashes with NSGenericException ("...more Update Constraints
            // in Window passes than there are views in the window"). The crash
            // report's window bounds literally read width 1, matching the old
            // frame. Letting the empty content size itself removes the
            // conflicting constraint and the loop.
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Ping Warden") {
                    appDelegate.openAbout()
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appDelegate.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, SPUUpdaterDelegate {
    private static let appMenuCheckForUpdatesTag = 2201
    // Sparkle feed URL is defined in Info.plist (SUFeedURL) as the single source of truth.

    private var updaterController: SPUStandardUpdaterController?
    private var updaterStartupError: Error?
    private var updaterHasStarted = false
    
    private var monitoringObserver: NSObjectProtocol?
    private var controlCenterObserver: NSObjectProtocol?
    private var dockIconObserver: NSObjectProtocol?
    private var gameModeObserver: NSObjectProtocol?
    private var menuMetricsObserver: NSObjectProtocol?
    private var windowObserver: NSObjectProtocol?
    private var settingsShortcutMonitor: Any?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var licenseNoticeWindow: NSWindow?
    private var gameModeDetector: GameModeDetector?
    private var monitorStateObserverToken: UUID?
    private var lastToggleTime: Date = .distantPast
    private let menuMetricsConsumerID = UUID()
    private var menuMetricsObserverToken: UUID?
    private var menuMetricsTimer: Timer?
    private var menuCurrentPingMs: Double?
    private var menuInterventionCount: Int?
    private var isStatusMenuOpen = false
    private let sessionCoordinator = ProtectedSessionCoordinator.shared
    private let protectionExperience = ProtectionExperienceCoordinator.shared
    private let settingsNavigation = SettingsNavigationModel()
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("Ping Warden launching...")

        sessionCoordinator.onSessionStateChanged = { [weak self] in
            self?.updateQuickActionMenuItems()
        }

        // Optional anonymous crash reporting (Sentry). New installations start
        // with it off; the Settings privacy toggle is checked before startup.
        CrashReporter.startIfEnabled()

        // Clear any cached Settings window state from prior builds that may have
        // injected fullSizeContentView or other window customizations via onAppear.
        // The SwiftUI Settings scene persists window frames under these keys.
        // Exclude our own AppKit settings window's autosave frame
        // ("PingWardenSettings") — deleting it every launch would throw away
        // the user's window size/position.
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            if key.contains("NSWindow Frame") && key.contains("Settings") && !key.contains("PingWardenSettings") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // Initialize monitoring before Sparkle so first-run UX can be gated on setup state.
        let monitor = PingWardenMonitor.shared

        // Licensing: grandfather existing installs (protection already
        // enabled and helper already approved) for 90 days, then enforce
        // the license gate.
        LicenseManager.shared.establishGrandfatheringIfNeeded(helperEnabled: monitor.isHelperRegistered)
        LicenseManager.shared.onReverificationSettled = { [weak self] in
            Task { @MainActor in
                await self?.protectionExperience.handleLicenseReverification()
            }
        }
        LicenseManager.shared.startPeriodicReverification()
        LicenseManager.shared.reverifyAtLaunchIfNeeded()

        // The monitor only restores persisted protection when the gate
        // already held before grandfathering ran. Settle the two cases
        // that leaves: a freshly grandfathered install that still needs
        // its restore, and a persisted intent whose entitlement is gone.
        if PingWardenPreferences.shared.isMonitoringEnabled {
            if LicenseManager.shared.canEnableProtection {
                if !monitor.isMonitoringActive, !monitor.isMonitoringRequested,
                   !protectionExperience.isPauseActive {
                    Task { @MainActor in
                        await self.protectionExperience.setPersistentProtection(true)
                    }
                }
            } else {
                log.info("Clearing persisted protection intent: license entitlement is gone")
                protectionExperience.noteLaunchLicenseGate()
            }
        }

        // One-time notice for grandfathered installs so the move to a
        // paid model is explained, never a surprise.
        if LicenseManager.shared.isGrandfathered,
           !LicenseManager.shared.transitionNoticeShown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                guard LicenseManager.shared.isGrandfathered,
                      !LicenseManager.shared.transitionNoticeShown else { return }
                LicenseManager.shared.transitionNoticeShown = true
                self.showLicenseTransitionNotice()
            }
        }
#if DEBUG
        let debugWindowPrefix = "--show-window="
        let debugWindowTarget = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix(debugWindowPrefix) })
            .map { String($0.dropFirst(debugWindowPrefix.count)) }
#else
        let debugWindowTarget: String? = nil
#endif

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
            Task { @MainActor in
                guard let self else { return }
                self.protectionExperience.refreshFromMonitor()
                self.updateMenuBarIcon()
                self.updateMenuItem()
                // If Sparkle was deferred during first-run setup, start it as
                // soon as the helper registration completes — otherwise
                // automatic update checks stay silently disabled all session.
                if PingWardenMonitor.shared.isHelperRegistered {
                    self.startUpdaterIfNeeded()
                }
            }
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
            if debugWindowTarget == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.showWelcomeWindow()
                }
            }
        } else {
            log.info("Helper already registered")
            // Reconcile both directions at startup: start if the user wants
            // protection and it isn't running, but also stop if a widget/
            // Shortcuts toggle turned it off while the app wasn't running.
            handleMonitoringStateChange()
        }

#if DEBUG
        if let debugWindowTarget {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showDebugWindow(named: debugWindowTarget)
            }
        }
#endif

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
            Task { @MainActor in
                self?.handleExternalMonitoringStateChange()
            }
        }

        // Observe Control Center mode changes
        controlCenterObserver = NotificationCenter.default.addObserver(
            forName: .controlCenterModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleControlCenterModeChange()
            }
        }

        // Observe dock icon visibility changes
        dockIconObserver = NotificationCenter.default.addObserver(
            forName: .dockIconVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateDockIconVisibility()
            }
        }

        // Observe Game Mode auto-detect changes
        gameModeObserver = NotificationCenter.default.addObserver(
            forName: .gameModeAutoDetectChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleGameModeAutoDetectChange()
            }
        }

        menuMetricsObserver = NotificationCenter.default.addObserver(
            forName: .menuDropdownMetricsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleMenuMetricsPreferenceChange()
            }
        }

        handleMenuMetricsPreferenceChange()
        ensureApplicationMenuItems()
        installSettingsShortcutMonitor()

        // Observe all window close events so we can update dock icon visibility
        // when any foreground utility window closes.
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateDockIconVisibility()
            }
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
        isTerminating = true

        gameModeDetector?.stop()
        protectionExperience.finishForTermination()

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
        if let settingsShortcutMonitor {
            NSEvent.removeMonitor(settingsShortcutMonitor)
            self.settingsShortcutMonitor = nil
        }

        menuMetricsTimer?.invalidate()
        menuMetricsTimer = nil
        PingMonitor.shared.stop(consumerID: menuMetricsConsumerID)
        if let menuMetricsObserverToken {
            PingMonitor.shared.removeObserver(menuMetricsObserverToken)
            self.menuMetricsObserverToken = nil
        }
    }

    private func updateDockIconVisibility() {
        let settingsVisible = settingsWindow?.isVisible ?? false
        let aboutVisible = aboutWindow?.isVisible ?? false
        let welcomeVisible = welcomeWindow?.isVisible ?? false
        let licenseNoticeVisible = licenseNoticeWindow?.isVisible ?? false

        // Lockout invariant (H2): never hide the dock icon while Control
        // Center mode has the menu bar icon removed. Without this, unchecking
        // "Show Dock Icon" after enabling Control Center mode leaves no way
        // into the app except re-launching from Finder — and the state
        // persists across launches. (Checked against the preference, not
        // `statusItem == nil`, because this also runs at launch before
        // setupMenuBar() when statusItem is legitimately still nil.)
        if PingWardenPreferences.shared.controlCenterWidgetEnabled,
           !PingWardenPreferences.shared.showDockIcon {
            log.info("Menu bar icon is hidden (Control Center mode) — forcing dock icon on to prevent lockout")
            PingWardenPreferences.shared.showDockIcon = true
            // Deliberately fall through (no early return): at launch this
            // runs before the dockIconVisibilityChanged observer exists, so
            // relying on the setter's notification to re-enter would leave
            // the activation policy unset for the whole session.
        }

        if PingWardenPreferences.shared.showDockIcon || settingsVisible || aboutVisible || welcomeVisible || licenseNoticeVisible {
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
        if window === settingsWindow || window === aboutWindow || window === welcomeWindow || window === licenseNoticeWindow {
            if window === settingsWindow {
                settingsWindow = nil
            }
            if window === aboutWindow {
                aboutWindow = nil
            }
            if window === welcomeWindow {
                welcomeWindow = nil
            }
            if window === licenseNoticeWindow {
                licenseNoticeWindow = nil
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
        Task { @MainActor in
            await protectionExperience.setGameModeActive(isActive)
            updateMenuItem()
        }
    }

    // MARK: - Welcome Window

    private func showWelcomeWindow() {
        if welcomeWindow != nil { return }

        let experience = protectionExperience
        let welcomeView = WelcomeView { completion in
            PingWardenMonitor.shared.registerHelper { registered in
                Task { @MainActor in
                    guard registered else {
                        completion(false)
                        return
                    }
                    // Setup is complete even without a license; only the
                    // protection toggle itself is gated. An unlicensed
                    // enable reports false and shows its message in the
                    // protectionExperience error surface.
                    _ = await experience.setPersistentProtection(true)
                    completion(true)
                }
            }
        } onOpenDashboard: {
            self.welcomeWindow?.close()
            self.welcomeWindow = nil
            self.openDashboard()
        } onDismiss: {
            self.welcomeWindow?.close()
            self.welcomeWindow = nil
            self.updateDockIconVisibility()
        } onOpenLicenseSettings: {
            self.welcomeWindow?.close()
            self.welcomeWindow = nil
            self.settingsNavigation.selectedSection = .license
            self.openSettings()
        }

#if DEBUG
        var welcomeRootView = AnyView(welcomeView)
        if ProcessInfo.processInfo.arguments.contains("--welcome-large-text") {
            welcomeRootView = AnyView(
                welcomeRootView.environment(\.dynamicTypeSize, .accessibility5)
            )
        }
        if ProcessInfo.processInfo.arguments.contains("--welcome-dark") {
            welcomeRootView = AnyView(welcomeRootView.preferredColorScheme(.dark))
        }
        let hostingController = NSHostingController(rootView: welcomeRootView)
#else
        let hostingController = NSHostingController(rootView: welcomeView)
#endif
#if DEBUG
        let initialSize = ProcessInfo.processInfo.arguments.contains("--welcome-min-size")
            ? NSSize(width: 480, height: 560)
            : WelcomeView.defaultSize
#else
        let initialSize = WelcomeView.defaultSize
#endif
        hostingController.view.frame = NSRect(origin: .zero, size: initialSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "Welcome to Ping Warden"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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

    // MARK: - License Transition Notice

    /// One-time window explaining the paid-model transition to
    /// grandfathered installs. Shown only on the first launch of the
    /// licensed build that observes protection already enabled.
    private func showLicenseTransitionNotice() {
        guard licenseNoticeWindow == nil,
              LicenseManager.shared.isGrandfathered else { return }

        let view = LicenseTransitionNoticeView(
            daysRemaining: LicenseManager.shared.grandfatherDaysRemaining,
            onOpenLicenseSettings: { [weak self] in
                self?.closeLicenseNoticeWindow()
                self?.settingsNavigation.selectedSection = .license
                self?.openSettings()
            },
            onDismiss: { [weak self] in
                self?.closeLicenseNoticeWindow()
            }
        )

        let hostingController = NSHostingController(rootView: view)
        hostingController.view.frame = NSRect(origin: .zero, size: LicenseTransitionNoticeView.contentSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: LicenseTransitionNoticeView.contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "Ping Warden Is Moving to a License"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        licenseNoticeWindow = window

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ensureApplicationMenuItems()
    }

    private func closeLicenseNoticeWindow() {
        licenseNoticeWindow?.close()
        licenseNoticeWindow = nil
        updateDockIconVisibility()
    }

#if DEBUG
    private func showDebugWindow(named name: String) {
        switch name {
        case "dashboard":
            settingsNavigation.selectedSection = .dashboard
            openSettings()
        case "general":
            settingsNavigation.selectedSection = .general
            openSettings()
        case "automation":
            settingsNavigation.selectedSection = .automation
            openSettings()
        case "advanced":
            settingsNavigation.selectedSection = .advanced
            openSettings()
        case "about":
            showAbout()
        default:
            log.error("Unknown debug window target: \(name, privacy: .public)")
        }
    }
#endif

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
        // Manual isEnabled control for the pause/resume items: with
        // autoenablesItems left on, AppKit re-enables any item whose target
        // responds to its action every time the menu opens, overriding the
        // assignments in updateQuickActionMenuItems().
        statusMenu?.autoenablesItems = false

        let dashboardItem = NSMenuItem(
            title: "Open Dashboard...",
            action: #selector(openDashboard),
            keyEquivalent: ""
        )
        dashboardItem.target = self
        dashboardItem.image = menuSymbol("chart.xyaxis.line")
        statusMenu?.addItem(dashboardItem)
        statusMenu?.addItem(NSMenuItem.separator())

        let initialPresentation = protectionExperience.menuPresentation()
        let toggleItem = NSMenuItem(
            title: initialPresentation.protectionTitle,
            action: #selector(toggleMonitoring),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.tag = 140
        toggleItem.image = protectionMenuImage()
        statusMenu?.addItem(toggleItem)

        let pauseItem = NSMenuItem(
            title: initialPresentation.pauseTitle ?? "Pause for 10 Minutes",
            action: #selector(toggleQuickPause),
            keyEquivalent: ""
        )
        pauseItem.target = self
        pauseItem.image = menuSymbol("pause.circle")
        pauseItem.tag = 150
        statusMenu?.addItem(pauseItem)

        statusMenu?.addItem(NSMenuItem.separator())

        // Status item
        let statusMenuItem = NSMenuItem(title: "Status: Checking...", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        statusMenu?.addItem(statusMenuItem)

        let pingMenuItem = NSMenuItem(title: "Current Ping: --", action: nil, keyEquivalent: "")
        pingMenuItem.tag = 101
        pingMenuItem.isEnabled = false
        statusMenu?.addItem(pingMenuItem)

        let interventionsMenuItem = NSMenuItem(title: "Wireless Interruptions: --", action: nil, keyEquivalent: "")
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
        showMetricsItem.image = menuSymbol("chart.xyaxis.line")
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
        settingsItem.image = menuSymbol("gearshape")
        statusMenu?.addItem(settingsItem)

        // Check for Updates (Sparkle)
        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = self
        updateItem.image = menuSymbol("arrow.trianglehead.2.clockwise.rotate.90")
        statusMenu?.addItem(updateItem)

        // About
        let aboutItem = NSMenuItem(
            title: "About Ping Warden",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        aboutItem.image = menuSymbol("info.circle")
        statusMenu?.addItem(aboutItem)

        let supportItem = NSMenuItem(
            title: "Donate to Ping Warden...",
            action: #selector(supportPingWarden),
            keyEquivalent: ""
        )
        supportItem.target = self
        supportItem.image = menuSymbol("cup.and.saucer")
        statusMenu?.addItem(supportItem)

        statusMenu?.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Ping Warden",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.image = menuSymbol("xmark.square")
        statusMenu?.addItem(quitItem)

        self.statusItem?.menu = statusMenu
    }

    private func menuSymbol(_ symbolName: String, accessibilityDescription: String? = nil) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
        image?.isTemplate = true
        return image
    }

    private func protectionMenuImage() -> NSImage? {
        let isMonitoring = PingWardenMonitor.shared.isMonitoringActive
        let symbolName = isMonitoring ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right"
        let description = isMonitoring ? "Turn Off Ping Protection" : "Turn On Ping Protection"
        return menuSymbol(symbolName, accessibilityDescription: description)
    }

    private func removeMenuBar() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            statusMenu = nil
        }
        stopMenuMetricsMonitoring()
    }

    @objc func openSettings() {
        log.info("openSettings called")
        NSApp.setActivationPolicy(.regular)
        showSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
        ensureApplicationMenuItems()
    }

    @objc private func openDashboard() {
        settingsNavigation.selectedSection = .dashboard
        openSettings()
    }

    @objc func openAbout() {
        showAbout()
    }

    private func installSettingsShortcutMonitor() {
        settingsShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  event.charactersIgnoringModifiers == "," else {
                return event
            }

            self?.openSettings()
            return nil
        }
    }

    private func showSettingsWindow() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            updateDockIconVisibility()
            return
        }

        let settingsView = SettingsView(
            navigationModel: settingsNavigation,
            onCheckForUpdates: { [weak self] in
                self?.checkForUpdates()
            }
        )
        let hostingController = NSHostingController(rootView: settingsView)
#if DEBUG
        let usesDebugMinimumSize = ProcessInfo.processInfo.arguments.contains("--settings-min-size")
        let initialSize = usesDebugMinimumSize
            ? NSSize(width: 760, height: 520)
            : NSSize(width: 980, height: 700)
#else
        let usesDebugMinimumSize = false
        let initialSize = NSSize(width: 980, height: 700)
#endif
        hostingController.view.frame = NSRect(origin: .zero, size: initialSize)

        if #available(macOS 14.0, *) {
            hostingController.sceneBridgingOptions = .all
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.title = "Settings"
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = false
        window.toolbar?.showsBaselineSeparator = false
        // Center first, then attach the autosave name: setFrameAutosaveName
        // restores any saved frame, so the restored position must not be
        // clobbered by a subsequent center().
        window.center()
        if !usesDebugMinimumSize {
            window.setFrameAutosaveName("PingWardenSettings")
        }

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        updateDockIconVisibility()
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
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.minSize = NSSize(width: 380, height: 420)
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

    @objc private func supportPingWarden() {
        NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/oliverames")!)
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

    @discardableResult
    private func startUpdaterIfNeeded() -> Bool {
        guard let updater = updaterController?.updater else {
            return false
        }

        if updaterHasStarted {
            return true
        }

        do {
            try updater.start()
            updaterHasStarted = true
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

        if let aboutItem = appMenu.items.first(where: { $0.title.hasPrefix("About ") }) {
            aboutItem.target = self
            aboutItem.action = #selector(showAbout)
        }

        if let settingsItem = appMenu.items.first(where: { $0.keyEquivalent == "," || $0.title == "Settings..." }) {
            settingsItem.title = "Settings..."
            settingsItem.target = self
            settingsItem.action = #selector(openSettings)
            settingsItem.keyEquivalent = ","
        } else if let aboutIndex = appMenu.items.firstIndex(where: { $0.title.hasPrefix("About ") }) {
            let settingsItem = NSMenuItem(
                title: "Settings...",
                action: #selector(openSettings),
                keyEquivalent: ","
            )
            settingsItem.target = self
            appMenu.insertItem(settingsItem, at: aboutIndex + 1)
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
        let errorText: String
        if let startupError = updaterStartupError as NSError? {
            errorText = "\(startupError.domain) \(startupError.code): \(startupError.localizedDescription)"
        } else {
            errorText = "The updater did not provide an error message."
        }
        alert.informativeText = "Ping Warden could not start its updater. You can retry, open the latest release in your browser, or copy the error for troubleshooting.\n\n\(errorText)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Download Latest Release")
        alert.addButton(withTitle: "Copy Error")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if startUpdaterIfNeeded() {
                updaterController?.updater.checkForUpdates()
            }
        case .alertSecondButtonReturn:
            if let releasesURL = URL(string: "https://github.com/oliverames/ping-warden/releases/latest") {
                NSWorkspace.shared.open(releasesURL)
            }
        case .alertThirdButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(errorText, forType: .string)
        default:
            break
        }
    }

    /// Sparkle calls this on every update check. Returning nil falls back to
    /// the `SUFeedURL` in Info.plist (stable channel). Returning the beta URL
    /// makes Sparkle pull `appcast-beta.xml` for opted-in users. The beta
    /// appcast is on the same gh-pages branch, signed with the same EdDSA
    /// key, just a separate XML file.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        guard PingWardenPreferences.shared.betaChannelEnabled else {
            return nil
        }
        return "https://oliverames.github.io/ping-warden/appcast-beta.xml"
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        log.error("Sparkle update cycle aborted: [\(nsError.domain, privacy: .public):\(nsError.code)] \(nsError.localizedDescription, privacy: .public)")
    }
    
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
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

        let presentation = protectionExperience.menuPresentation()
        if let toggleItem = menu.items.first(where: { $0.tag == 140 }) {
            toggleItem.title = presentation.protectionTitle
            toggleItem.image = protectionMenuImage()
            toggleItem.isEnabled = presentation.protectionActionEnabled
        }

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
                interventionsItem.title = "Wireless Interruptions: \(count)"
            } else {
                interventionsItem.title = "Wireless Interruptions: --"
            }
        }
    }

    private func updateQuickActionMenuItems() {
        guard let menu = statusMenu else { return }

        let presentation = protectionExperience.menuPresentation()
        if let pauseItem = menu.items.first(where: { $0.tag == 150 }) {
            pauseItem.isHidden = presentation.pauseTitle == nil
            pauseItem.title = presentation.pauseTitle ?? "Pause for 10 Minutes"
            pauseItem.isEnabled = presentation.pauseActionEnabled
            pauseItem.image = menuSymbol(
                presentation.pauseTitle?.hasPrefix("Resume") == true
                    ? "play.circle"
                    : "pause.circle"
            )
        }

    }

    private func updateStatusMenuItem() {
        guard let menu = statusMenu,
              let statusItem = menu.items.first(where: { $0.tag == 100 }) else { return }

        statusItem.title = protectionExperience.menuPresentation().statusTitle
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        isStatusMenuOpen = true
        syncMenuMetricsTargetIfNeeded()
        updateMenuItem()
        refreshMenuInterventionCount()
        // Live dropdown metrics only run while the menu can actually show
        // them; opening starts the probe and intervention polling and
        // closing tears it down again.
        if PingWardenPreferences.shared.showMenuDropdownMetrics {
            startMenuMetricsMonitoring()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        isStatusMenuOpen = false
        if PingWardenPreferences.shared.showMenuDropdownMetrics {
            stopMenuMetricsMonitoring()
        }
    }

    @objc private func toggleMonitoring() {
        // Debounce rapid toggles to prevent race conditions
        let now = Date()
        guard now.timeIntervalSince(lastToggleTime) > 0.5 else {
            log.debug("Toggle debounced - too soon since last toggle")
            return
        }
        lastToggleTime = now

        guard PingWardenMonitor.shared.isHelperRegistered else {
            showWelcomeWindow()
            return
        }

        let shouldEnable = protectionExperience.pauseUntil != nil
            || (!PingWardenMonitor.shared.isMonitoringRequested
                && !PingWardenMonitor.shared.isMonitoringActive)
        Task {
            await protectionExperience.setPersistentProtection(shouldEnable)
            updateMenuItem()
        }
    }

    @objc private func toggleMenuDropdownMetrics() {
        PingWardenPreferences.shared.showMenuDropdownMetrics.toggle()
    }

    @objc private func toggleQuickPause() {
        Task {
            if protectionExperience.pauseUntil != nil {
                await protectionExperience.resumeProtection()
            } else {
                await protectionExperience.pauseForTenMinutes()
            }
            updateMenuItem()
        }
    }

    private func handleMenuMetricsPreferenceChange() {
        guard statusItem != nil else {
            stopMenuMetricsMonitoring()
            return
        }

        if PingWardenPreferences.shared.showMenuDropdownMetrics, isStatusMenuOpen {
            startMenuMetricsMonitoring()
        } else {
            stopMenuMetricsMonitoring()
        }
        updateMenuMetricsMenuItems()
    }

    private func startMenuMetricsMonitoring() {
        let target = menuMetricsTarget()

        if menuMetricsObserverToken == nil {
            menuMetricsObserverToken = PingMonitor.shared.addObserver { [weak self] snapshot in
                guard let self else { return }
                let result = snapshot.latestResult
                self.menuCurrentPingMs = result.success ? result.latencyMs : nil
                self.updateMenuMetricsMenuItems()
            }
        }
        PingMonitor.shared.start(
            consumerID: menuMetricsConsumerID,
            server: target.host,
            port: target.port,
            interval: 2,
            priority: 10
        )

        refreshMenuInterventionCount()

        if menuMetricsTimer == nil {
            menuMetricsTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.syncMenuMetricsTargetIfNeeded()
                    self?.refreshMenuInterventionCount()
                }
            }
            if let menuMetricsTimer {
                RunLoop.main.add(menuMetricsTimer, forMode: .common)
            }
        }
    }

    private func stopMenuMetricsMonitoring() {
        menuMetricsTimer?.invalidate()
        menuMetricsTimer = nil
        PingMonitor.shared.stop(consumerID: menuMetricsConsumerID)
        if let menuMetricsObserverToken {
            PingMonitor.shared.removeObserver(menuMetricsObserverToken)
            self.menuMetricsObserverToken = nil
        }
        menuCurrentPingMs = nil
        menuInterventionCount = nil
    }

    private func syncMenuMetricsTargetIfNeeded() {
        guard PingWardenPreferences.shared.showMenuDropdownMetrics else { return }

        let target = menuMetricsTarget()
        PingMonitor.shared.start(
            consumerID: menuMetricsConsumerID,
            server: target.host,
            port: target.port,
            interval: 2,
            priority: 10
        )
    }

    private func refreshMenuInterventionCount() {
        guard PingWardenPreferences.shared.showMenuDropdownMetrics else { return }

        PingWardenMonitor.shared.getInterventionCount { [weak self] count in
            Task { @MainActor in
                guard let self, let count else { return }
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
        Task { @MainActor in
            // A persisted pause restored at launch outranks the stored
            // protection intent until it expires; resumeProtection enables
            // blocking when the pause timer fires.
            if !protectionExperience.isPauseActive {
                _ = await protectionExperience.setPersistentProtection(shouldMonitor)
            }
            updateMenuBarIcon()
            updateMenuItem()
        }
    }

    private func handleExternalMonitoringStateChange() {
        let effectiveState = PingWardenPreferences.shared.effectiveMonitoringEnabled
        Task { @MainActor in
            await protectionExperience.handleExternallyAppliedProtectionState(effectiveState)
            updateMenuBarIcon()
            updateMenuItem()
        }
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

// MARK: - License Transition Notice View

/// One-time notice shown on the first launch of the licensed build for
/// grandfathered installs. Explains the paid-model move, the 90-day
/// transition, and the donation-honoring offer.
struct LicenseTransitionNoticeView: View {
    static let contentSize = CGSize(width: 460, height: 460)

    let daysRemaining: Int?
    let onOpenLicenseSettings: () -> Void
    let onDismiss: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 40

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: heroIconSize, weight: .light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                    .padding(.top, 24)

                VStack(spacing: 10) {
                    Text("Ping Warden Is Moving to a License")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)

                    VStack(spacing: 8) {
                        if let daysRemaining {
                            Text("Starting with this release, the AWDL blocking feature (Ping Protection) requires a one-time $15 license.")
                            Text("As a thank-you for being an early user, this Mac keeps full Ping Protection for \(daysRemaining) more days. Nothing changes today, and no action is needed right now.")
                        } else {
                            Text("Starting with this release, the AWDL blocking feature (Ping Protection) requires a one-time $15 license.")
                            Text("As a thank-you for being an early user, this Mac keeps full Ping Protection during a 90-day transition. Nothing changes today, and no action is needed right now.")
                        }
                        Text("Everything else in Ping Warden stays free, and the source code remains open under the MIT License.")
                    }
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
                }
                .padding(.top, 16)
                .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Already supported Ping Warden?")
                        .font(.headline)
                    Text("If you donated through the Buy Me a Coffee link before this release, email \(LicenseManager.donationConversionEmail) and that support will be honored as a full license.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Email \(LicenseManager.donationConversionEmail)") {
                        NSWorkspace.shared.open(URL(string: "mailto:\(LicenseManager.donationConversionEmail)?subject=Ping%20Warden%20license%20from%20donation")!)
                    }
                    .controlSize(.small)
                }
                .padding(.top, 20)
                .padding(.horizontal, 32)

                VStack(spacing: 10) {
                    Button {
                        onOpenLicenseSettings()
                    } label: {
                        Text("View License Options")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)

                    Button {
                        onDismiss()
                    } label: {
                        Text("Continue Using Ping Warden")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 24)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Settings View

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var selectedSection: SettingsSection = .general
}

struct SettingsView: View {
    let onCheckForUpdates: () -> Void
    @ObservedObject var navigationModel: SettingsNavigationModel

    init(
        navigationModel: SettingsNavigationModel,
        onCheckForUpdates: @escaping () -> Void = {}
    ) {
        self.navigationModel = navigationModel
        self.onCheckForUpdates = onCheckForUpdates
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $navigationModel.selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            SettingsContentView(
                section: navigationModel.selectedSection,
                onCheckForUpdates: onCheckForUpdates
            )
            .navigationTitle(navigationModel.selectedSection.rawValue)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .settingsToolbarMaterial()
        .frame(minWidth: 760, minHeight: 520)
    }
}

private extension View {
    @ViewBuilder
    func settingsToolbarMaterial() -> some View {
        if #available(macOS 15.0, *) {
            self
                .toolbarBackground(.bar, for: .windowToolbar)
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        } else {
            self
                .toolbarBackground(.bar, for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        }
    }

    @ViewBuilder
    func settingsScrollEdgeTreatment() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case general = "General"
    case license = "License"
    case automation = "Automation"
    case advanced = "Advanced"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "chart.xyaxis.line"
        case .general: return "gearshape"
        case .license: return "checkmark.seal"
        case .automation: return "sparkles"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

struct SettingsContentView: View {
    let section: SettingsSection
    let onCheckForUpdates: () -> Void

    var body: some View {
        Group {
            switch section {
            case .dashboard:
                dashboardContent
            case .general:
                GeneralSettingsContent(onCheckForUpdates: onCheckForUpdates)
            case .license:
                LicenseSettingsContent()
            case .automation:
                AutomationSettingsContent()
            case .advanced:
                AdvancedSettingsContent()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var dashboardContent: some View {
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DashboardSettingsContent()
                }

                Spacer(minLength: 20)
            }
            .scrollContentBackground(.hidden)
            .settingsScrollEdgeTreatment()
        }
        // No explicit .background here: on macOS 26 the Settings scene
        // already renders with the system Liquid Glass material, and an
        // opaque windowBackgroundColor on top would obscure it. On
        // macOS 13-25 the inherited scene background continues to look
        // correct without us setting one explicitly.
    }
}

// MARK: - Settings Components

private let settingsLog = Logger(subsystem: "com.amesvt.pingwarden", category: "Settings")

/// Small pill badge ("Unavailable", "Needs Permission", etc.) with WCAG AA contrast.
/// White text on a darker-tinted fill passes >=4.5:1 in both light and dark
/// mode without depending on the parent background. Replaces the previous
/// `.opacity(0.2)` pattern which scored 1.71:1 in light mode (text was nearly
/// invisible to low-vision users).
struct StatusBadge: View {
    enum Tint {
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
        case .unavailable: return Color(red: 0.40, green: 0.40, blue: 0.40)
        }
    }

    private var voiceOverLabel: String {
        switch tint {
        case .unavailable: return "\(text)"
        }
    }
}

// MARK: - General Settings Content

struct GeneralSettingsContent: View {
    let onCheckForUpdates: () -> Void
    @StateObject private var monitorState = MonitoringStateStore()
    @ObservedObject private var protectionExperience = ProtectionExperienceCoordinator.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showDockIcon = PingWardenPreferences.shared.showDockIcon
    @State private var showMenuDropdownMetrics = PingWardenPreferences.shared.showMenuDropdownMetrics
    @State private var settingsErrorMessage: String?
    @State private var isFinishingSetup = false

    init(onCheckForUpdates: @escaping () -> Void = {}) {
        self.onCheckForUpdates = onCheckForUpdates
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ping Warden")
                            .font(.headline)
                        Text("Version \(appVersion)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 16)

                    Button("Check for Updates...", action: onCheckForUpdates)
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 8)
            }

            Section("Protection") {
                if monitorState.isHelperRegistered {
                    Toggle(isOn: Binding(
                        get: { PingWardenPreferences.shared.isMonitoringEnabled },
                        set: { newValue in
                            Task {
                                await protectionExperience.setPersistentProtection(newValue)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep Ping Protection On")
                            Text("Keep protection active outside Latency Sessions and Game Mode")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(protectionExperience.isBusy)
                    .accessibilityLabel("Keep Ping Protection On")
                    .accessibilityHint("Controls ongoing protection outside temporary latency sessions and Game Mode")
                } else {
                    LabeledContent {
                        Button {
                            finishSetup()
                        } label: {
                            if isFinishingSetup {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Finish Setup")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isFinishingSetup)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ping Protection")
                            Text("Approve the helper to finish setup")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let error = protectionExperience.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Status")
                .accessibilityValue(statusText)

                if monitorState.isMonitoring && monitorState.interventionCount > 0 {
                    LabeledContent("Wireless Interruptions") {
                        HStack(spacing: 8) {
                            Text("\(monitorState.interventionCount)")
                                .font(.headline)
                                .foregroundStyle(.green)
                            Text("blocked")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button {
                                PingWardenMonitor.shared.resetInterventionCount { success in
                                    Task { @MainActor in
                                        if success {
                                            monitorState.refresh()
                                        } else {
                                            settingsErrorMessage = "The helper could not reset the intervention counter. Run the helper test in Advanced settings and try again."
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Reset intervention counter")
                            .help("Reset counter")
                        }
                    }
                }
            }

            Section("App") {
                Toggle(isOn: Binding(
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
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            settingsErrorMessage = "Launch at Login could not be changed. \(error.localizedDescription)"
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login")
                        Text("Start Ping Warden when you log in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $showDockIcon) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Dock Icon")
                        Text("Display app icon in the Dock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChangeCompat(of: showDockIcon) { newValue in
                    PingWardenPreferences.shared.showDockIcon = newValue
                }

                Toggle(isOn: $showMenuDropdownMetrics) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Menu Dropdown Metrics")
                        Text("Show current ping and protection events in the menu")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChangeCompat(of: showMenuDropdownMetrics) { newValue in
                    PingWardenPreferences.shared.showMenuDropdownMetrics = newValue
                }
            }

            Section("Support") {
                LabeledContent {
                    Button("Donate...") {
                        NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/oliverames")!)
                    }
                    .buttonStyle(.bordered)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Support Development")
                        Text("Ping Warden is open source, and everything except enabling Ping Protection is free. Donations made before the licensed release are honored as full licenses; email \(LicenseManager.donationConversionEmail) to claim yours.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                Label("No Password Prompts", systemImage: "checkmark.shield")
                    .font(.subheadline)
                    .fontWeight(.medium)
            } header: {
                Text("How It Works")
            } footer: {
                Text("AWDL (Apple Wireless Direct Link) powers AirDrop, AirPlay, and Handoff. Its radio activity can interrupt latency-sensitive traffic. Ping Warden uses a background helper to block AWDL while protection is active. The helper requires one system approval and runs on demand.")
            }
        }
        .formStyle(.grouped)
        .settingsScrollEdgeTreatment()
        .onAppear {
            monitorState.startObserving()
        }
        .onDisappear {
            monitorState.stopObserving()
        }
        .alert(
            "Setting Could Not Be Changed",
            isPresented: Binding(
                get: { settingsErrorMessage != nil },
                set: { if !$0 { settingsErrorMessage = nil } }
            )
        ) {
            Button("OK") { settingsErrorMessage = nil }
        } message: {
            Text(settingsErrorMessage ?? "Try again.")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private func finishSetup() {
        guard !isFinishingSetup else { return }
        isFinishingSetup = true
        PingWardenMonitor.shared.registerHelper { success in
            Task { @MainActor in
                guard success else {
                    isFinishingSetup = false
                    settingsErrorMessage = "Ping Warden is still waiting for approval in System Settings → General → Login Items."
                    return
                }
                let enabled = await protectionExperience.setPersistentProtection(true)
                isFinishingSetup = false
                if !enabled {
                    settingsErrorMessage = protectionExperience.lastError
                        ?? "The helper was approved, but Ping Protection could not turn on. Run the helper test in Advanced settings."
                }
            }
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

// MARK: - License Settings Content

struct LicenseSettingsContent: View {
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var protectionExperience = ProtectionExperienceCoordinator.shared
    @State private var keyField = ""
    @State private var licenseMessage: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: license.canEnableProtection ? "checkmark.seal.fill" : "seal")
                            .foregroundStyle(license.canEnableProtection ? .green : .secondary)
                            .accessibilityHidden(true)
                        Text(license.hasValidPaidLicense ? "Licensed" : (license.isGrandfathered ? "Free Transition" : "Unlicensed"))
                            .font(.headline)
                    }

                    Text(statusCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Ping Protection License")
            } footer: {
                Text("Ping Warden is open source, and everything except enabling Ping Protection is free. A license keeps AWDL blocking available and supports development.")
            }

            if license.isGrandfathered {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        if let days = license.grandfatherDaysRemaining {
                            Text("Ping Warden is moving to a paid model for the AWDL blocking feature. As an existing user, this Mac keeps full Ping Protection for \(days) more days, free and with no action needed.")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Ping Warden is moving to a paid model for the AWDL blocking feature. As an existing user, this Mac keeps full Ping Protection during a 90-day transition, free and with no action needed.")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("After the transition ends, a $15 one-time license keeps Ping Protection available. Everything else in the app stays free, and the source remains open under MIT.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("If you donated through the Buy Me a Coffee link before this release, thank you. Email \(LicenseManager.donationConversionEmail) and that support will be honored as a full license.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Email \(LicenseManager.donationConversionEmail)") {
                            NSWorkspace.shared.open(URL(string: "mailto:\(LicenseManager.donationConversionEmail)?subject=Ping%20Warden%20license%20from%20donation")!)
                        }
                        .controlSize(.small)
                    }
                } header: {
                    Text("Transition Period")
                } footer: {
                    Text("Enter a license key below any time during the transition. Nothing changes until it ends.")
                }

                Section("Enter License Key") {
                    SecureField("License key", text: $keyField)
                        .accessibilityLabel("License key")

                    HStack {
                        Button {
                            Task {
                                let entitled = await license.verify(key: keyField)
                                licenseMessage = entitled
                                    ? "License verified. Ping Protection is available."
                                    : licenseMessageForLastResult
                                if entitled { keyField = "" }
                            }
                        } label: {
                            if license.isVerifying {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Verify")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(license.isVerifying || keyField.trimmingCharacters(in: .whitespaces).isEmpty)

                        Button("Buy a License...") {
                            NSWorkspace.shared.open(LicenseManager.purchaseURL)
                        }
                    }

                    if let licenseMessage {
                        Label(licenseMessage, systemImage: messageIcon)
                            .font(.caption)
                            .foregroundStyle(messageIsError ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if !license.canEnableProtection {
                Section("Enter License Key") {
                    SecureField("License key", text: $keyField)
                        .accessibilityLabel("License key")

                    HStack {
                        Button {
                            Task {
                                let entitled = await license.verify(key: keyField)
                                licenseMessage = entitled
                                    ? "License verified. Ping Protection is available."
                                    : licenseMessageForLastResult
                                if entitled { keyField = "" }
                            }
                        } label: {
                            if license.isVerifying {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Verify")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(license.isVerifying || keyField.trimmingCharacters(in: .whitespaces).isEmpty)

                        Button("Buy a License...") {
                            NSWorkspace.shared.open(LicenseManager.purchaseURL)
                        }
                    }

                    if let licenseMessage {
                        Label(licenseMessage, systemImage: messageIcon)
                            .font(.caption)
                            .foregroundStyle(messageIsError ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("If you donated through the Buy Me a Coffee link before this release, thank you. Email \(LicenseManager.donationConversionEmail) and that support will be honored as a full license.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Email \(LicenseManager.donationConversionEmail)") {
                            NSWorkspace.shared.open(URL(string: "mailto:\(LicenseManager.donationConversionEmail)?subject=Ping%20Warden%20license%20from%20donation")!)
                        }
                        .controlSize(.small)
                    }
                } header: {
                    Text("Donated Before?")
                }
            }

            if let error = protectionExperience.lastError,
               error.contains("license") {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statusCaption: String {
        if license.isGrandfathered {
            return "Full Ping Protection continues free during the transition period."
        }
        if license.canEnableProtection {
            return "Ping Protection is available on this Mac."
        }
        return "Enter a license key to enable Ping Protection."
    }

    private var licenseMessageForLastResult: String {
        switch license.lastVerificationResult {
        case .revoked:
            return "This license key is not valid (refunded, cancelled, or disabled)."
        case .invalidKey:
            return "That key does not look like a Gumroad license key. Check it and try again."
        case .unreachable:
            return "Gumroad could not be reached. Connect to the internet and try again."
        case .valid, .none:
            return "The license could not be verified."
        }
    }

    private var messageIcon: String {
        if case .valid = license.lastVerificationResult { return "checkmark.circle.fill" }
        return "exclamationmark.triangle.fill"
    }

    private var messageIsError: Bool {
        if case .valid = license.lastVerificationResult { return false }
        return true
    }
}

// MARK: - Automation Settings Content

struct AutomationSettingsContent: View {
    @State private var gameModeAutoDetect = PingWardenPreferences.shared.gameModeAutoDetect
    @State private var controlCenterEnabled = PingWardenPreferences.shared.controlCenterWidgetEnabled
    @State private var controlCenterAvailability = ControlCenterSupport.availabilityForCurrentApp()
    @State private var screenRecordingPermissionGranted = GameModeDetector.hasScreenRecordingPermission()
    @State private var showingControlCenterConfirm = false
    @State private var showingScreenRecordingPermissionAlert = false

    var body: some View {
        Form {
            Section("Game Mode") {
                Toggle(isOn: $gameModeAutoDetect) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Game Mode Auto-Detect")
                            if !screenRecordingPermissionGranted {
                                StatusBadge(text: "Needs Permission", tint: .unavailable)
                            }
                        }
                        Text("Turn on protection and record a local latency session while a recognized game is fullscreen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Game Mode Auto-Detect")
                .accessibilityHint("Uses visible window metadata to recognize fullscreen games and never captures or saves screen contents")
                .onChangeCompat(of: gameModeAutoDetect) { newValue in
                    screenRecordingPermissionGranted = GameModeDetector.hasScreenRecordingPermission()
                    guard !newValue || screenRecordingPermissionGranted else {
                        gameModeAutoDetect = false
                        PingWardenPreferences.shared.gameModeAutoDetect = false
                        showingScreenRecordingPermissionAlert = true
                        return
                    }
                    PingWardenPreferences.shared.gameModeAutoDetect = newValue
                }
            }

            Section {
                Toggle(isOn: $controlCenterEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Hide Menu Bar Icon")
                            if !controlCenterAvailability.isAvailable {
                                StatusBadge(text: controlCenterAvailability.statusText, tint: .unavailable)
                            }
                        }
                        Text(controlCenterAvailability.detailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Hide Menu Bar Icon")
                .accessibilityHint("Keeps Ping Warden in the Dock and uses the Control Center toggle instead of the menu bar icon")
                .disabled(!controlCenterAvailability.isAvailable)
                .onChangeCompat(of: controlCenterEnabled) { newValue in
                    if newValue {
                        showingControlCenterConfirm = true
                    } else {
                        PingWardenPreferences.shared.controlCenterWidgetEnabled = false
                    }
                }
            } header: {
                Text("Interface")
            } footer: {
                // Section footer carries the conditional help text. EmptyView()
                // collapses the footer when there's nothing relevant to say.
                if controlCenterAvailability.isAvailable && controlCenterEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(controlCenterAvailability.footerText)
                        Text("Ping Warden stays in the Dock so settings remain available.")
                    }
                } else if !controlCenterAvailability.isAvailable {
                    Text(controlCenterAvailability.footerText)
                } else {
                    EmptyView()
                }
            }
        }
        .formStyle(.grouped)
        .settingsScrollEdgeTreatment()
        .onAppear {
            refreshAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAvailability()
        }
        .alert("Screen Recording Permission Needed", isPresented: $showingScreenRecordingPermissionAlert) {
            Button("Open System Settings") {
                GameModeDetector.openScreenRecordingSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Game Mode auto-detect reads app and window metadata to identify fullscreen games. It never captures or saves screen contents.")
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
            Text("The menu bar icon will be hidden, and Ping Warden will stay visible in the Dock. Add the Ping Protection control in System Settings if it is not already in Control Center.")
        }
    }

    private func refreshAvailability() {
        controlCenterAvailability = ControlCenterSupport.availabilityForCurrentApp()
        screenRecordingPermissionGranted = GameModeDetector.hasScreenRecordingPermission()
    }
}

// MARK: - Advanced Settings Content

struct AdvancedSettingsContent: View {
    private struct DiagnosticsSheetResult: Identifiable {
        let id = UUID()
        let export: DiagnosticsExporter.ExportResult
    }

    @ObservedObject private var protectionExperience = ProtectionExperienceCoordinator.shared
    @State private var showingRepairConfirm = false
    @State private var showingRemovalConfirm = false
    @State private var showingTestResults = false
    @State private var testResults = ""
    @State private var diagnosticsResult: DiagnosticsSheetResult?
    @State private var isRunningHelperTest = false
    @State private var isExportingDiagnostics = false
    @State private var maintenanceErrorMessage: String?
    @State private var crashReportingRelaunchRequired = false
    @State private var crashReportingEnabled = PingWardenPreferences.shared.isCrashReportingEnabled
    @State private var betaChannelEnabled = PingWardenPreferences.shared.betaChannelEnabled

    var body: some View {
        Form {
            Section("Privacy") {
                Toggle(isOn: $crashReportingEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Send Crash Reports")
                            if crashReportingRelaunchRequired {
                                StatusBadge(text: "Relaunch Required", tint: .unavailable)
                            }
                        }
                        Text("Anonymous crash reports help fix bugs. No IP address, usage data, or ping targets. Turning off is immediate; turning on requires a relaunch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Send Crash Reports")
                .accessibilityHint("Sends anonymous crash details without IP addresses, usage data, or ping targets")
                .onChangeCompat(of: crashReportingEnabled) { newValue in
                    PingWardenPreferences.shared.isCrashReportingEnabled = newValue
                    crashReportingRelaunchRequired = newValue
                }
            }

            Section("Updates") {
                Toggle(isOn: $betaChannelEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Receive Beta Updates")
                        Text("Opt in to pre-release builds. Betas may have bugs and are released ahead of the stable channel. Takes effect at the next update check.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Receive Beta Updates")
                .accessibilityHint("Switches future update checks between the stable and pre-release channels")
                .onChangeCompat(of: betaChannelEnabled) { newValue in
                    PingWardenPreferences.shared.betaChannelEnabled = newValue
                }
            }

            Section("Diagnostics") {
                LabeledContent {
                    Button {
                        runHelperTest()
                    } label: {
                        if isRunningHelperTest {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Run Test")
                        }
                    }
                        .buttonStyle(.bordered)
                        .disabled(isRunningHelperTest)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Test Helper Connection")
                        Text("Verify the registered helper and signed XPC connection")
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
                    Button {
                        exportDiagnostics()
                    } label: {
                        if isExportingDiagnostics {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Create Snapshot")
                        }
                    }
                        .buttonStyle(.bordered)
                        .disabled(isExportingDiagnostics)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Diagnostics Snapshot")
                        Text("Create a private local text file for troubleshooting")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Maintenance") {
                LabeledContent {
                    Button("Repair...") { showingRepairConfirm = true }
                        .buttonStyle(.bordered)
                        .disabled(protectionExperience.isBusy)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Repair Helper Connection")
                        Text("Reconnect the approved helper without changing your protection preference")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Button("Prepare to Remove...") { showingRemovalConfirm = true }
                        .buttonStyle(.bordered)
                        .tint(.red)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remove Ping Warden")
                        Text("Turn off protection, unregister the helper, clear local data, and quit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .settingsScrollEdgeTreatment()
        .confirmationDialog(
            "Repair Helper Connection?",
            isPresented: $showingRepairConfirm,
            titleVisibility: .visible
        ) {
            Button("Repair") {
                repairHelperConnection()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Ping Warden will reconnect to the approved helper and restore your current protection preference. It will not erase settings or session history.")
        }
        .confirmationDialog(
            "Prepare Ping Warden for Removal?",
            isPresented: $showingRemovalConfirm,
            titleVisibility: .visible
        ) {
            Button("Prepare to Remove", role: .destructive) {
                prepareForRemoval()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This turns off Ping Protection, unregisters the helper and Launch at Login, clears settings, custom servers, and latency session history, reveals the app in Finder, then quits. The app will remain in Applications until you move it to Trash.")
        }
        .alert("Helper Test Results", isPresented: $showingTestResults) {
            Button("OK") {}
        } message: {
            Text(testResults)
        }
        .sheet(item: $diagnosticsResult) { result in
            DiagnosticsResultView(result: result.export) {
                diagnosticsResult = nil
            }
        }
        .alert(
            "Maintenance Could Not Finish",
            isPresented: Binding(
                get: { maintenanceErrorMessage != nil },
                set: { if !$0 { maintenanceErrorMessage = nil } }
            )
        ) {
            Button("OK") { maintenanceErrorMessage = nil }
        } message: {
            Text(maintenanceErrorMessage ?? "Try again.")
        }
    }

    private func runHelperTest() {
        guard !isRunningHelperTest else { return }
        isRunningHelperTest = true
        DispatchQueue.global(qos: .userInitiated).async {
            let healthCheck = PingWardenMonitor.shared.performHealthCheck()

            DispatchQueue.main.async {
                isRunningHelperTest = false
                if !healthCheck.isHealthy {
                    self.testResults = "Helper test failed:\n\(healthCheck.message)"
                    self.showingTestResults = true
                    return
                }

                self.testResults = healthCheck.message
                self.showingTestResults = true
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
        guard !isExportingDiagnostics else { return }
        isExportingDiagnostics = true
        DispatchQueue.global(qos: .utility).async {
            let result = DiagnosticsExporter.exportSnapshot()
            DispatchQueue.main.async {
                isExportingDiagnostics = false
                guard let result else {
                    maintenanceErrorMessage = "The diagnostics snapshot could not be created on the Desktop or in the temporary folder."
                    return
                }

                diagnosticsResult = DiagnosticsSheetResult(export: result)
            }
        }
    }

    private func repairHelperConnection() {
        let shouldRemainEnabled = PingWardenPreferences.shared.isMonitoringEnabled
        PingWardenMonitor.shared.registerHelper { success in
            Task { @MainActor in
                guard success else {
                    maintenanceErrorMessage = "The helper could not reconnect. Confirm that Ping Warden is allowed in System Settings → General → Login Items, then run the helper test."
                    return
                }
                let restored = await protectionExperience.setPersistentProtection(shouldRemainEnabled)
                if !restored {
                    maintenanceErrorMessage = "The helper reconnected, but Ping Warden could not restore your protection preference."
                }
            }
        }
    }

    private func prepareForRemoval() {
        settingsLog.info("Preparing Ping Warden for removal")
        Task { @MainActor in
            let previousProtectionEnabled = PingWardenPreferences.shared.isMonitoringEnabled
            let launchAtLoginWasEnabled = SMAppService.mainApp.status == .enabled
            let helperService = SMAppService.daemon(
                plistName: "com.amesvt.pingwarden.helper.plist"
            )
            let helperWasEnabled = helperService.status == .enabled

            let stopped = await protectionExperience.setPersistentProtection(false)
            guard stopped else {
                maintenanceErrorMessage = "Ping Protection could not be turned off, so no settings were erased. Quit Ping Warden to restore wireless sharing, then try again."
                return
            }

            do {
                if SMAppService.mainApp.status == .enabled {
                    try await SMAppService.mainApp.unregister()
                }
            } catch {
                settingsLog.error("Launch at Login unregister failed: \(error.localizedDescription)")
                let restored = await restoreRemovalState(
                    protectionEnabled: previousProtectionEnabled,
                    restoreLaunchAtLogin: false,
                    restoreHelper: false
                )
                maintenanceErrorMessage = removalFailureMessage(
                    "Launch at Login could not be unregistered. \(error.localizedDescription)",
                    restored: restored
                )
                return
            }

            do {
                if helperWasEnabled {
                    try await helperService.unregister()
                    settingsLog.info("Helper unregistered successfully")
                }
            } catch {
                settingsLog.error("Helper unregister failed: \(error.localizedDescription)")
                let restored = await restoreRemovalState(
                    protectionEnabled: previousProtectionEnabled,
                    restoreLaunchAtLogin: launchAtLoginWasEnabled,
                    restoreHelper: false
                )
                maintenanceErrorMessage = removalFailureMessage(
                    "The helper could not be unregistered. \(error.localizedDescription)",
                    restored: restored
                )
                return
            }

            do {
                try clearLocalDataForRemoval()
            } catch {
                settingsLog.error("Local data removal failed: \(error.localizedDescription)")
                let restored = await restoreRemovalState(
                    protectionEnabled: previousProtectionEnabled,
                    restoreLaunchAtLogin: launchAtLoginWasEnabled,
                    restoreHelper: helperWasEnabled
                )
                maintenanceErrorMessage = removalFailureMessage(
                    "Ping Warden could not clear its latency session history. \(error.localizedDescription)",
                    restored: restored
                )
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    @MainActor
    private func restoreRemovalState(
        protectionEnabled: Bool,
        restoreLaunchAtLogin: Bool,
        restoreHelper: Bool
    ) async -> Bool {
        var restored = true

        if restoreLaunchAtLogin, SMAppService.mainApp.status != .enabled {
            do {
                try SMAppService.mainApp.register()
            } catch {
                settingsLog.error("Launch at Login rollback failed: \(error.localizedDescription)")
                restored = false
            }
        }

        if restoreHelper {
            let helperService = SMAppService.daemon(
                plistName: "com.amesvt.pingwarden.helper.plist"
            )
            if helperService.status != .enabled {
                do {
                    try helperService.register()
                } catch {
                    settingsLog.error("Helper rollback failed: \(error.localizedDescription)")
                    restored = false
                }
            }

            if helperService.status == .enabled {
                let connected = await withCheckedContinuation { continuation in
                    PingWardenMonitor.shared.registerHelper { success in
                        continuation.resume(returning: success)
                    }
                }
                restored = connected && restored
            } else {
                restored = false
            }
        }

        let protectionRestored = await protectionExperience.setPersistentProtection(
            protectionEnabled
        )
        return protectionRestored && restored
    }

    private func removalFailureMessage(_ cause: String, restored: Bool) -> String {
        if restored {
            return "\(cause) Your previous Ping Warden settings were restored, and no local data was erased."
        }
        return "\(cause) Ping Warden could not fully restore the prior state. Open Ping Warden again, run the helper test, and review Launch at Login before retrying. No local data was erased."
    }

    private func clearLocalDataForRemoval() throws {
        // App Group preferences survive app deletion, so clear them only after
        // the helper has been turned off and unregistered successfully.
        try ProtectedSessionStore().removeAll()
        LicenseManager.shared.resetForRemoval()
        PingWardenPreferences.shared.resetForRemoval()
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }
}

private struct DiagnosticsResultView: View {
    let result: DiagnosticsExporter.ExportResult
    let onDone: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Diagnostics Snapshot Created")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(result.fileURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            ScrollView {
                Text(result.contents)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button(copied ? "Copied" : "Copy Contents") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.contents, forType: .string)
                    copied = true
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.fileURL])
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 560)
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
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 28)

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
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                Spacer(minLength: 28)

                Text("Local network protection and measurement for macOS")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 28)

                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        aboutDonateButton
                        aboutDocumentationLink
                        aboutIssueLink
                    }

                    VStack(spacing: 8) {
                        aboutDonateButton
                        aboutDocumentationLink
                        aboutIssueLink
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.top, 12)

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
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 4) {
                        Link("james-howard/AWDLControl", destination: URL(string: "https://github.com/james-howard/AWDLControl") ?? URL(fileURLWithPath: "/"))
                            .font(.caption)

                        Text("SMAppService + XPC architecture")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 12)

                Text("© 2025-2026 Oliver Ames")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 420, idealHeight: 480)
        .background(.regularMaterial)
    }

    private var aboutDonateButton: some View {
        Button("Donate") {
            openURL(URL(string: "https://buymeacoffee.com/oliverames")!)
        }
    }

    private var aboutDocumentationLink: some View {
        Link(
            "Documentation",
            destination: URL(string: "https://github.com/oliverames/ping-warden#readme")!
        )
    }

    private var aboutIssueLink: some View {
        Link(
            "Report an Issue",
            destination: URL(string: "https://github.com/oliverames/ping-warden/issues/new/choose")!
        )
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
final class GameModeDetector: @unchecked Sendable {
    private let detectionQueue = DispatchQueue(
        label: "com.amesvt.pingwarden.game-mode-detection",
        qos: .utility
    )
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    private var isGameModeActive = false
    private var hasLoggedPermissionWarning = false
    private let log = Logger(subsystem: "com.amesvt.pingwarden", category: "GameMode")
    /// Cache of pid → isGame to avoid re-reading Info.plist every 2 seconds.
    /// Entries are evicted via `appDidTerminateObserver` so the cache cannot
    /// outgrow the set of currently-running apps for the session.
    private var gameCheckCache: [pid_t: Bool] = [:]
    private var appDidTerminateObserver: NSObjectProtocol?
    private var appDidActivateObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var inactiveFullscreenSamples = 0
    private var idleStreakTicks = 0

    private static let ignoredFullscreenOwners: Set<String> = [
        "Finder",
        "Dock",
        "Window Server",
        "SystemUIServer",
        "Control Center",
        "Notification Center"
    ]

    var onGameModeChange: ((Bool) -> Void)?

    deinit {
        timer?.cancel()
        if let observer = appDidTerminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = appDidActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = screenParametersObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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
        if !Self.hasScreenRecordingPermission() {
            log.warning("Screen Recording permission not granted - Game Mode detection may not work correctly")
            if !hasLoggedPermissionWarning {
                hasLoggedPermissionWarning = true
                // Only show alert once per app session
                showScreenRecordingPermissionAlert()
            }
        }

        detectionQueue.async { [weak self] in
            guard let self else { return }
            self.isRunning = true
            self.checkGameModeStatus()
            self.scheduleSafetyTimer()
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
                self?.detectionQueue.async { [weak self] in
                    self?.gameCheckCache.removeValue(forKey: pid)
                }
            }
        }

        if appDidActivateObserver == nil {
            appDidActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleGameModeStatusCheck()
            }
        }

        if screenParametersObserver == nil {
            screenParametersObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleGameModeStatusCheck()
            }
        }
    }

    func stop() {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { [weak self] in self?.stop() }
            return
        }

        if let observer = appDidTerminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appDidTerminateObserver = nil
        }

        if let observer = appDidActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appDidActivateObserver = nil
        }

        if let observer = screenParametersObserver {
            NotificationCenter.default.removeObserver(observer)
            screenParametersObserver = nil
        }

        detectionQueue.sync {
            isRunning = false
            timer?.cancel()
            timer = nil
            gameCheckCache.removeAll()
            inactiveFullscreenSamples = 0
            idleStreakTicks = 0

            if isGameModeActive {
                isGameModeActive = false
                DispatchQueue.main.async { [weak self] in
                    self?.onGameModeChange?(false)
                }
            }
        }
    }

    /// Check if Screen Recording permission is granted
    /// CGWindowListCopyWindowInfo requires this permission on macOS 10.15+ to get window names
    static func hasScreenRecordingPermission() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Show alert explaining Screen Recording permission is needed
    private func showScreenRecordingPermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Screen Recording Permission Needed"
            alert.informativeText = "Game Mode auto-detect reads app and window metadata to identify fullscreen games. It never captures or saves screen contents."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                Self.openScreenRecordingSettings()
            }
        }
    }

    private func scheduleGameModeStatusCheck() {
        detectionQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            // An activation or display change means the user just did
            // something; drop back to the responsive polling tier.
            self.idleStreakTicks = 0
            self.checkGameModeStatus()
        }
    }

    private func scheduleSafetyTimer() {
        dispatchPrecondition(condition: .onQueue(detectionQueue))
        timer?.cancel()

        let interval = GameModePollingPolicy.interval(
            isActive: isGameModeActive,
            idleStreakTicks: idleStreakTicks
        )
        let newTimer = DispatchSource.makeTimerSource(queue: detectionQueue)
        newTimer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(Int(interval * 100))
        )
        newTimer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }
            self.checkGameModeStatus()
        }
        timer = newTimer
        newTimer.resume()
    }

    private func checkGameModeStatus() {
        dispatchPrecondition(condition: .onQueue(detectionQueue))
        let isFullscreen = isAnyAppFullscreen()

        if isFullscreen {
            inactiveFullscreenSamples = 0
            idleStreakTicks = 0
            if !isGameModeActive {
                isGameModeActive = true
                log.info("Game Mode detected: true")
                scheduleSafetyTimer()
                DispatchQueue.main.async { [weak self] in
                    self?.onGameModeChange?(true)
                }
            }
            return
        }

        guard isGameModeActive else {
            inactiveFullscreenSamples = 0
            idleStreakTicks += 1
            // Recreate the repeating timer so a streak crossing the idle
            // threshold takes effect on the very next tick.
            scheduleSafetyTimer()
            return
        }

        inactiveFullscreenSamples += 1
        idleStreakTicks += 1
        guard inactiveFullscreenSamples >= 2 else {
            return
        }

        inactiveFullscreenSamples = 0
        isGameModeActive = false
        log.info("Game Mode detected: false")
        scheduleSafetyTimer()
        DispatchQueue.main.async { [weak self] in
            self?.onGameModeChange?(false)
        }
    }

    private func isAnyAppFullscreen() -> Bool {
        let displayBounds = Self.activeDisplayBounds()
        guard !displayBounds.isEmpty else { return false }

        // Get list of windows on screen
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for window in windowList {
            // Fullscreen app content should be a normal app window. Higher
            // layers are menu extras, overlays, panels, or system UI.
            guard let layer = window[kCGWindowLayer as String] as? Int32,
                  layer == 0 else {
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

            // Check if window covers an active display.
            if Self.windowFrameCoversAnyDisplay(windowFrame, displayBounds: displayBounds) {
                // Get owner name and PID
                guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                      let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t else {
                    continue
                }

                guard ownerPID != ProcessInfo.processInfo.processIdentifier else {
                    continue
                }

                // Skip system apps that commonly go fullscreen
                if Self.ignoredFullscreenOwners.contains(ownerName) {
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

    private static func activeDisplayBounds() -> [CGRect] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else { return [] }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else { return [] }

        return displays.prefix(Int(displayCount)).map { CGDisplayBounds($0) }
    }

    private static func windowFrameCoversAnyDisplay(_ windowFrame: CGRect, displayBounds: [CGRect]) -> Bool {
        displayBounds.contains { displayFrame in
            let intersection = windowFrame.intersection(displayFrame)
            guard !intersection.isNull, !intersection.isEmpty else {
                return false
            }
            return intersection.width >= displayFrame.width * 0.95 &&
                   intersection.height >= displayFrame.height * 0.95
        }
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

        // Check LSApplicationCategoryType for game category. The generic
        // category is "public.app-category.games", but most titles declare a
        // subcategory like "public.app-category.action-games" or
        // "public.app-category.role-playing-games" — those end in "-games"
        // and do NOT share the generic prefix, so match both shapes.
        if let categoryType = infoPlist["LSApplicationCategoryType"] as? String {
            let isGameCategory = categoryType == "public.app-category.games" ||
                (categoryType.hasPrefix("public.app-category.") && categoryType.hasSuffix("-games"))
            if isGameCategory {
                log.debug("App \(bundleURL.lastPathComponent) has game category (\(categoryType))")
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

#Preview("License Settings") {
    LicenseSettingsContent()
        .frame(width: 450, height: 350)
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
    WelcomeView(
        onSetup: { completion in completion(true) },
        onOpenDashboard: {},
        onDismiss: {}
    )
}
