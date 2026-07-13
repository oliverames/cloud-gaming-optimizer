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
    @Published private(set) var phase: ProtectionSessionPhase = .idle

    var onSessionCompleted: ((ProtectedSessionSummary) -> Void)?
    var onSessionStateChanged: (() -> Void)?

    var isActive: Bool { accumulator != nil }
    var isTransitioning: Bool { phase == .starting || phase == .stopping }

    private let pingMonitor = PingMonitor.shared
    private let telemetryConsumerID = UUID()
    private let store = ProtectedSessionStore()
    private var telemetryObserverToken: UUID?
    private var accumulator: ProtectedSessionAccumulator?
    private var latestInterventionCount = 0
    private var elapsedTimer: Timer?
    private var interventionTimer: Timer?
    private var startOperationID: UUID?

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
        guard phase == .idle, accumulator == nil else { return }
        guard PingWardenMonitor.shared.isHelperRegistered else {
            lastError = "Finish Ping Protection setup before starting a session."
            return
        }
        guard PingWardenMonitor.shared.isMonitoringActive else {
            lastError = "Ping Protection must be on before recording a latency session."
            return
        }

        lastError = nil
        phase = .starting
        let operationID = UUID()
        startOperationID = operationID
        onSessionStateChanged?()

        let startedAt = Date()
        guard let startingInterventionCount = await fetchInterventionCount() else {
            lastError = "The helper did not return its intervention counter, so the latency session did not start."
            phase = .idle
            startOperationID = nil
            onSessionStateChanged?()
            return
        }
        latestInterventionCount = startingInterventionCount
        guard phase == .starting, startOperationID == operationID else {
            return
        }
        accumulator = ProtectedSessionAccumulator(
            startedAt: startedAt,
            trigger: trigger,
            startingInterventionCount: latestInterventionCount
        )
        activeSessionStartedAt = startedAt
        activeTrigger = trigger
        elapsed = 0
        phase = .active
        startOperationID = nil

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

    func stop(
        endReason: ProtectedSessionEndReason = .endedByUser,
        protectionWasInterrupted: Bool = false
    ) async {
        if phase == .starting {
            startOperationID = nil
            phase = .idle
            onSessionStateChanged?()
            return
        }
        guard accumulator != nil, phase == .active else { return }
        phase = .stopping
        onSessionStateChanged?()
        if let endingInterventionCount = await fetchInterventionCount() {
            latestInterventionCount = endingInterventionCount
        }
        finish(
            endingInterventionCount: latestInterventionCount,
            endReason: endReason,
            protectionWasInterrupted: protectionWasInterrupted
        )
    }

    func startForGameMode() {
        guard phase == .idle, accumulator == nil else { return }
        Task { await start(trigger: .gameMode) }
    }

    func stopForGameMode() {
        guard activeTrigger == .gameMode || phase == .starting else { return }
        Task { await stop(endReason: .gameModeEnded) }
    }

    func finishForTermination() {
        guard accumulator != nil else { return }
        finish(
            endingInterventionCount: latestInterventionCount,
            endReason: .applicationTerminated,
            protectionWasInterrupted: false
        )
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
        endReason: ProtectedSessionEndReason,
        protectionWasInterrupted: Bool
    ) {
        guard let currentAccumulator = accumulator else { return }

        accumulator = nil
        phase = .idle
        startOperationID = nil
        activeSessionStartedAt = nil
        activeTrigger = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        interventionTimer?.invalidate()
        interventionTimer = nil
        pingMonitor.stop(consumerID: telemetryConsumerID)

        let summary = currentAccumulator.finish(
            endedAt: Date(),
            endingInterventionCount: endingInterventionCount,
            endReason: endReason,
            protectionWasInterrupted: protectionWasInterrupted
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
                    guard let count else { return }
                    ProtectedSessionCoordinator.shared.latestInterventionCount = max(0, count)
                }
            }
        }
        newInterventionTimer.tolerance = 0.5
        interventionTimer = newInterventionTimer
    }

    private func fetchInterventionCount() async -> Int? {
        await withCheckedContinuation { continuation in
            let didComplete = LockedValue(false)
            let finish: @Sendable (Int?) -> Void = { value in
                let shouldFinish = didComplete.withValue { completed in
                    guard !completed else { return false }
                    completed = true
                    return true
                }
                guard shouldFinish else { return }
                continuation.resume(returning: value.map { max(0, $0) })
            }

            PingWardenMonitor.shared.getInterventionCount { count in
                finish(count)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                finish(nil)
            }
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
