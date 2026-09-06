//
//  PingMonitor.swift
//  PingWarden
//
//  Real-time network latency monitoring for cloud gaming.
//  Uses TCP connection timing as a proxy for ICMP ping.
//
//  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
//  Licensed under the MIT License.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.amesvt.pingwarden", category: "PingMonitor")

/// Monitors network latency in real-time using TCP connection timing
/// Designed for cloud gaming - shows current ping, jitter, packet loss
class PingMonitor: @unchecked Sendable {
    static let shared = PingMonitor()
    
    // MARK: - Types
    
    struct PingResult: Identifiable {
        let id = UUID()
        let latency: TimeInterval  // in seconds
        let timestamp: Date
        let success: Bool
        
        var latencyMs: Double {
            latency * 1000.0
        }
    }

    struct Snapshot {
        let latestResult: PingResult
        let statistics: NetworkStatistics
        let history: [PingResult]
    }
    
    enum Quality {
        case excellent  // <20ms
        case good       // 20-50ms
        case fair       // 50-100ms
        case poor       // >100ms or packet loss
        
        var description: String {
            switch self {
            case .excellent: return "Excellent"
            case .good: return "Good"
            case .fair: return "Fair"
            case .poor: return "Poor"
            }
        }
    }
    
    // MARK: - Properties
    
    private var timer: Timer?
    private var history = RollingHistory<PingResult>()
    private let historyLock = NSLock()
    private let stateLock = NSLock()
    private let queue = DispatchQueue(label: "com.amesvt.pingwarden.pingmonitor", qos: .utility)
    private let statsWindowSeconds: TimeInterval = 120
    private let historyRetentionSeconds: TimeInterval = 3900 // Keep slightly over one hour
    private let connectionTimeoutSeconds: Int = 1
    private var activeSessionID: UInt64 = 0
    private var inFlightSessionID: UInt64?
    private let legacyConsumerID = UUID()
    private var telemetryDemands: [UUID: TelemetryDemand] = [:]
    private var demandRevision: UInt64 = 0
    private var observers: [UUID: (Snapshot) -> Void] = [:]
    
    /// Current server to ping
    var server: String = "8.8.8.8"
    
    /// Port to use for TCP ping (53 = DNS, usually reachable and low-latency)
    var port: UInt16 = 53
    
    /// Interval between pings (in seconds)
    var interval: TimeInterval = 2.0
    
    /// Callback when new ping result is available
    var onPingResult: ((PingResult) -> Void)?
    
    /// Callback when statistics are updated
    var onStatsUpdate: ((NetworkStatistics) -> Void)?
    
    // MARK: - Computed Properties
    
    var isMonitoring: Bool {
        return timer != nil
    }
    
    var currentPing: TimeInterval? {
        withHistoryLock {
            // Failed probes store the timeout as their latency; reporting
            // that as "current ping" would show e.g. 1000 ms instead of
            // signaling loss. Surface the last *successful* measurement.
            history.last(where: { $0.success })?.latency
        }
    }
    
    // MARK: - Public Methods
    
    /// Legacy single-owner entry point. New callers should use the consumer
    /// overload so several UI surfaces can share one physical probe stream.
    func start(server: String? = nil, port: UInt16? = nil, interval: TimeInterval? = nil) {
        start(
            consumerID: legacyConsumerID,
            server: server ?? self.server,
            port: port ?? self.port,
            interval: interval ?? self.interval
        )
    }

    /// Register or update one consumer's telemetry demand. All consumers that
    /// request the selected target share a single timer and use the fastest
    /// requested interval. Higher-priority consumers choose the target.
    func start(
        consumerID: UUID,
        server: String,
        port: UInt16,
        interval: TimeInterval,
        priority: Int = 0,
        resetHistory: Bool = false
    ) {
        runOnMainThreadSync { [weak self] in
            guard let self else { return }
            self.demandRevision &+= 1
            self.telemetryDemands[consumerID] = TelemetryDemand(
                consumerID: consumerID,
                host: server,
                port: port,
                interval: interval,
                priority: priority,
                revision: self.demandRevision
            )
            self.reconcileTelemetryDemands(resetHistory: resetHistory)
        }
    }
    
