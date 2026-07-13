import Foundation
import os.log

private let sessionLog = Logger(
    subsystem: "com.amesvt.pingwarden",
    category: "ProtectedSession"
)

@MainActor
final class ProtectedSessionCoordinator: ObservableObject {
    static let shared = ProtectedSessionCoordinator()

    @Published private(set) var activeSessionStartedAt: Date?
    @Published private(set) var activeTrigger: ProtectedSessionTrigger?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var history: [ProtectedSessionSummary] = []
    @Published private(set) var latestSummary: ProtectedSessionSummary?
    @Published private(set) var lastError: String?

    var onSessionCompleted: ((ProtectedSessionSummary) -> Void)?
    var onSessionStateChanged: (() -> Void)?

    var isActive: Bool { accumulator != nil }

    private let pingMonitor = PingMonitor.shared
    private let telemetryConsumerID = UUID()
    private let store = ProtectedSessionStore()
    private var telemetryObserverToken: UUID?
    private var accumulator: ProtectedSessionAccumulator?
    private var wasMonitoringBeforeSession = false
    private var latestInterventionCount = 0
    private var elapsedTimer: Timer?
    private var interventionTimer: Timer?

    private init() {
        do {
            history = try store.load()
            latestSummary = history.first
        } catch {
            sessionLog.error("Could not load protected sessions: \(error.localizedDescription)")
        }

        telemetryObserverToken = pingMonitor.addObserver { [weak self] snapshot in
            Task { @MainActor in
                self?.record(snapshot.latestResult)
            }
        }
    }

    func start(trigger: ProtectedSessionTrigger = .manual) async {
        guard accumulator == nil else { return }
        guard PingWardenMonitor.shared.isHelperRegistered else {
            lastError = "Finish Ping Protection setup before starting a session."
            return
        }

        lastError = nil
        wasMonitoringBeforeSession = PingWardenMonitor.shared.isMonitoringActive
        if !wasMonitoringBeforeSession {
            PingWardenMonitor.shared.startMonitoring(persistUserPreference: false)
            await waitForProtectionToStart()
        }

        guard PingWardenMonitor.shared.isMonitoringActive else {
            lastError = "Ping Protection could not start. Check the helper in Settings."
            return
        }

        let startedAt = Date()
        latestInterventionCount = await fetchInterventionCount()
        accumulator = ProtectedSessionAccumulator(
            startedAt: startedAt,
            trigger: trigger,
            startingInterventionCount: latestInterventionCount
        )
        activeSessionStartedAt = startedAt
        activeTrigger = trigger
        elapsed = 0

        let target = selectedTelemetryTarget()
        pingMonitor.start(
            consumerID: telemetryConsumerID,
            server: target.host,
            port: target.port,
            interval: selectedTelemetryInterval(),
            priority: 50
        )
        startSessionTimers()
        onSessionStateChanged?()
        sessionLog.info("Protected session started (\(trigger.rawValue, privacy: .public))")
    }

    func stop(restoreProtection: Bool = true) async {
        guard accumulator != nil else { return }
        latestInterventionCount = await fetchInterventionCount()
        finish(
            endingInterventionCount: latestInterventionCount,
            restoreProtection: restoreProtection
        )
    }

    func startForGameMode() {
        guard accumulator == nil else { return }
        Task { await start(trigger: .gameMode) }
    }

    func stopForGameMode() {
        guard activeTrigger == .gameMode else { return }
        Task { await stop(restoreProtection: false) }
    }

    func finishForTermination() {
        guard accumulator != nil else { return }
        finish(endingInterventionCount: latestInterventionCount, restoreProtection: false)
    }

    func clearHistory() {
        do {
            try store.removeAll()
            history = []
            latestSummary = nil
        } catch {
            lastError = "Session history could not be cleared."
            sessionLog.error("Could not clear protected sessions: \(error.localizedDescription)")
        }
    }

    private func record(_ result: PingMonitor.PingResult) {
        guard accumulator != nil else { return }
        accumulator?.record(PingSample(
            latencyMs: result.latencyMs,
            success: result.success,
            timestamp: result.timestamp
        ))
    }

    private func finish(
        endingInterventionCount: Int,
        restoreProtection: Bool = true
    ) {
        guard let currentAccumulator = accumulator else { return }

        accumulator = nil
        activeSessionStartedAt = nil
        activeTrigger = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        interventionTimer?.invalidate()
        interventionTimer = nil
        pingMonitor.stop(consumerID: telemetryConsumerID)

        let summary = currentAccumulator.finish(
            endedAt: Date(),
            endingInterventionCount: endingInterventionCount
        )
        latestSummary = summary
        elapsed = summary.duration

        do {
            try store.save(summary)
            history = try store.load()
        } catch {
            lastError = "The session ended, but its recap could not be saved."
            sessionLog.error("Could not save protected session: \(error.localizedDescription)")
        }

        let preferences = PingWardenPreferences.shared
        preferences.completedProtectedSessionCount += 1
        preferences.lifetimeInterventionCount += summary.interventionCount

        if restoreProtection && !wasMonitoringBeforeSession {
            PingWardenMonitor.shared.stopMonitoring(persistUserPreference: false)
        }
        wasMonitoringBeforeSession = false
        onSessionStateChanged?()

        sessionLog.info(
            "Protected session ended: \(summary.sampleCount) samples, \(summary.interventionCount) interventions"
        )
        onSessionCompleted?(summary)
    }

    private func startSessionTimers() {
        elapsedTimer?.invalidate()
        let newElapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.activeSessionStartedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        newElapsedTimer.tolerance = 0.2
        elapsedTimer = newElapsedTimer

        interventionTimer?.invalidate()
        let newInterventionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            PingWardenMonitor.shared.getInterventionCount { count in
                Task { @MainActor in
                    ProtectedSessionCoordinator.shared.latestInterventionCount = max(0, count)
                }
            }
        }
        newInterventionTimer.tolerance = 0.5
        interventionTimer = newInterventionTimer
    }

    private func fetchInterventionCount() async -> Int {
        await withCheckedContinuation { continuation in
            PingWardenMonitor.shared.getInterventionCount { count in
                continuation.resume(returning: max(0, count))
            }
        }
    }

    private func waitForProtectionToStart() async {
        for _ in 0..<30 {
            if PingWardenMonitor.shared.isMonitoringActive { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func selectedTelemetryTarget() -> (host: String, port: UInt16) {
        let fallback = ("8.8.8.8", UInt16(53))
        guard let rawTargetID = UserDefaults.standard.string(forKey: DashboardConfig.selectedTargetKey),
              let separatorIndex = rawTargetID.lastIndex(of: ":") else {
            return fallback
        }

        let host = String(rawTargetID[..<separatorIndex])
        let portText = String(rawTargetID[rawTargetID.index(after: separatorIndex)...])
        guard !host.isEmpty, let port = UInt16(portText) else { return fallback }
        return (host, port)
    }

    private func selectedTelemetryInterval() -> TimeInterval {
        let stored = UserDefaults.standard.double(forKey: DashboardConfig.updateIntervalKey)
        return DashboardConfig.intervalOptions.contains(stored)
            ? stored
            : DashboardConfig.defaultInterval
    }
}
