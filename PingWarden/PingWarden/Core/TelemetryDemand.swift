//
//  TelemetryDemand.swift
//  PingWarden
//
//  Pure policy for reconciling multiple UI consumers onto one probe stream.
//

import Foundation

struct TelemetryDemand: Equatable {
    let consumerID: UUID
    let host: String
    let port: UInt16
    let interval: TimeInterval
    let priority: Int
    let revision: UInt64
}

struct TelemetryConfiguration: Equatable {
    let host: String
    let port: UInt16
    let interval: TimeInterval
}

enum TelemetryDemandResolver {
    static let minimumInterval: TimeInterval = 0.2

    static func resolve(_ demands: [TelemetryDemand]) -> TelemetryConfiguration? {
        guard let targetOwner = demands.max(by: { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.revision < rhs.revision
        }) else {
            return nil
        }

        let matchingIntervals = demands.lazy
            .filter { $0.host == targetOwner.host && $0.port == targetOwner.port }
            .map { max(minimumInterval, $0.interval) }

        return TelemetryConfiguration(
            host: targetOwner.host,
            port: targetOwner.port,
            interval: matchingIntervals.min() ?? max(minimumInterval, targetOwner.interval)
        )
    }
}
