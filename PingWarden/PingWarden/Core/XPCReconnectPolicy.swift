//
//  XPCReconnectPolicy.swift
//  PingWarden
//
//  Backoff policy for reconnecting XPC channels.
//

import Foundation

enum XPCReconnectPolicy {
    /// Upper bound on the backoff so a large attempt number can never
    /// produce a multi-day (or, past ~1024 attempts, infinite) delay that
    /// effectively stops retrying.
    static let maxDelaySeconds: TimeInterval = 30

    static func delayForAttempt(_ attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        // Cap the exponent before pow() — pow(2, 1100) overflows to +inf.
        let boundedAttempt = min(attempt, 16)
        return min(pow(2.0, Double(boundedAttempt - 1)), maxDelaySeconds)
    }
}
