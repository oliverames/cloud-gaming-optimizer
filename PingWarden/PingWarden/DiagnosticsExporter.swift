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
        // Both getInterventionCount and performHealthCheck below use
        // semaphore waits that would deadlock/stall the main thread. Enforce
        // the background-queue contract up front and in Release builds too
        // (assert() compiles out and would let a future main-thread call
        // site hang the UI).
        guard !Thread.isMainThread else {
            assertionFailure("exportSnapshot must not be called on the main thread")
            return nil
        }

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

        let interventionCount = LockedValue<Int?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        monitor.getInterventionCount { count in
            interventionCount.withValue { $0 = count }
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

        let health = monitor.performHealthCheck()
        let awdlStatus = monitor.currentAWDLInterfaceStatus()

        let selectedTargetID = UserDefaults.standard.string(forKey: "DashboardSelectedPingTargetID")
        let customTargetIDs = Set(
            CustomPingTargetStore(userDefaults: PingWardenPreferences.shared.defaults)
                .load()
                .map { "\($0.host.lowercased()):\($0.port)" }
        )
        let selectedTarget = DiagnosticsPrivacy.targetDescription(
            selectedTargetID: selectedTargetID,
            customTargetIDs: customTargetIDs
        )
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
          intervention_count=\(interventionCount.withValue { $0.map(String.init) ?? "unavailable" })
          awdl_interface=\(awdlStatus)
          health_ok=\(health.isHealthy)
          health_message=\(health.message)

        dashboard:
          selected_target=\(selectedTarget)
          update_interval=\(updateIntervalValue)
        """

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let filename = "PingWarden-Diagnostics-\(fileTimestamp).txt"

        // Desktop writes can fail (TCC denial, iCloud-evicted or read-only
        // Desktop); fall back to the temporary directory rather than
        // reporting a generic failure.
        let candidateDirs = [desktop, FileManager.default.temporaryDirectory].compactMap { $0 }
        for destinationDir in candidateDirs {
            let fileURL = destinationDir.appendingPathComponent(filename)
            do {
                guard let data = diagnostics.data(using: .utf8) else { continue }
                try data.write(to: fileURL, options: [.atomic])
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: fileURL.path
                )
                return ExportResult(fileURL: fileURL, contents: diagnostics)
            } catch {
                continue
            }
        }
        return nil
    }
}
