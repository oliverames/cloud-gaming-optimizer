import Foundation
import os.log

private let protectionExperienceLog = Logger(
    subsystem: "com.amesvt.pingwarden",
    category: "ProtectionExperience"
)

@MainActor
final class ProtectionExperienceCoordinator: ObservableObject {
    static let shared = ProtectionExperienceCoordinator()

    enum Transition: Equatable {
        case idle
        case enablingProtection
        case disablingProtection
    }

    @Published private(set) var pauseUntil: Date?
    @Published private(set) var transition: Transition = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var gameModeActive = false

    private let monitor = PingWardenMonitor.shared
    private let preferences = PingWardenPreferences.shared
    private let session = ProtectedSessionCoordinator.shared
    private let license = LicenseManager.shared
    private var pauseTimer: Timer?
    private var actionGeneration = 0
    private var gameModeGeneration = 0
    private var requestedSessionTrigger: ProtectedSessionTrigger?

    private init() {
        restorePersistedPauseIfActive()
    }

    var isBusy: Bool {
        transition != .idle || session.isTransitioning
    }

    /// Whether a pause is in effect right now. A persisted pause restored at
    /// launch outranks the stored protection intent until it expires.
    var isPauseActive: Bool {
        pauseUntil.map { $0 > Date() } ?? false
    }

    var policyState: ProtectionExperiencePolicy.State {
        ProtectionExperiencePolicy.State(
            helperAvailable: monitor.isHelperRegistered,
            persistentProtectionEnabled: preferences.isMonitoringEnabled,
            effectiveProtectionEnabled: monitor.isMonitoringActive,
            sessionPhase: session.phase,
            sessionTrigger: session.activeTrigger,
            pauseUntil: pauseUntil,
            licenseAllowsProtection: license.canEnableProtection
        )
    }

    func menuPresentation(now: Date = Date()) -> ProtectionExperiencePolicy.MenuPresentation {
        let base = ProtectionExperiencePolicy.presentation(for: policyState, now: now)
        switch transition {
        case .idle:
            return base
        case .enablingProtection:
            return ProtectionExperiencePolicy.MenuPresentation(
                protectionTitle: "Turning On Ping Protection...",
                protectionActionEnabled: false,
                pauseTitle: nil,
                pauseActionEnabled: false,
                statusTitle: "Status: Turning On Protection"
            )
        case .disablingProtection:
            return ProtectionExperiencePolicy.MenuPresentation(
                protectionTitle: "Turning Off Ping Protection...",
                protectionActionEnabled: false,
                pauseTitle: nil,
                pauseActionEnabled: false,
                statusTitle: "Status: Turning Off Protection"
            )
        }
    }

    func refreshFromMonitor() {
        objectWillChange.send()

        guard transition == .idle,
              session.isActive,
              !monitor.isMonitoringActive else {
            return
        }

        Task {
            await endSession(
                reason: .protectionFailed,
                protectionWasInterrupted: true
            )
        }
    }

    /// Called after a license re-verification settles. A revoked or
    /// invalid license while protection is actively enabled turns
    /// protection off immediately; the user sees why in the menu and
    /// Settings. An unreachable API never triggers this: the offline
    /// grace window in LicensePolicy covers that case.
    func handleLicenseReverification() async {
        objectWillChange.send()

        if license.canEnableProtection {
            if lastError?.localizedCaseInsensitiveContains("license") == true {
                lastError = nil
            }
            return
        }

        // Also cancel an enable whose helper reply has not arrived yet.
        guard monitor.isMonitoringActive || monitor.isMonitoringRequested || preferences.isMonitoringEnabled || isBusy else { return }

        actionGeneration += 1
        let generation = actionGeneration
        clearPause()
        if session.phase != .idle {
            requestedSessionTrigger = nil
            await session.stop(
                endReason: .protectionTurnedOff,
                protectionWasInterrupted: true
            )
        }
        guard generation == actionGeneration, !license.canEnableProtection else { return }
        transition = .disablingProtection
        let success = await monitor.setProtectionEnabled(
            false,
            persistUserPreference: true
        )
        guard generation == actionGeneration else { return }
        transition = .idle
        guard !license.canEnableProtection else {
            lastError = nil
            objectWillChange.send()
            return
        }
        lastError = success
            ? "The license for Ping Protection is no longer valid, so protection turned off. Enter a valid license key in Settings → License."
            : "The license for Ping Protection is no longer valid, and it could not turn off cleanly. Quit Ping Warden to restore wireless sharing."
        objectWillChange.send()
    }

