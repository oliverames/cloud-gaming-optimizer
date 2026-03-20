//
//  DiagnosticsExporter.swift
//  PingWarden
//
//  Creates user-shareable diagnostics snapshots for support.
//

import Foundation
import ServiceManagement

enum DiagnosticsExporter {
    struct ExportResult {
        let fileURL: URL
        let contents: String
    }

    static func exportSnapshot() -> ExportResult? {
        let monitor = PingWardenMonitor.shared
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let now = Date()
        let timestamp = formatter.string(from: now)
        let fileTimestamp = timestamp
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"

        var interventionCount = 0
        let semaphore = DispatchSemaphore(value: 0)
        monitor.getInterventionCount { count in
            interventionCount = count
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2.0)

        let registrationStatus: String
        switch monitor.registrationStatus {
        case .enabled:
            registrationStatus = "enabled"
        case .notRegistered:
            registrationStatus = "notRegistered"
        case .requiresApproval:
            registrationStatus = "requiresApproval"
        case .notFound:
            registrationStatus = "notFound"
        @unknown default:
            registrationStatus = "unknown"
        }

        // Both getInterventionCount (above) and performHealthCheck use semaphore
        // waits that would deadlock the main thread. The sole call site already
        // dispatches to a background queue, so assert that contract here.
        assert(!Thread.isMainThread, "exportSnapshot must not be called on the main thread")
        let health = monitor.performHealthCheck()
        let awdlStatus = monitor.currentAWDLInterfaceStatus()

        let selectedTarget = UserDefaults.standard.string(forKey: "DashboardSelectedPingTargetID") ?? "unknown"
        let updateInterval = UserDefaults.standard.double(forKey: "DashboardUpdateInterval")
        let updateIntervalValue = updateInterval > 0 ? String(updateInterval) : "default"

        let diagnostics = """
        Ping Warden Diagnostics
        generated_at=\(timestamp)

        app:
          version=\(version)
          build=\(build)
          bundle_id=\(Bundle.main.bundleIdentifier ?? "unknown")

        system:
          macos=\(osString)
          arch=\(ProcessInfo.processInfo.processorCount > 0 ? "available" : "unknown")

        preferences:
          monitoring_intent=\(PingWardenPreferences.shared.isMonitoringEnabled)
          monitoring_effective=\(PingWardenPreferences.shared.effectiveMonitoringEnabled)
          game_mode_auto_detect=\(PingWardenPreferences.shared.gameModeAutoDetect)
          control_center_widget=\(PingWardenPreferences.shared.controlCenterWidgetEnabled)
          show_dock_icon=\(PingWardenPreferences.shared.showDockIcon)
          last_known_awdl_state=\(PingWardenPreferences.shared.lastKnownState)

        runtime:
          helper_registered=\(monitor.isHelperRegistered)
          registration_status=\(registrationStatus)
          monitor_active=\(monitor.isMonitoringActive)
          intervention_count=\(interventionCount)
          awdl_interface=\(awdlStatus)
          health_ok=\(health.isHealthy)
          health_message=\(health.message)

        dashboard:
          selected_target=\(selectedTarget)
          update_interval=\(updateIntervalValue)
        """

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let destinationDir = desktop ?? FileManager.default.temporaryDirectory
        let filename = "PingWarden-Diagnostics-\(fileTimestamp).txt"
        let fileURL = destinationDir.appendingPathComponent(filename)

        do {
            try diagnostics.write(to: fileURL, atomically: true, encoding: .utf8)
            return ExportResult(fileURL: fileURL, contents: diagnostics)
        } catch {
            return nil
        }
    }
}
