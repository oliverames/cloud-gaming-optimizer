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

    private let appGroupID = "PV3W52NDZ3.com.amesvt.pingwarden"
    private let legacyAppGroupID = "group.com.amesvt.pingwarden"
    private let legacyMigrationKey = "LegacyAppGroupMigrationCompleted"
    private let monitoringEnabledKey = "AWDLMonitoringEnabled" // User intent
    private let effectiveMonitoringEnabledKey = "AWDLEffectiveMonitoringEnabled" // Runtime state
    private let lastStateKey = "AWDLLastState"
    private let controlCenterEnabledKey = "ControlCenterWidgetEnabled"
    private let gameModeAutoDetectKey = "GameModeAutoDetect"
    private let showDockIconKey = "ShowDockIcon"
    private let showMenuDropdownMetricsKey = "ShowMenuDropdownMetrics"
    private let donationLastSeenVersionKey = "DonationPromptLastSeenVersion"
    private let donationDismissedPermanentlyKey = "DonationPromptDismissedPermanently"
    private let supportLastPromptDateKey = "SupportPromptLastDate"
    private let supportOpenedDateKey = "SupportOpenedDate"
    private let completedSessionCountKey = "CompletedProtectedSessionCount"
    private let lifetimeInterventionCountKey = "LifetimeInterventionCount"
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

        migrateLegacyPreferencesIfAvailable()

        // `register` only applies when the key has never been written. Existing
        // choices persist, while new installations start with reporting off.
        defaults.register(defaults: [
            crashReportingEnabledKey: false,
        ])
    }

    /// macOS 15 began enforcing App Group authorization for non-sandboxed
    /// Developer ID apps. Ping Warden 2.x used an iOS-style `group.` ID without
    /// an embedded provisioning profile, so that container is not safely
    /// readable on macOS 15 and later. On macOS 13 and 14, copy any existing
    /// values directly before the old container becomes inaccessible.
    private func migrateLegacyPreferencesIfAvailable() {
        guard !defaults.bool(forKey: legacyMigrationKey) else { return }

        if #available(macOS 15.0, *) {
            defaults.set(true, forKey: legacyMigrationKey)
            return
        }

        do {
            let data = try Data(contentsOf: legacyPreferencesURL)
            guard let values = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else {
                log.warning("Legacy App Group preferences were not a dictionary")
                defaults.set(true, forKey: legacyMigrationKey)
                return
            }

            for (key, value) in values where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            log.info("Migrated \(values.count) legacy App Group preference values")
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            log.debug("No legacy App Group preferences found")
        } catch {
            // Do not block launch. Leaving the marker unset lets a future
            // launch retry after a transient read failure.
            log.warning("Legacy App Group migration failed: \(error.localizedDescription)")
            return
        }

        defaults.set(true, forKey: legacyMigrationKey)
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
            ControlCenterSupport.reloadPingProtectionControl()
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
            ControlCenterSupport.reloadPingProtectionControl()
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

    var supportLastPromptDate: Date? {
        get { defaults.object(forKey: supportLastPromptDateKey) as? Date }
        set { defaults.set(newValue, forKey: supportLastPromptDateKey) }
    }

    var supportOpenedDate: Date? {
        get { defaults.object(forKey: supportOpenedDateKey) as? Date }
        set { defaults.set(newValue, forKey: supportOpenedDateKey) }
    }

    var completedProtectedSessionCount: Int {
        get { max(0, defaults.integer(forKey: completedSessionCountKey)) }
        set { defaults.set(max(0, newValue), forKey: completedSessionCountKey) }
    }

    var lifetimeInterventionCount: Int {
        get { max(0, defaults.integer(forKey: lifetimeInterventionCountKey)) }
        set { defaults.set(max(0, newValue), forKey: lifetimeInterventionCountKey) }
    }

    /// Crash reporting via Sentry. Default `false`; users can opt in from
    /// Settings → Advanced → Privacy. Reports contain no IP, network target,
    /// usage telemetry, or session event data. Turning it off applies
    /// immediately; turning it on starts reporting on the next launch.
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

    /// Remove every value owned by the shared app-group suite. This is used
    /// only after Ping Protection is confirmed off and the helper has been
    /// unregistered, so a partial removal cannot strand privileged state.
    func resetForRemoval() {
        defaults.removePersistentDomain(forName: appGroupID)

        // Before macOS 15, Ping Warden 2.x could persist values in the legacy
        // iOS-style group even without a profile. Remove that plist too when
        // the operating system still permits direct access to the container.
        if #unavailable(macOS 15.0),
           FileManager.default.fileExists(atPath: legacyPreferencesURL.path) {
            do {
                try FileManager.default.removeItem(at: legacyPreferencesURL)
            } catch {
                log.warning("Could not remove legacy App Group preferences: \(error.localizedDescription)")
            }
        }
    }

    private var legacyPreferencesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(legacyAppGroupID, isDirectory: true)
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(legacyAppGroupID).plist", isDirectory: false)
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