    /// Called at launch when the persisted protection intent survived
    /// but the entitlement did not (transition ended, refund, forged
    /// preference). The monitor already refused to restore AWDL-down;
    /// this clears the stale intent so the menu does not claim
    /// protection is on, and tells the user why.
    func noteLaunchLicenseGate() {
        preferences.isMonitoringEnabled = false
        lastError = license.grandfatherWindowExpired
            ? "The transition period has ended, so Ping Protection stayed off. Enter a license key in Settings → License to turn it back on. Donated before? Email \(LicenseManager.donationConversionEmail)."
            : "Ping Protection stayed off because it requires a license. Enter your key in Settings → License. Donated before? Email \(LicenseManager.donationConversionEmail)."
        objectWillChange.send()
    }

    @discardableResult
    func setPersistentProtection(_ enabled: Bool) async -> Bool {
        // The license gate covers every path that would put AWDL down:
        // persistent toggles, latency sessions, Game Mode, and launch
        // reconciliation all funnel through the two entry points below.
        if enabled, !license.canEnableProtection {
            lastError = license.grandfatherWindowExpired
                ? "The transition period has ended. Enter a license key in Settings → License to keep Ping Protection. Donated before? Email \(LicenseManager.donationConversionEmail)."
                : "Ping Protection requires a license. Enter your key in Settings → License. Donated before? Email \(LicenseManager.donationConversionEmail)."
            objectWillChange.send()
            return false
        }

        actionGeneration += 1
        let generation = actionGeneration
        lastError = nil
        clearPause()

        if !enabled, session.phase != .idle {
            requestedSessionTrigger = nil
            await session.stop(
                endReason: .protectionTurnedOff,
                protectionWasInterrupted: false
            )
            guard generation == actionGeneration else { return false }
        }

        if enabled, monitor.isMonitoringActive {
            preferences.isMonitoringEnabled = true
            objectWillChange.send()
            return true
        }

        if !enabled,
           !monitor.isMonitoringRequested,
           !monitor.isMonitoringActive,
           preferences.lastKnownState == "up" {
            preferences.isMonitoringEnabled = false
            objectWillChange.send()
            return true
        }

        transition = enabled ? .enablingProtection : .disablingProtection
        let success = await monitor.setProtectionEnabled(
            enabled,
            persistUserPreference: true
        )
        guard generation == actionGeneration else {
            // A newer action or an externally applied state owns the outcome.
            // Release the transition only if no newer action has claimed it,
            // otherwise leaving it set wedges every protection control.
            if transition == (enabled ? .enablingProtection : .disablingProtection) {
                transition = .idle
            }
            objectWillChange.send()
            return success
        }

        transition = .idle
        if !success {
            lastError = enabled
                ? "Ping Protection could not turn on. Run the helper test in Advanced settings."
                : "Ping Protection could not turn off. Quit Ping Warden to restore wireless sharing, then try again."
        }
        objectWillChange.send()
        return success
    }

    @discardableResult
    func startManualSession() async -> Bool {
        await startSession(trigger: .manual, gameModeRequest: nil)
    }

    func endManualSession() async {
        await endSession(reason: .endedByUser, protectionWasInterrupted: false)
    }

