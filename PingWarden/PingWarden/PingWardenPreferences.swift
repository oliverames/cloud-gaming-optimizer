//
//  PingWardenPreferences.swift
//  PingWarden
//
//  Manages shared state between app and widget using App Groups.
//
//  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
//  Licensed under the MIT License.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.amesvt.pingwarden", category: "Preferences")

/// Manages shared state between app and widget using App Groups
final class PingWardenPreferences: @unchecked Sendable {
    static let shared = PingWardenPreferences()

    private let appGroupID = "group.com.amesvt.pingwarden"
    private let monitoringEnabledKey = "AWDLMonitoringEnabled" // User intent
    private let effectiveMonitoringEnabledKey = "AWDLEffectiveMonitoringEnabled" // Runtime state
    private let lastStateKey = "AWDLLastState"
    private let controlCenterEnabledKey = "ControlCenterWidgetEnabled"
    private let gameModeAutoDetectKey = "GameModeAutoDetect"
    private let showDockIconKey = "ShowDockIcon"
    private let showMenuDropdownMetricsKey = "ShowMenuDropdownMetrics"
    private let donationLastSeenVersionKey = "DonationPromptLastSeenVersion"
    private let donationDismissedPermanentlyKey = "DonationPromptDismissedPermanently"
    private let crashReportingEnabledKey = "CrashReportingEnabled"
    private let betaChannelEnabledKey = "BetaChannelEnabled"

    /// Shared App Group defaults handle, exposed so non-singleton consumers
    /// (CustomPingTargetStore, tests, future widget targets) can re-use the
    /// same suite without duplicating the suite name.
    let defaults: UserDefaults

    private init() {
        if let suite = UserDefaults(suiteName: appGroupID) {
            log.debug("Successfully connected to App Group suite")
            defaults = suite
        } else {
            log.error("Failed to create App Group suite, using standard defaults")
            defaults = UserDefaults.standard
        }

        // Per-app defaults. `register` only applies when the key has never
        // been written by the user, so toggling crash reporting off in the
        // UI persists across launches; only fresh installs (or users on
        // v2.3.0 launching v2.3.1 for the first time) see the default.
        defaults.register(defaults: [
            crashReportingEnabledKey: true,
        ])
    }

