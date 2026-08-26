import Foundation

enum GameModePollingPolicy {
    static let activeInterval: TimeInterval = 2
    static let inactiveInterval: TimeInterval = 10
    /// Deep-idle cadence used once no fullscreen game has been seen for a
    /// sustained stretch. App-activation and display-change events reset the
    /// streak and re-check immediately, so a game launching from idle is
    /// caught by the event path rather than waiting out this tier.
    static let idleInterval: TimeInterval = 30
    /// Consecutive quiet ticks (at the inactive cadence, roughly 90 s) before
    /// dropping to `idleInterval`.
    static let idleStreakThreshold: Int = 9

    static func interval(isActive: Bool) -> TimeInterval {
        isActive ? activeInterval : inactiveInterval
    }

    static func interval(isActive: Bool, idleStreakTicks: Int) -> TimeInterval {
        guard !isActive else { return activeInterval }
        return idleStreakTicks >= idleStreakThreshold ? idleInterval : inactiveInterval
    }
}