    func pauseForTenMinutes() async {
        guard monitor.isHelperRegistered else { return }
        actionGeneration += 1
        let generation = actionGeneration
        lastError = nil

        if session.phase != .idle {
            requestedSessionTrigger = nil
            await session.stop(
                endReason: .protectionPaused,
                protectionWasInterrupted: false
            )
            guard generation == actionGeneration else { return }
        }

        pauseUntil = Date().addingTimeInterval(10 * 60)
        preferences.protectionPauseUntil = pauseUntil
        schedulePauseTimer()
        transition = .disablingProtection
        let success = await monitor.setProtectionEnabled(
            false,
            persistUserPreference: false
        )
        if generation != actionGeneration {
            // Superseded while the disable was in flight, for example by a
            // widget-driven state change. The winner owns both the radio and
            // the UI; stay quiet instead of reporting a failure the user
            // did not cause.
            if transition == .disablingProtection {
                transition = .idle
            }
            objectWillChange.send()
            return
        }
        transition = .idle
        if !success {
            clearPause()
            lastError = "Ping Protection could not pause. Quit Ping Warden to restore wireless sharing, then try again."
        }
        objectWillChange.send()
    }

    func resumeProtection() async {
        clearPause()
        lastError = nil

        if gameModeActive, session.phase == .idle {
            _ = await startSession(
                trigger: .gameMode,
                gameModeRequest: gameModeGeneration
            )
            return
        }

        await reconcileProtection()
    }

    func setGameModeActive(_ active: Bool) async {
        gameModeGeneration += 1
        let request = gameModeGeneration
        gameModeActive = active

        if active {
            guard !ProtectionExperiencePolicy.isPaused(policyState, now: Date()),
                  session.phase == .idle else {
                return
            }
            _ = await startSession(trigger: .gameMode, gameModeRequest: request)
            return
        }

        if session.activeTrigger == .gameMode
            || (session.phase == .starting && requestedSessionTrigger == .gameMode) {
            await endSession(reason: .gameModeEnded, protectionWasInterrupted: false)
        } else {
            await reconcileProtection()
        }
    }

    func handleExternallyAppliedProtectionState(_ enabled: Bool) async {
        // A user toggle's XPC reply writes the shared preference, which loops
        // back here through the distributed notification. A signal that
        // agrees with the in-flight transition is that action's own echo:
        // bumping the generation would stale the awaiting action and strand
        // `transition` non-idle, disabling every protection control.
        if isEchoOfInFlightTransition(enabled) { return }
        actionGeneration += 1
        lastError = nil
        clearPause()
        // The external writer owns the radio now; release any transition a
        // superseded local action left behind so the UI stays interactive.
        transition = .idle
        monitor.adoptExternallyAppliedMonitoringState(enabled)

        if !enabled, session.phase != .idle {
            requestedSessionTrigger = nil
            await session.stop(
                endReason: .protectionTurnedOff,
                protectionWasInterrupted: true
            )
        }

        objectWillChange.send()
    }

    private func isEchoOfInFlightTransition(_ enabled: Bool) -> Bool {
        switch transition {
        case .idle:
            return false
        case .enablingProtection:
            return enabled
        case .disablingProtection:
            return !enabled
        }
    }

    func finishForTermination() {
        // Keep the persisted pause: quitting mid-pause expresses no new
        // intent, so a relaunch inside the window must stay paused.
        clearPause(persistStoredPause: false)
        session.finishForTermination()
        if monitor.isMonitoringRequested || monitor.isMonitoringActive {
            // The app cannot wait for an asynchronous XPC reply while AppKit
            // is terminating. Publish the safe visible state immediately;
            // the stop command below restores AWDL now, and the helper also
            // guarantees restoration when its final connection closes.
            preferences.effectiveMonitoringEnabled = false
            preferences.lastKnownState = "unknown"
            monitor.stopMonitoring(persistUserPreference: false)
        }
    }