    /// Stop monitoring
    func stop() {
        stop(consumerID: legacyConsumerID)
    }

    func stop(consumerID: UUID) {
        runOnMainThreadSync { [weak self] in
            guard let self else { return }
            self.telemetryDemands.removeValue(forKey: consumerID)
            self.reconcileTelemetryDemands()
        }
    }

    @discardableResult
    func addObserver(_ observer: @escaping (Snapshot) -> Void) -> UUID {
        let token = UUID()
        stateLock.lock()
        observers[token] = observer
        stateLock.unlock()
        return token
    }

    func removeObserver(_ token: UUID) {
        stateLock.lock()
        observers.removeValue(forKey: token)
        stateLock.unlock()
    }

    deinit {
        // Backstop: owners (DashboardViewModel, AppDelegate) call stop() before
        // releasing their PingMonitor, which is the reliable teardown path.
        // @StateObject / AppDelegate releases happen on the main thread in
        // practice, where the timer was scheduled, so invalidating here is safe.
        timer?.invalidate()
    }
    
    /// Clear history
    func clearHistory() {
        withHistoryLock {
            history.removeAll(keepingCapacity: true)
        }
    }
    
    // MARK: - Private Methods
    
    private func performPing(sessionID: UInt64) {
        guard markProbeInFlight(sessionID: sessionID) else {
            log.debug("Skipping ping because the previous probe is still in flight")
            return
        }

        // Capture the configuration on the calling thread (always main, where
        // `start()` also writes these). Reading server/port/interval inside
        // `queue.async` would race with a concurrent `start()` that rewrites
        // them while an older probe is still in flight after a target switch —
        // a torn String read on `server` is undefined behavior. The session-ID
        // guard prevents stale *results* but not the concurrent memory access.
        let host = self.server
        let probePort = self.port
        let timeoutSeconds = self.connectionTimeoutSeconds
        let configuredInterval = self.interval

        queue.async { [weak self] in
            guard let self = self else { return }
            defer { self.markProbeFinished(sessionID: sessionID) }

            let timestamp = Date()
            let measuredLatencyMs = TCPProbe.measureLatency(
                host: host,
                port: probePort,
                timeoutSeconds: timeoutSeconds
            )
            let success = measuredLatencyMs != nil
            let latency = success ? (measuredLatencyMs ?? 0) / 1000.0 : TimeInterval(timeoutSeconds)

            let result = PingResult(
                latency: latency,
                timestamp: timestamp,
                success: success
            )

            guard self.isSessionCurrent(sessionID) else {
                log.debug("Dropping stale ping result from an old monitor session")
                return
            }

            // Store in history
            guard self.addToHistoryIfCurrent(
                result,
                interval: configuredInterval,
                sessionID: sessionID
            ) else {
                return
            }

            // Statistics and the retained-history snapshot are derived on the
            // utility queue. The main thread only publishes the finished value.
            let snapshot = self.makeSnapshot(latestResult: result)

            // Notify callbacks on main thread
            DispatchQueue.main.async {
                guard self.isSessionCurrent(sessionID) else { return }
                self.onPingResult?(result)
                self.onStatsUpdate?(snapshot.statistics)
                self.observerCallbacks().forEach { $0(snapshot) }
            }

            if success {
                log.debug("Ping to \(host): \(String(format: "%.1f", result.latencyMs))ms")
            } else {
                log.warning("Ping to \(host) failed")
            }
        }
    }

