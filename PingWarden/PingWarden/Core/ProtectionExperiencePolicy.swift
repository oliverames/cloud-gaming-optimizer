import Foundation

enum ProtectionSessionPhase: String, Codable, CaseIterable, Sendable {
    case idle
    case starting
    case active
    case stopping
}

enum ProtectionExperiencePolicy {
    struct State: Equatable, Sendable {
        var helperAvailable: Bool
        var persistentProtectionEnabled: Bool
        var effectiveProtectionEnabled: Bool
        var sessionPhase: ProtectionSessionPhase
        var sessionTrigger: ProtectedSessionTrigger?
        var pauseUntil: Date?
        var licenseAllowsProtection: Bool

        init(
            helperAvailable: Bool,
            persistentProtectionEnabled: Bool,
            effectiveProtectionEnabled: Bool,
            sessionPhase: ProtectionSessionPhase,
            sessionTrigger: ProtectedSessionTrigger?,
            pauseUntil: Date?,
            licenseAllowsProtection: Bool = true
        ) {
            self.helperAvailable = helperAvailable
            self.persistentProtectionEnabled = persistentProtectionEnabled
            self.effectiveProtectionEnabled = effectiveProtectionEnabled
            self.sessionPhase = sessionPhase
            self.sessionTrigger = sessionTrigger
            self.pauseUntil = pauseUntil
            self.licenseAllowsProtection = licenseAllowsProtection
        }
    }

    struct MenuPresentation: Equatable, Sendable {
        let protectionTitle: String
        let protectionActionEnabled: Bool
        let pauseTitle: String?
        let pauseActionEnabled: Bool
        let statusTitle: String
    }

    static func activePauseUntil(in state: State, now: Date) -> Date? {
        guard let pauseUntil = state.pauseUntil, pauseUntil > now else {
            return nil
        }
        return pauseUntil
    }

    static func isPaused(_ state: State, now: Date) -> Bool {
        activePauseUntil(in: state, now: now) != nil
    }

    static func sessionRequiresProtection(_ phase: ProtectionSessionPhase) -> Bool {
        switch phase {
        case .starting, .active, .stopping:
            return true
        case .idle:
            return false
        }
    }

    static func shouldEnableProtection(for state: State, now: Date) -> Bool {
        guard state.helperAvailable, state.licenseAllowsProtection, !isPaused(state, now: now) else {
            return false
        }
        return state.persistentProtectionEnabled || sessionRequiresProtection(state.sessionPhase)
    }

    static func presentation(for state: State, now: Date) -> MenuPresentation {
        let paused = isPaused(state, now: now)
        let desiredProtection = shouldEnableProtection(for: state, now: now)
        let protectionOnOrPending = state.effectiveProtectionEnabled || desiredProtection
        let isTransitioningSession = state.sessionPhase == .starting
            || state.sessionPhase == .stopping

        let protectionTitle: String
        if !state.helperAvailable {
            protectionTitle = "Finish Setup..."
        } else if protectionOnOrPending {
            protectionTitle = "Turn Off Ping Protection"
        } else {
            protectionTitle = "Turn On Ping Protection"
        }

        let pauseTitle: String?
        if paused {
            pauseTitle = "Resume Ping Protection"
        } else if protectionOnOrPending && !isTransitioningSession {
            pauseTitle = "Pause for 10 Minutes"
        } else {
            pauseTitle = nil
        }

        return MenuPresentation(
            protectionTitle: protectionTitle,
            protectionActionEnabled: !isTransitioningSession,
            pauseTitle: state.helperAvailable ? pauseTitle : nil,
            pauseActionEnabled: state.helperAvailable
                && pauseTitle != nil
                && !isTransitioningSession,
            statusTitle: statusTitle(
                for: state,
                paused: paused,
                desiredProtection: desiredProtection
            )
        )
    }

    private static func statusTitle(
        for state: State,
        paused: Bool,
        desiredProtection: Bool
    ) -> String {
        guard state.helperAvailable else {
            return "Status: Not Set Up"
        }
        if paused {
            return "Status: Paused"
        }

        switch state.sessionPhase {
        case .starting:
            return "Status: Starting Latency Session"
        case .stopping:
            return "Status: Ending Latency Session"
        case .active where state.effectiveProtectionEnabled:
            if state.sessionTrigger == .gameMode {
                return "Status: Protected, Game Mode Session Active"
            }
            return "Status: Protected, Latency Session Active"
        case .active:
            return "Status: Restoring Protection"
        case .idle:
            break
        }

        if desiredProtection && !state.effectiveProtectionEnabled {
            return "Status: Turning On Protection"
        }
        if !desiredProtection && state.effectiveProtectionEnabled {
            return "Status: Turning Off Protection"
        }
        return state.effectiveProtectionEnabled
            ? "Status: Protected"
            : "Status: Not Protected"
    }
}