    @discardableResult
    private func startSession(
        trigger: ProtectedSessionTrigger,
        gameModeRequest: Int?
    ) async -> Bool {
        if !license.canEnableProtection {
            lastError = license.grandfatherWindowExpired
                ? "The transition period has ended. Enter a license key in Settings → License to keep Ping Protection. Donated before? Email \(LicenseManager.donationConversionEmail)."
                : "Ping Protection requires a license. Enter your key in Settings → License. Donated before? Email \(LicenseManager.donationConversionEmail)."
            objectWillChange.send()
            return false
        }

        guard monitor.isHelperRegistered, session.phase == .idle else {
            lastError = monitor.isHelperRegistered
                ? nil
                : "Finish Ping Protection setup before recording a latency session."
            return false
        }

        actionGeneration += 1
        let generation = actionGeneration
        requestedSessionTrigger = trigger
        lastError = nil
        clearPause()

        if !monitor.isMonitoringActive {
            transition = .enablingProtection
            let enabled = await monitor.setProtectionEnabled(
                true,
                persistUserPreference: false
            )
            transition = .idle
            guard enabled else {
                requestedSessionTrigger = nil
                lastError = "Ping Protection could not turn on, so the latency session did not start."
                return false
            }
        }

        guard generation == actionGeneration else {
            requestedSessionTrigger = nil
            await reconcileProtection()
            return false
        }

        if let gameModeRequest,
           (!gameModeActive || gameModeRequest != gameModeGeneration) {
            requestedSessionTrigger = nil
            await reconcileProtection()
            return false
        }

        await session.start(trigger: trigger)
        requestedSessionTrigger = nil
        let started = session.isActive
        if !started {
            lastError = session.lastError ?? "The latency session did not start."
            await reconcileProtection()
        }
        objectWillChange.send()
        return started
    }

    private func endSession(
        reason: ProtectedSessionEndReason,
        protectionWasInterrupted: Bool
    ) async {
        actionGeneration += 1
        requestedSessionTrigger = nil
        await session.stop(
            endReason: reason,
            protectionWasInterrupted: protectionWasInterrupted
        )
        await reconcileProtection()
        objectWillChange.send()
    }

    private func reconcileProtection() async {
        let shouldEnable = ProtectionExperiencePolicy.shouldEnableProtection(
            for: policyState,
            now: Date()
        )

        if shouldEnable == monitor.isMonitoringActive,
           shouldEnable == monitor.isMonitoringRequested {
            return
        }

        transition = shouldEnable ? .enablingProtection : .disablingProtection
        let success = await monitor.setProtectionEnabled(
            shouldEnable,
            persistUserPreference: false
        )
        transition = .idle
        if !success {
            lastError = shouldEnable
                ? "Ping Protection could not turn on."
                : "Ping Protection could not turn off."
            protectionExperienceLog.error("Could not reconcile protection state to \(shouldEnable)")
        }
    }

    private func schedulePauseTimer() {
        pauseTimer?.invalidate()
        guard let pauseUntil else { return }

        let timer = Timer.scheduledTimer(
            withTimeInterval: max(0, pauseUntil.timeIntervalSinceNow),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.resumeProtection()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        pauseTimer = timer
    }

    private func clearPause(persistStoredPause: Bool = true) {
        pauseTimer?.invalidate()
        pauseTimer = nil
        pauseUntil = nil
        if persistStoredPause {
            preferences.protectionPauseUntil = nil
        }
    }

    /// Restore a pause that was active when the app last quit or crashed, so
    /// an expiring ten-minute window is not cut short by a relaunch. Expired
    /// leftovers are cleared; protection state itself reconciles elsewhere.
    private func restorePersistedPauseIfActive() {
        guard let stored = preferences.protectionPauseUntil else { return }
        if stored > Date() {
            protectionExperienceLog.info("Restoring protection pause until \(stored, privacy: .public)")
            pauseUntil = stored
            schedulePauseTimer()
        } else {
            preferences.protectionPauseUntil = nil
        }
    }
}