    private func beginSession() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        activeSessionID &+= 1
        inFlightSessionID = nil
        return activeSessionID
    }

    private func endSession() {
        stateLock.lock()
        activeSessionID &+= 1
        inFlightSessionID = nil
        stateLock.unlock()
    }

    private func markProbeInFlight(sessionID: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSessionID == sessionID, inFlightSessionID == nil else {
            return false
        }
        inFlightSessionID = sessionID
        return true
    }

    private func markProbeFinished(sessionID: UInt64) {
        stateLock.lock()
        if inFlightSessionID == sessionID {
            inFlightSessionID = nil
        }
        stateLock.unlock()
    }

    private func isSessionCurrent(_ sessionID: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeSessionID == sessionID
    }

    private static func mapQuality(_ quality: PingQuality) -> Quality {
        switch quality {
        case .excellent: return .excellent
        case .good: return .good
        case .fair: return .fair
        case .poor: return .poor
        }
    }
    
    private func addToHistoryIfCurrent(
        _ result: PingResult,
        interval: TimeInterval,
        sessionID: UInt64
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSessionID == sessionID else { return false }

        withHistoryLock {
            history.append(result)
            
            // Time-based retention keeps behavior consistent across intervals.
            let cutoff = Date().addingTimeInterval(-historyRetentionSeconds)
            history.removePrefix { $0.timestamp < cutoff }
            
            // Cap history by expected sample volume to avoid unbounded growth.
            let effectiveInterval = max(interval, 0.2)
            let maxHistorySize = Int((historyRetentionSeconds / effectiveInterval).rounded(.up))
            history.trimToLast(maxHistorySize)
        }
        return true
    }
    
    private func runOnMainThreadSync(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync(execute: block)
        }
    }
    
    private func snapshotRecentResults() -> [PingResult] {
        withHistoryLock {
            let cutoff = Date().addingTimeInterval(-statsWindowSeconds)
            return history.elements.filter { $0.timestamp > cutoff }
        }
    }

    private func makeSnapshot(latestResult: PingResult) -> Snapshot {
        let retainedHistory = withHistoryLock { history.elements }
        let cutoff = Date().addingTimeInterval(-statsWindowSeconds)
        let recentSamples = retainedHistory.lazy
            .filter { $0.timestamp > cutoff }
            .map { PingSample(latencyMs: $0.latencyMs, success: $0.success, timestamp: $0.timestamp) }
        let computed = PingStatistics.calculate(from: Array(recentSamples))
        let statistics = NetworkStatistics(
            currentPing: computed.currentPing,
            averagePing: computed.averagePing,
            minimumPing: computed.minimumPing,
            maximumPing: computed.maximumPing,
            jitter: computed.jitter,
            packetLoss: computed.packetLoss,
            quality: Self.mapQuality(computed.quality)
        )
        return Snapshot(latestResult: latestResult, statistics: statistics, history: retainedHistory)
    }

    private func observerCallbacks() -> [(Snapshot) -> Void] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Array(observers.values)
    }

    private func reconcileTelemetryDemands(resetHistory: Bool = false) {
        guard let configuration = TelemetryDemandResolver.resolve(Array(telemetryDemands.values)) else {
            if timer != nil {
                log.info("Stopping shared ping monitor because no consumers remain")
                timer?.invalidate()
                timer = nil
                endSession()
            }
            return
        }

        if timer != nil,
           server == configuration.host,
           port == configuration.port,
           interval == configuration.interval {
            return
        }

        let targetChanged = server != configuration.host || port != configuration.port
        timer?.invalidate()
        server = configuration.host
        port = configuration.port
        interval = configuration.interval

        log.info("Starting shared ping monitor: \(configuration.host):\(configuration.port) every \(configuration.interval)s")
        let sessionID = beginSession()
        if resetHistory || targetChanged {
            clearHistory()
        }
        performPing(sessionID: sessionID)

        let scheduledTimer = Timer.scheduledTimer(withTimeInterval: configuration.interval, repeats: true) { [weak self] _ in
            self?.performPing(sessionID: sessionID)
        }
        scheduledTimer.tolerance = min(0.25, configuration.interval * 0.1)
        timer = scheduledTimer
        RunLoop.main.add(scheduledTimer, forMode: .common)
    }
    
    @discardableResult
    private func withHistoryLock<T>(_ block: () -> T) -> T {
        historyLock.lock()
        defer { historyLock.unlock() }
        return block()
    }
}

// MARK: - Network Statistics

struct NetworkStatistics {
    let currentPing: Double      // milliseconds
    let averagePing: Double      // milliseconds
    let minimumPing: Double      // milliseconds
    let maximumPing: Double      // milliseconds
    let jitter: Double           // milliseconds (variance)
    let packetLoss: Double       // percentage (0-100)
    let quality: PingMonitor.Quality
    
    var qualityDescription: String {
        quality.description
    }
}
