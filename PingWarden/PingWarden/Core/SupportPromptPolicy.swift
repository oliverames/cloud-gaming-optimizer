import Foundation

enum SupportPromptPolicy {
    static let minimumCompletedSessions = 3
    static let minimumLifetimeInterventions = 10
    static let promptCooldown: TimeInterval = 30 * 24 * 60 * 60
    static let supportCooldown: TimeInterval = 180 * 24 * 60 * 60

    struct Context: Sendable {
        var setupComplete: Bool
        var completedSessionCount: Int
        var lifetimeInterventionCount: Int
        var activeSession: Bool
        var updateInProgress: Bool
        var dismissedPermanently: Bool
        var lastPromptDate: Date?
        var supportOpenedDate: Date?
        var now: Date
    }

    static func shouldPrompt(_ context: Context) -> Bool {
        guard context.setupComplete,
              !context.activeSession,
              !context.updateInProgress,
              !context.dismissedPermanently else {
            return false
        }

        let demonstratedValue = context.completedSessionCount >= minimumCompletedSessions
            || context.lifetimeInterventionCount >= minimumLifetimeInterventions
        guard demonstratedValue else { return false }

        if let lastPromptDate = context.lastPromptDate,
           context.now.timeIntervalSince(lastPromptDate) < promptCooldown {
            return false
        }

        if let supportOpenedDate = context.supportOpenedDate,
           context.now.timeIntervalSince(supportOpenedDate) < supportCooldown {
            return false
        }

        return true
    }
}
