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
    
    enum Quality {
        case excellent  // <20ms
        case good       // 20-50ms
        case fair       // 50-100ms
        case poor       // >100ms or packet loss
        
        var color: String {
            switch self {
            case .excellent: return "green"
            case .good: return "yellow"
            case .fair: return "orange"
            case .poor: return "red"
            }
        }
        
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
    private var history: [PingResult] = []
    private let historyLock = NSLock()
    private let stateLock = NSLock()
    private let queue = DispatchQueue(label: "com.amesvt.pingwarden.pingmonitor", qos: .utility)
    private let statsWindowSeconds: TimeInterval = 120
    private let historyRetentionSeconds: TimeInterval = 3900 // Keep slightly over one hour
    private let connectionTimeoutSeconds: Int = 1
    private var activeSessionID: UInt64 = 0
    private var inFlightSessionID: UInt64?
    
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
            history.last?.latency
        }
    }
    
    var currentPingMs: Double? {
        currentPing.map { $0 * 1000.0 }
    }
    
    // MARK: - Public Methods
    
    /// Start monitoring with specified server and interval
    func start(server: String? = nil, port: UInt16? = nil, interval: TimeInterval? = nil) {
        if let server = server { self.server = server }
        if let port = port { self.port = port }
        if let interval = interval { self.interval = interval }
        
        guard !isMonitoring else {
            log.warning("Ping monitor already running")
            return
        }
        
        log.info("Starting ping monitor: \(self.server):\(self.port) every \(self.interval)s")
        let sessionID = beginSession()
        
        // Perform immediate ping
        performPing(sessionID: sessionID)
        
        // Schedule repeating timer on main thread
        runOnMainThreadSync { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: self.interval, repeats: true) { [weak self] _ in
                self?.performPing(sessionID: sessionID)
            }
            // Ensure timer continues during UI interactions
            if let timer = self.timer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }
    
    /// Stop monitoring
    func stop() {
        log.info("Stopping ping monitor")
        
        runOnMainThreadSync { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
        endSession()
    }

    deinit {
        // Backstop: owners (DashboardViewModel, AppDelegate) call stop() before
        // releasing their PingMonitor, which is the reliable teardown path.
        // @StateObject / AppDelegate releases happen on the main thread in
        // practice, where the timer was scheduled, so invalidating here is safe.
        timer?.invalidate()
    }
    
    /// Get current network statistics
    func getStatistics() -> NetworkStatistics {
        let recentResults = snapshotRecentResults()

        let pureSamples = recentResults.map {
            PingSample(latencyMs: $0.latencyMs, success: $0.success, timestamp: $0.timestamp)
        }
        let computed = PingStatistics.calculate(from: pureSamples)

        return NetworkStatistics(
            currentPing: computed.currentPing,
            averagePing: computed.averagePing,
            minimumPing: computed.minimumPing,
            maximumPing: computed.maximumPing,
            jitter: computed.jitter,
            packetLoss: computed.packetLoss,
            quality: Self.mapQuality(computed.quality)
        )
    }
    
    /// Get historical ping data for graphing
    func getHistory(lastMinutes: Int = 60) -> [PingResult] {
        let cutoff = Date().addingTimeInterval(-TimeInterval(lastMinutes * 60))
        return withHistoryLock {
            history.filter { $0.timestamp > cutoff }
        }
    }
    
    /// Clear history
    func clearHistory() {
        withHistoryLock {
            history.removeAll()
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
            self.addToHistory(result, interval: configuredInterval)

            // Notify callbacks on main thread
            DispatchQueue.main.async {
                self.onPingResult?(result)
                self.onStatsUpdate?(self.getStatistics())
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
    
    private func addToHistory(_ result: PingResult, interval: TimeInterval) {
        withHistoryLock {
            history.append(result)
            
            // Time-based retention keeps behavior consistent across intervals.
            let cutoff = Date().addingTimeInterval(-historyRetentionSeconds)
            history.removeAll { $0.timestamp < cutoff }
            
            // Cap history by expected sample volume to avoid unbounded growth.
            let effectiveInterval = max(interval, 0.2)
            let maxHistorySize = Int((historyRetentionSeconds / effectiveInterval).rounded(.up))
            if history.count > maxHistorySize {
                history.removeFirst(history.count - maxHistorySize)
            }
        }
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
            return history.filter { $0.timestamp > cutoff }
        }
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
    
    var qualityColor: String {
        quality.color
    }
    
    var qualityDescription: String {
        quality.description
    }
}
