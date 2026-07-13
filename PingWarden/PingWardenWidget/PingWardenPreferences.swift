//
//  PingWardenPreferences.swift
//  PingWardenWidget
//
//  Manages shared state between app and widget using App Groups.
//
//  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
//  Licensed under the MIT License.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.amesvt.pingwarden", category: "WidgetPreferences")

/// Manages shared state between app and widget using App Groups
/// Note: This file should be kept in sync with PingWarden/PingWardenPreferences.swift
/// The widget only uses isMonitoringEnabled and lastKnownState, but all properties
/// are included for consistency and to ensure key names match.
final class PingWardenPreferences: @unchecked Sendable {
    static let shared = PingWardenPreferences()

    private let appGroupID = "group.com.amesvt.pingwarden"
    private let monitoringEnabledKey = "AWDLMonitoringEnabled"
    private let effectiveMonitoringEnabledKey = "AWDLEffectiveMonitoringEnabled"
    private let lastStateKey = "AWDLLastState"
    private let controlCenterEnabledKey = "ControlCenterWidgetEnabled"
    private let gameModeAutoDetectKey = "GameModeAutoDetect"
    private let showDockIconKey = "ShowDockIcon"
    private let showMenuDropdownMetricsKey = "ShowMenuDropdownMetrics"

    // Assigned once in init (a `lazy var` is not thread-safe and the async
    // intent perform() can race control rendering on first access).
    private let defaults: UserDefaults?

    /// True when the shared App Group suite is in use. When false, the widget
    /// and the main app are reading *different* defaults domains — writes
    /// from here would appear to succeed while the app never sees them, so
    /// intent handlers must surface an error instead of proceeding.
    let usesAppGroupSuite: Bool

    private init() {
        if let suite = UserDefaults(suiteName: appGroupID) {
            log.debug("Successfully connected to App Group suite")
            defaults = suite
            usesAppGroupSuite = true
        } else {
            // Fallback to standard defaults if app group fails
            // This matches the main app's behavior for consistency
            log.error("Failed to create App Group suite, using standard defaults")
            defaults = UserDefaults.standard
            usesAppGroupSuite = false
        }
    }

    /// Whether continuous AWDL monitoring is enabled
    var isMonitoringEnabled: Bool {
        get {
            return defaults?.bool(forKey: monitoringEnabledKey) ?? false
        }
        set {
            guard let defaults = defaults else {
                log.error("Cannot set \(self.monitoringEnabledKey): defaults is nil")
                return
            }
            defaults.set(newValue, forKey: monitoringEnabledKey)
            // The App Intent applies the privileged operation over authenticated
            // XPC before publishing this display state. This setter deliberately
            // has no command side effect.
        }
    }

    /// Last known AWDL state (for widget display)
    var lastKnownState: String {
        get {
            return defaults?.string(forKey: lastStateKey) ?? "unknown"
        }
        set {
            guard let defaults = defaults else {
                log.error("Cannot set \(self.lastStateKey): defaults is nil")
                return
            }
            defaults.set(newValue, forKey: lastStateKey)
        }
    }

    /// Effective runtime monitoring state written by the main app.
    var effectiveMonitoringEnabled: Bool {
        get {
            return defaults?.bool(forKey: effectiveMonitoringEnabledKey) ?? false
        }
        set {
            guard let defaults = defaults else {
                log.error("Cannot set \(self.effectiveMonitoringEnabledKey): defaults is nil")
                return
            }
            defaults.set(newValue, forKey: effectiveMonitoringEnabledKey)
        }
    }

    /// Whether Control Center widget mode is enabled (hides menu bar icon)
    var controlCenterWidgetEnabled: Bool {
        get {
            return defaults?.bool(forKey: controlCenterEnabledKey) ?? false
        }
        set {
            guard let defaults = defaults else {
                log.error("Cannot set \(self.controlCenterEnabledKey): defaults is nil")
                return
            }
            defaults.set(newValue, forKey: controlCenterEnabledKey)
            // Note: Widget doesn't post this notification as it's only used by main app
        }
    }

    /// Whether to auto-enable AWDL blocking when Game Mode is active
    var gameModeAutoDetect: Bool {
        get {
            return defaults?.bool(forKey: gameModeAutoDetectKey) ?? false
        }
        set {
            guard let defaults = defaults else {
                log.error("Cannot set \(self.gameModeAutoDetectKey): defaults is nil")
                return
            }
            defaults.set(newValue, forKey: gameModeAutoDetectKey)
            // Note: Widget doesn't post this notification as it's only used by main app
        }
    }

    /// Whether to show the app icon in the Dock
    var showDockIcon: Bool {
        get {
            return defaults?.bool(forKey: showDockIconKey) ?? false
        }
        set {
            guard let defaults = defaults else {
                log.error("Cannot set \(self.showDockIconKey): defaults is nil")
                return
            }
            defaults.set(newValue, forKey: showDockIconKey)
            // Note: Widget doesn't post this notification as it's only used by main app
        }
    }

    /// Whether to show live metrics in the menu dropdown (main app preference)
    var showMenuDropdownMetrics: Bool {
        get {
            return defaults?.bool(forKey: showMenuDropdownMetricsKey) ?? false
        }
        set {
            guard let defaults = defaults else {
                log.error("Cannot set \(self.showMenuDropdownMetricsKey): defaults is nil")
                return
            }
            defaults.set(newValue, forKey: showMenuDropdownMetricsKey)
            // Note: Widget doesn't post this notification as it's only used by main app
        }
    }
}

extension Notification.Name {
    // Use a namespaced notification name to avoid collisions with other apps
    static let awdlMonitoringStateChanged = Notification.Name("com.amesvt.pingwarden.notification.MonitoringStateChanged")
    static let awdlEffectiveMonitoringStateChanged = Notification.Name("com.amesvt.pingwarden.notification.EffectiveMonitoringStateChanged")
    // These are defined in the main app but included here for reference:
    // static let controlCenterModeChanged = Notification.Name("com.amesvt.pingwarden.notification.ControlCenterModeChanged")
    // static let gameModeAutoDetectChanged = Notification.Name("com.amesvt.pingwarden.notification.GameModeAutoDetectChanged")
    // static let dockIconVisibilityChanged = Notification.Name("com.amesvt.pingwarden.notification.DockIconVisibilityChanged")
}
