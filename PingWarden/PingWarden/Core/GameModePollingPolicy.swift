import Foundation

enum GameModePollingPolicy {
    static let activeInterval: TimeInterval = 2
    static let inactiveInterval: TimeInterval = 10

    static func interval(isActive: Bool) -> TimeInterval {
        isActive ? activeInterval : inactiveInterval
    }
}