    /// User intent for whether AWDL monitoring should be enabled.
    /// This is shared with the widget.
    var isMonitoringEnabled: Bool {
        get { defaults.bool(forKey: monitoringEnabledKey) }
        set {
            defaults.set(newValue, forKey: monitoringEnabledKey)
            DistributedNotificationCenter.default().postNotificationName(
                .awdlMonitoringStateChanged,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }

    /// Effective runtime state of monitoring as reported by the app/helper.
    /// This value is used for accurate status display and should not be used as user intent.
    var effectiveMonitoringEnabled: Bool {
        get { defaults.bool(forKey: effectiveMonitoringEnabledKey) }
        set {
            defaults.set(newValue, forKey: effectiveMonitoringEnabledKey)
            DistributedNotificationCenter.default().postNotificationName(
                .awdlEffectiveMonitoringStateChanged,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            NotificationCenter.default.post(name: .awdlMonitorStateChanged, object: nil)
        }
    }

    /// Last known AWDL state (for widget display)
    var lastKnownState: String {
        get { defaults.string(forKey: lastStateKey) ?? "unknown" }
        set { defaults.set(newValue, forKey: lastStateKey) }
    }

    /// Whether Control Center widget mode is enabled (hides menu bar icon)
    var controlCenterWidgetEnabled: Bool {
        get { defaults.bool(forKey: controlCenterEnabledKey) }
        set {
            defaults.set(newValue, forKey: controlCenterEnabledKey)
            NotificationCenter.default.post(name: .controlCenterModeChanged, object: nil)
        }
    }

    /// Whether to auto-enable AWDL blocking when Game Mode is active
    var gameModeAutoDetect: Bool {
        get { defaults.bool(forKey: gameModeAutoDetectKey) }
        set {
            defaults.set(newValue, forKey: gameModeAutoDetectKey)
            NotificationCenter.default.post(name: .gameModeAutoDetectChanged, object: nil)
        }
    }

    /// Whether to show the app icon in the Dock
    var showDockIcon: Bool {
        get { defaults.bool(forKey: showDockIconKey) }
        set {
            defaults.set(newValue, forKey: showDockIconKey)
            NotificationCenter.default.post(name: .dockIconVisibilityChanged, object: nil)
        }
    }

    /// Whether to show live ping and intervention metrics in the menu bar dropdown
    var showMenuDropdownMetrics: Bool {
        get { defaults.bool(forKey: showMenuDropdownMetricsKey) }
        set {
            defaults.set(newValue, forKey: showMenuDropdownMetricsKey)
            NotificationCenter.default.post(name: .menuDropdownMetricsChanged, object: nil)
        }
    }

    /// Last `CFBundleShortVersionString` for which the donation prompt was
    /// shown (or postponed via "Maybe later"). `nil` until the very first
    /// time the prompt would have fired.
    var donationPromptLastSeenVersion: String? {
        get { defaults.string(forKey: donationLastSeenVersionKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: donationLastSeenVersionKey)
            } else {
                defaults.removeObject(forKey: donationLastSeenVersionKey)
            }
        }
    }

    /// User-set kill switch. Once true, the donation prompt never fires
    /// again on this Mac for any future version. Reset by `performUninstall`.
    var donationPromptDismissedPermanently: Bool {
        get { defaults.bool(forKey: donationDismissedPermanentlyKey) }
        set { defaults.set(newValue, forKey: donationDismissedPermanentlyKey) }
    }

    /// Crash reporting via Sentry. Default `true` — anonymous data only
    /// (no IP, no network targets, no usage telemetry, no session events).
    /// The default is registered in `init` so existing users who have not
    /// explicitly toggled the setting also get crash reporting on first
    /// launch of v2.3.1; explicit user choices persist. Toggled in
    /// Settings → Advanced → Privacy; applied at next launch. Reset to
    /// the registered default by `performUninstall`.
    var isCrashReportingEnabled: Bool {
        get { defaults.bool(forKey: crashReportingEnabledKey) }
        set { defaults.set(newValue, forKey: crashReportingEnabledKey) }
    }

    /// Opt-in beta channel for Sparkle updates. Default `false` — when
    /// enabled, Sparkle pulls from `appcast-beta.xml` instead of the stable
    /// `appcast.xml`. Toggled in Settings → Advanced → Updates; takes effect
    /// on the next update check (no restart required because the
    /// `SPUUpdaterDelegate.feedURLString(for:)` callback fires every check).
    var betaChannelEnabled: Bool {
        get { defaults.bool(forKey: betaChannelEnabledKey) }
        set { defaults.set(newValue, forKey: betaChannelEnabledKey) }
    }
}

extension Notification.Name {
    // Use namespaced notification names to avoid collisions with other apps
    static let awdlMonitoringStateChanged = Notification.Name("com.amesvt.pingwarden.notification.MonitoringStateChanged")
    static let awdlEffectiveMonitoringStateChanged = Notification.Name("com.amesvt.pingwarden.notification.EffectiveMonitoringStateChanged")
    static let awdlMonitorStateChanged = Notification.Name("com.amesvt.pingwarden.notification.MonitorStateChanged")
    static let controlCenterModeChanged = Notification.Name("com.amesvt.pingwarden.notification.ControlCenterModeChanged")
    static let gameModeAutoDetectChanged = Notification.Name("com.amesvt.pingwarden.notification.GameModeAutoDetectChanged")
    static let dockIconVisibilityChanged = Notification.Name("com.amesvt.pingwarden.notification.DockIconVisibilityChanged")
    static let menuDropdownMetricsChanged = Notification.Name("com.amesvt.pingwarden.notification.MenuDropdownMetricsChanged")
}
