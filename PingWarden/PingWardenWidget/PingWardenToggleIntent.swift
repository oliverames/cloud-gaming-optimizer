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
/// Note: This intent updates the shared preference and sends a distributed notification.
/// If enabling while the app is not running, the app is launched in the background
/// so helper control can be applied.
struct SetPingProtectionIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set Ping Protection"
    static var description = IntentDescription("Turns Ping Protection on or off")
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
/// Note: This intent updates the shared preference and sends a distributed notification.
/// If enabling while the app is not running, the app is launched in the background
/// so helper control can be applied.
struct ToggleAWDLMonitoringIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Ping Protection"
    static var description = IntentDescription("Toggles Ping Protection on or off")
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult {
        let currentState = PingWardenPreferences.shared.isMonitoringEnabled
        try await PingProtectionIntentHandler.apply(desiredState: !currentState)
        return .result()
    }
}

private enum PingProtectionIntentHandler {
    private enum LaunchOutcome {
        case alreadyRunning
        case launched
        case failed
    }

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

        let previousIntentState = preferences.isMonitoringEnabled
        let previousEffectiveState = preferences.effectiveMonitoringEnabled
        log.info("Setting monitoring intent from \(previousIntentState) to \(desiredState)")

        preferences.isMonitoringEnabled = desiredState
        ControlCenter.shared.reloadControls(ofKind: PingWardenControlKind.pingProtection)

        let verifiedState = preferences.isMonitoringEnabled
        if verifiedState != desiredState {
            log.error("Failed to set monitoring intent - state mismatch")
            throw AWDLError.toggleFailed
        }

        // Enabling always needs the main app to apply helper state. Disabling
        // also needs the app if the last effective state says protection is active.
        let launchRequired = desiredState || previousEffectiveState != desiredState
        let launchOutcome = launchRequired ? await launchMainAppIfNeeded() : LaunchOutcome.alreadyRunning

        switch launchOutcome {
        case .alreadyRunning:
            break
        case .launched:
            // Give the app a brief moment to finish launch and process intent signal.
            // (The app also reconciles intent vs. runtime state at startup, so
            // this repost is belt-and-braces rather than load-bearing.)
            try? await Task.sleep(nanoseconds: 700_000_000)
            postMonitoringIntentNotification()
            ControlCenter.shared.reloadControls(ofKind: PingWardenControlKind.pingProtection)
        case .failed:
            // Roll back the intent so the toggle doesn't show a state that
            // nothing will ever apply, then surface the failure.
            preferences.isMonitoringEnabled = previousIntentState
            ControlCenter.shared.reloadControls(ofKind: PingWardenControlKind.pingProtection)
            log.error("Main app could not be launched - rolled back monitoring intent")
            throw AWDLError.appLaunchFailed
        }

        log.info("Successfully set monitoring intent to \(desiredState)")
    }

    /// Launch the main app if it's not already running
    private static func launchMainAppIfNeeded() async -> LaunchOutcome {
        let bundleIdentifier = "com.amesvt.pingwarden"

        // Check if app is already running
        guard !isMainAppRunning(bundleIdentifier: bundleIdentifier) else {
            log.debug("Main app already running")
            return .alreadyRunning
        }

        log.info("Main app not running, attempting to launch...")

        // Try to launch the app using its bundle identifier
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false // Don't bring to foreground
            configuration.addsToRecentItems = false

            do {
                _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                log.info("Successfully launched main app")
                return .launched
            } catch {
                log.error("Failed to launch main app: \(error.localizedDescription)")
            }
        } else {
            log.warning("Could not find main app URL for bundle identifier: \(bundleIdentifier)")
        }
        return .failed
    }

    private static func isMainAppRunning(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    private static func postMonitoringIntentNotification() {
        DistributedNotificationCenter.default().postNotificationName(
            .awdlMonitoringStateChanged,
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

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .toggleFailed:
            return "Failed to toggle Ping Protection"
        case .monitoringFailed:
            return "Failed to start monitoring"
        case .appLaunchFailed:
            return "Failed to launch Ping Warden app"
        }
    }
}
