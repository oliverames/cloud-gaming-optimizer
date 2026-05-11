//
//  PingStatistics.swift
//  PingWarden
//
//  Shared ping statistics utilities (pure Foundation, testable).
//

import Foundation

enum PingQuality: String {
    case excellent
    case good
    case fair
    case poor
}

struct PingSample {
    let latencyMs: Double
    let success: Bool
    let timestamp: Date
}

struct PingStatisticsResult {
    let currentPing: Double
    let averagePing: Double
    let minimumPing: Double
    let maximumPing: Double
    let jitter: Double
    let packetLoss: Double
    let quality: PingQuality
}

enum PingStatistics {
    static func calculate(from samples: [PingSample]) -> PingStatisticsResult {
        guard !samples.isEmpty else {
            return PingStatisticsResult(
                currentPing: 0,
                averagePing: 0,
                minimumPing: 0,
                maximumPing: 0,
                jitter: 0,
                packetLoss: 0,
                quality: .poor
            )
        }

        let successful = samples.filter(\.success)
        let latencies = successful.map(\.latencyMs)

        let current = successful.last?.latencyMs ?? 0
        let average = latencies.isEmpty ? 0 : latencies.reduce(0, +) / Double(latencies.count)
        let minimum = latencies.min() ?? 0
        let maximum = latencies.max() ?? 0

        let jitter: Double
        if latencies.count > 1 {
            let diffs = zip(latencies.dropLast(), latencies.dropFirst()).map { abs($0.1 - $0.0) }
            jitter = diffs.reduce(0, +) / Double(diffs.count)
        } else {
            jitter = 0
        }

        let failedCount = samples.count - successful.count
        let packetLoss = samples.isEmpty ? 0 : (Double(failedCount) / Double(samples.count)) * 100.0

        // Use the median of the last 5 successful samples for quality
        // assessment to avoid flickering from single-sample outliers. For
        // even-count windows the median is the average of the two middle
        // elements, so the classifier behaves the same whether the window
        // has 1, 2, 3, 4, or 5 samples.
        let recentLatencies = Array(latencies.suffix(5))
        let qualityLatency: Double
        if recentLatencies.isEmpty {
            qualityLatency = 0
        } else {
            let sorted = recentLatencies.sorted()
            let midIndex = sorted.count / 2
            qualityLatency = sorted.count.isMultiple(of: 2)
                ? (sorted[midIndex - 1] + sorted[midIndex]) / 2.0
                : sorted[midIndex]
        }

        let quality: PingQuality
        if qualityLatency == 0 || latencies.isEmpty {
            quality = .poor
        } else if qualityLatency < 20 && packetLoss < 1.0 {
            quality = .excellent
        } else if qualityLatency < 50 && packetLoss < 2.0 {
            quality = .good
        } else if qualityLatency < 100 && packetLoss < 5.0 {
            quality = .fair
        } else {
            quality = .poor
        }

        return PingStatisticsResult(
            currentPing: current,
            averagePing: average,
            minimumPing: minimum,
            maximumPing: maximum,
            jitter: jitter,
            packetLoss: packetLoss,
            quality: quality
        )
    }
}
