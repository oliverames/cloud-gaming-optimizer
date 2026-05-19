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

/// App Intent to toggle AWDL monitoring (used by Control Widget button)
/// When enabled, continuously monitors and keeps AWDL down.
///
/// Note: This intent updates the shared preference and sends a distributed notification.
/// If enabling while the app is not running, the app is launched in the background
/// so helper control can be applied.
struct ToggleAWDLMonitoringIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Ping Protection"
    static var description = IntentDescription("Toggles Ping Protection on or off")

    /// Opens the main app when the intent is performed
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        // Toggle the current state
        let currentState = PingWardenPreferences.shared.isMonitoringEnabled
        let newState = !currentState
        log.info("Toggling monitoring from \(currentState) to \(newState)")

        // Update shared preference and broadcast intent change.
        PingWardenPreferences.shared.isMonitoringEnabled = newState
        postMonitoringIntentNotification()
        WidgetCenter.shared.reloadAllTimelines()

        // Verify the change was applied
        let verifiedState = PingWardenPreferences.shared.isMonitoringEnabled
        if verifiedState != newState {
            log.error("Failed to toggle monitoring - state mismatch")
            throw AWDLError.toggleFailed
        }

        // Launch app when enabling and app is not already running so monitoring can start.
        let launchRequired = newState
        let didLaunch = launchRequired ? await launchMainAppIfNeeded() : false

        if didLaunch {
            // Give the app a brief moment to finish launch and process intent signal.
            try? await Task.sleep(nanoseconds: 700_000_000)
            postMonitoringIntentNotification()
        }

        log.info("Successfully toggled monitoring to \(newState)")
        return .result()
    }

    /// Launch the main app if it's not already running
    @discardableResult
    private func launchMainAppIfNeeded() async -> Bool {
        let bundleIdentifier = "com.amesvt.pingwarden"

        // Check if app is already running
        guard !isMainAppRunning(bundleIdentifier: bundleIdentifier) else {
            log.debug("Main app already running")
            return false
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
                return true
            } catch {
                log.error("Failed to launch main app: \(error.localizedDescription)")
            }
        } else {
            log.warning("Could not find main app URL for bundle identifier: \(bundleIdentifier)")
        }
        return false
    }

    private func isMainAppRunning(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    private func postMonitoringIntentNotification() {
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
