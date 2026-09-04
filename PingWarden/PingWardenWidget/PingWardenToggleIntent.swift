//
//  PingWardenToggleIntent.swift
//  PingWardenWidget
//
//  App Intent to toggle AWDL monitoring from Control Center.
//
//  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
//  Licensed under the MIT License.
//

import AppIntents
import AppKit
import Foundation
import os.log
import WidgetKit

private let log = Logger(subsystem: "com.amesvt.pingwarden", category: "WidgetIntent")

/// App Intent to set Ping Protection from a Control Center toggle.
/// When enabled, continuously monitors and keeps AWDL down.
///
/// The signed widget applies the operation directly to the privileged helper.
/// Shared preferences are updated only after that authenticated XPC call succeeds.
struct SetPingProtectionIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set Ping Protection"
    static var description = IntentDescription("Turns Ping Protection on or off and saves that choice")
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Enabled")
    var value: Bool

    init() {}

    init(value: Bool) {
        self.value = value
    }

    func perform() async throws -> some IntentResult {
        try await PingProtectionIntentHandler.apply(desiredState: value)
        return .result()
    }
}

/// App Intent to toggle AWDL monitoring.
/// When enabled, continuously monitors and keeps AWDL down.
///
/// The signed widget applies the operation directly to the privileged helper.
/// Shared preferences are updated only after that authenticated XPC call succeeds.
struct ToggleAWDLMonitoringIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Ping Protection"
    static var description = IntentDescription("Toggles Ping Protection and saves the new choice")
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult {
        let currentState = PingWardenPreferences.shared.isMonitoringEnabled
        try await PingProtectionIntentHandler.apply(desiredState: !currentState)
        return .result()
    }
}

private enum PingProtectionIntentHandler {
    static func apply(desiredState: Bool) async throws {
        let preferences = PingWardenPreferences.shared

        // Without the shared App Group suite the widget and the app read
        // different defaults domains: the write below would verify fine here
        // while the app never sees it. Fail visibly instead of toggling a
        // control that does nothing.
        guard preferences.usesAppGroupSuite else {
            log.error("App Group suite unavailable - refusing to toggle into a split-brain state")
            throw AWDLError.toggleFailed
        }

        // Enabling protection requires a license. The main app owns
        // verification; the widget reads the same shared cache, so the
        // gate cannot drift between the two toggle surfaces.
        if desiredState, !PingWardenWidgetLicenseGate.canEnableProtection(preferences) {
            log.warning("License gate blocked enabling Ping Protection from widget")
            throw AWDLError.licenseRequired
        }

        if desiredState {
            // The helper restores AWDL when its final client disconnects.
            // Keep the containing app alive as the durable connection owner.
            try await openContainingApp()
            guard PingWardenWidgetLicenseGate.canEnableProtection(preferences) else {
                throw AWDLError.licenseRequired
            }
        }

        log.info("Applying authenticated monitoring state: \(desiredState)")
        try await PingWardenWidgetHelperClient.setProtectionEnabled(desiredState)

        // A direct Control Center action is explicit user intent, so save it
        // as the persistent preference after the helper applies the change.
        preferences.isMonitoringEnabled = desiredState
        preferences.effectiveMonitoringEnabled = desiredState
        preferences.lastKnownState = desiredState ? "down" : "up"

        // These notifications invalidate display state in a running main app.
        // They never authorize the root operation, which already succeeded over
        // the helper's signed-client XPC boundary above.
        postMonitoringStateNotifications()
        ControlCenter.shared.reloadControls(ofKind: PingWardenControlKind.pingProtection)

        log.info("Successfully set monitoring intent to \(desiredState)")
    }

    @MainActor
    private static func openContainingApp() async throws {
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard Bundle(url: appURL)?.bundleIdentifier == "com.amesvt.pingwarden" else {
            throw AWDLError.appLaunchFailed
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.amesvt.pingwarden")
            .contains(where: { !$0.isTerminated && $0.bundleURL?.standardizedFileURL == appURL.standardizedFileURL }) {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        guard !app.isTerminated else { throw AWDLError.appLaunchFailed }
    }

    private static func postMonitoringStateNotifications() {
        DistributedNotificationCenter.default().postNotificationName(
            .awdlMonitoringStateChanged,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        DistributedNotificationCenter.default().postNotificationName(
            .awdlEffectiveMonitoringStateChanged,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

enum AWDLError: Error, CustomLocalizedStringResourceConvertible {
    case toggleFailed
    case monitoringFailed
    case appLaunchFailed
    case licenseRequired

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .toggleFailed:
            return "Ping Protection could not change. Open Ping Warden and finish setup."
        case .monitoringFailed:
            return "Ping Protection could not reach its helper. Open Ping Warden and finish setup."
        case .appLaunchFailed:
            return "Ping Warden could not be opened."
        case .licenseRequired:
            return "Ping Protection requires a license. Open Ping Warden to enter your license key."
        }
    }
}
