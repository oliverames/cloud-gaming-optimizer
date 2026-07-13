//
//  MonitoringStateStore.swift
//  PingWarden
//
//  Shared observer bridge for monitor runtime state and cross-process intent changes.
//

import Foundation

@MainActor
final class MonitoringStateStore: ObservableObject {
    @Published private(set) var isMonitoring = PingWardenMonitor.shared.isMonitoringActive
    @Published private(set) var isHelperRegistered = PingWardenMonitor.shared.isHelperRegistered
    @Published private(set) var interventionCount: Int = 0

    nonisolated(unsafe) private var monitoringIntentObserver: NSObjectProtocol?
    nonisolated(unsafe) private var monitoringEffectiveObserver: NSObjectProtocol?
    private var monitorStateObserverToken: UUID?
    nonisolated(unsafe) private var interventionTimer: Timer?
    private var isObserving = false

    func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        monitoringIntentObserver = DistributedNotificationCenter.default().addObserver(
            forName: .awdlMonitoringStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        monitoringEffectiveObserver = DistributedNotificationCenter.default().addObserver(
            forName: .awdlEffectiveMonitoringStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        monitorStateObserverToken = PingWardenMonitor.shared.addStateObserver { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }

        interventionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshInterventionCount()
            }
        }

        refresh()
        refreshInterventionCount()
    }

    func stopObserving() {
        guard isObserving else { return }
        isObserving = false

        if let observer = monitoringIntentObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            monitoringIntentObserver = nil
        }

        if let observer = monitoringEffectiveObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            monitoringEffectiveObserver = nil
        }

        if let token = monitorStateObserverToken {
            PingWardenMonitor.shared.removeStateObserver(token)
            monitorStateObserverToken = nil
        }

        interventionTimer?.invalidate()
        interventionTimer = nil
    }

    deinit {
        // Backstop in case onDisappear -> stopObserving() is ever skipped
        // (e.g. a future refactor that drops the callback). Observer removal,
        // registry-token removal, and timer invalidation are all safe off the
        // main actor; @StateObject deallocation happens on the main thread in
        // practice.
        if let observer = monitoringIntentObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let observer = monitoringEffectiveObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let token = monitorStateObserverToken {
            PingWardenMonitor.shared.removeStateObserver(token)
        }
        interventionTimer?.invalidate()
    }

    func refresh() {
        isMonitoring = PingWardenMonitor.shared.isMonitoringActive
        isHelperRegistered = PingWardenMonitor.shared.isHelperRegistered
        refreshInterventionCount()
    }

    private func refreshInterventionCount() {
        guard isMonitoring else {
            interventionCount = 0
            return
        }

        PingWardenMonitor.shared.getInterventionCount { [weak self] count in
            guard let self, let count else { return }
            Task { @MainActor in
                self.interventionCount = count
            }
        }
    }
}
