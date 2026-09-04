import Foundation
import XCTest
@testable import PingWardenCore

final class ProtectionExperiencePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testExpiredLicenseBlocksEveryReconciliationPhase() {
        for phase in ProtectionSessionPhase.allCases {
            var state = makeState(persistentProtectionEnabled: true, sessionPhase: phase)
            state.licenseAllowsProtection = false
            XCTAssertFalse(ProtectionExperiencePolicy.shouldEnableProtection(for: state, now: now))
            state.pauseUntil = now.addingTimeInterval(-1)
            XCTAssertFalse(ProtectionExperiencePolicy.shouldEnableProtection(for: state, now: now))
            state.persistentProtectionEnabled = false
            XCTAssertFalse(ProtectionExperiencePolicy.shouldEnableProtection(for: state, now: now))
        }
    }

    func testSessionStartingOrActiveRequiresTemporaryProtection() {
        var state = makeState(sessionPhase: .starting, sessionTrigger: .manual)
        XCTAssertTrue(ProtectionExperiencePolicy.shouldEnableProtection(for: state, now: now))

        state.sessionPhase = .active
        XCTAssertTrue(ProtectionExperiencePolicy.shouldEnableProtection(for: state, now: now))

        state.sessionPhase = .stopping
        XCTAssertTrue(ProtectionExperiencePolicy.shouldEnableProtection(for: state, now: now))

        state.sessionPhase = .idle
        state.sessionTrigger = nil
        XCTAssertFalse(ProtectionExperiencePolicy.shouldEnableProtection(for: state, now: now))
    }

    func testPersistentIntentKeepsProtectionOnAfterSessionEnds() {
        let state = makeState(
            persistentProtectionEnabled: true,
            sessionPhase: .idle
        )

        XCTAssertTrue(ProtectionExperiencePolicy.shouldEnableProtection(for: state, now: now))
    }

    func testCurrentPersistentIntentWinsInsteadOfAStaleSessionSnapshot() {
        var state = makeState(sessionPhase: .active, sessionTrigger: .manual)
        state.persistentProtectionEnabled = true
        state.sessionPhase = .idle
        state.sessionTrigger = nil

        XCTAssertTrue(ProtectionExperiencePolicy.shouldEnableProtection(for: state, now: now))

        state.persistentProtectionEnabled = false
        XCTAssertFalse(ProtectionExperiencePolicy.shouldEnableProtection(for: state, now: now))
    }

    func testActivePauseOverridesPersistentAndSessionReasons() {
        let pauseUntil = now.addingTimeInterval(600)
        let state = makeState(
            persistentProtectionEnabled: true,
            sessionPhase: .active,
            sessionTrigger: .manual,
            pauseUntil: pauseUntil
        )

        XCTAssertEqual(
            ProtectionExperiencePolicy.activePauseUntil(in: state, now: now),
            pauseUntil
        )
        XCTAssertTrue(ProtectionExperiencePolicy.isPaused(state, now: now))
        XCTAssertFalse(ProtectionExperiencePolicy.shouldEnableProtection(for: state, now: now))
    }

    func testExpiredPauseNoLongerOverridesProtectionReasons() {
        let state = makeState(
            persistentProtectionEnabled: true,
            pauseUntil: now.addingTimeInterval(-1)
        )

        XCTAssertNil(ProtectionExperiencePolicy.activePauseUntil(in: state, now: now))
        XCTAssertFalse(ProtectionExperiencePolicy.isPaused(state, now: now))
        XCTAssertTrue(ProtectionExperiencePolicy.shouldEnableProtection(for: state, now: now))
    }

    func testHelperUnavailableAlwaysPreventsProtection() {
        let state = makeState(
            helperAvailable: false,
            persistentProtectionEnabled: true,
            sessionPhase: .active,
            sessionTrigger: .manual
        )

        XCTAssertFalse(ProtectionExperiencePolicy.shouldEnableProtection(for: state, now: now))
    }

    func testOffMenuPresentation() {
        let presentation = ProtectionExperiencePolicy.presentation(
            for: makeState(),
            now: now
        )

        XCTAssertEqual(presentation.protectionTitle, "Turn On Ping Protection")
        XCTAssertNil(presentation.pauseTitle)
        XCTAssertEqual(presentation.statusTitle, "Status: Not Protected")
    }

    func testOnMenuPresentationUsesOnePauseAction() {
        let presentation = ProtectionExperiencePolicy.presentation(
            for: makeState(
                persistentProtectionEnabled: true,
                effectiveProtectionEnabled: true
            ),
            now: now
        )

        XCTAssertEqual(presentation.protectionTitle, "Turn Off Ping Protection")
        XCTAssertEqual(presentation.pauseTitle, "Pause for 10 Minutes")
        XCTAssertTrue(presentation.pauseActionEnabled)
        XCTAssertEqual(presentation.statusTitle, "Status: Protected")
    }

    func testPausedMenuPresentationReplacesPauseWithResume() {
        let presentation = ProtectionExperiencePolicy.presentation(
            for: makeState(
                persistentProtectionEnabled: true,
                pauseUntil: now.addingTimeInterval(600)
            ),
            now: now
        )

        XCTAssertEqual(presentation.protectionTitle, "Turn On Ping Protection")
        XCTAssertEqual(presentation.pauseTitle, "Resume Ping Protection")
        XCTAssertTrue(presentation.pauseActionEnabled)
        XCTAssertEqual(presentation.statusTitle, "Status: Paused")
    }

    func testActiveSessionStatusExplainsWhyProtectionIsActive() {
        let presentation = ProtectionExperiencePolicy.presentation(
            for: makeState(
                effectiveProtectionEnabled: true,
                sessionPhase: .active,
                sessionTrigger: .manual
            ),
            now: now
        )

        XCTAssertEqual(presentation.protectionTitle, "Turn Off Ping Protection")
        XCTAssertEqual(presentation.pauseTitle, "Pause for 10 Minutes")
        XCTAssertEqual(presentation.statusTitle, "Status: Protected, Latency Session Active")
    }

    func testGameModeSessionStatusNamesItsOwner() {
        let presentation = ProtectionExperiencePolicy.presentation(
            for: makeState(
                effectiveProtectionEnabled: true,
                sessionPhase: .active,
                sessionTrigger: .gameMode
            ),
            now: now
        )

        XCTAssertEqual(presentation.statusTitle, "Status: Protected, Game Mode Session Active")
    }

    func testStartingAndStoppingDescribeTheSessionTransition() {
        var state = makeState(sessionPhase: .starting, sessionTrigger: .manual)
        var presentation = ProtectionExperiencePolicy.presentation(for: state, now: now)
        XCTAssertEqual(presentation.statusTitle, "Status: Starting Latency Session")

        state.effectiveProtectionEnabled = true
        state.sessionPhase = .stopping
        presentation = ProtectionExperiencePolicy.presentation(for: state, now: now)
        XCTAssertEqual(presentation.statusTitle, "Status: Ending Latency Session")
    }

    func testNotSetUpMenuPresentationOffersSetup() {
        let presentation = ProtectionExperiencePolicy.presentation(
            for: makeState(helperAvailable: false),
            now: now
        )

        XCTAssertEqual(presentation.statusTitle, "Status: Not Set Up")
        XCTAssertEqual(presentation.protectionTitle, "Finish Setup...")
        XCTAssertTrue(presentation.protectionActionEnabled)
        XCTAssertNil(presentation.pauseTitle)
    }

    func testDesiredAndEffectiveMismatchHasHonestStatus() {
        var state = makeState(persistentProtectionEnabled: true)
        var presentation = ProtectionExperiencePolicy.presentation(for: state, now: now)
        XCTAssertEqual(presentation.statusTitle, "Status: Turning On Protection")

        state.persistentProtectionEnabled = false
        state.effectiveProtectionEnabled = true
        presentation = ProtectionExperiencePolicy.presentation(for: state, now: now)
        XCTAssertEqual(presentation.statusTitle, "Status: Turning Off Protection")
    }

    private func makeState(
        helperAvailable: Bool = true,
        persistentProtectionEnabled: Bool = false,
        effectiveProtectionEnabled: Bool = false,
        sessionPhase: ProtectionSessionPhase = .idle,
        sessionTrigger: ProtectedSessionTrigger? = nil,
        pauseUntil: Date? = nil
    ) -> ProtectionExperiencePolicy.State {
        .init(
            helperAvailable: helperAvailable,
            persistentProtectionEnabled: persistentProtectionEnabled,
            effectiveProtectionEnabled: effectiveProtectionEnabled,
            sessionPhase: sessionPhase,
            sessionTrigger: sessionTrigger,
            pauseUntil: pauseUntil
        )
    }
}
