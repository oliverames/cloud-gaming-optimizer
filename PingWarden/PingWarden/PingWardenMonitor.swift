//
//  PingWardenMonitor.swift
//  PingWarden
//
//  Controls the AWDL helper daemon via SMAppService and XPC.
//
//  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
//  Licensed under the MIT License.
//

import Foundation
import AppKit
import ServiceManagement
import os.log

/// Unified logger for PingWardenMonitor - logs to both Console.app and file
private let log = Logger(subsystem: "com.amesvt.pingwarden", category: "Monitor")

/// Signpost for performance measurement
private let signposter = OSSignposter(subsystem: "com.amesvt.pingwarden", category: "Performance")

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// Controls the AWDL helper daemon via SMAppService and XPC
/// In v2.x, the helper runs as a bundled LaunchDaemon registered via SMAppService
/// No more password prompts - just one-time system approval
///
/// Architecture (v2.x):
/// - Helper binary bundled in Contents/MacOS/PingWardenHelper
/// - Plist bundled in Contents/Library/LaunchDaemons/com.amesvt.pingwarden.helper.plist
/// - Communication via XPC (com.amesvt.pingwarden.xpc)
/// - Helper exits when app quits (via XPC connection invalidation)
class PingWardenMonitor: @unchecked Sendable {
    static let shared = PingWardenMonitor()

    /// XPC service name - must match MachServices key in plist
    private let xpcServiceName = "com.amesvt.pingwarden.xpc"

    /// Plist filename for SMAppService - must match file in Contents/Library/LaunchDaemons/
    private let helperPlistName = "com.amesvt.pingwarden.helper.plist"

    /// Maximum time to wait for registration approval (60 seconds)
    private let registrationTimeoutSeconds: TimeInterval = 60.0

    /// Maximum XPC connection retry attempts
    private let maxXPCRetries = 3

    /// Current XPC retry count (protected by stateLock)
    private var _xpcRetryCount = 0

    /// SMAppService instance for the helper daemon
    private lazy var helperService: SMAppService = {
        return SMAppService.daemon(plistName: helperPlistName)
    }()

    /// XPC connection to the helper (use thread-safe accessor)
    private var _xpcConnection: NSXPCConnection?

    /// Lock for thread-safe access to state
    private let stateLock = NSLock()
    private var _isMonitoring = false

    /// Flag to prevent recursive registration
    private var _isRegisteringHelper = false

    /// Counter to prevent infinite registration retries
    private var _registrationAttempts = 0
    private let maxRegistrationAttempts = 3

    /// Flag to prevent re-entrant XPC invalidation handling
    private var _isHandlingInvalidation = false

    /// Monotonic command token. A newer protection request invalidates older
    /// replies so delayed XPC callbacks cannot overwrite the user's latest
    /// choice after a rapid on/off transition or reconnect.
    private var _protectionOperationGeneration: UInt64 = 0

    /// Thread-safe access to XPC connection
    private var xpcConnection: NSXPCConnection? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _xpcConnection
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _xpcConnection = newValue
        }
    }

    /// Thread-safe access to registration flag
    private var isRegisteringHelper: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isRegisteringHelper
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _isRegisteringHelper = newValue
        }
    }

    /// Thread-safe access to XPC retry count
    private var xpcRetryCount: Int {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _xpcRetryCount
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _xpcRetryCount = newValue
        }
    }

    /// Thread-safe access to monitoring state
    private var isMonitoring: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isMonitoring
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _isMonitoring = newValue
        }
    }

    /// Thread-safe registry of state-change observer callbacks.
    private let stateObservers = StateObserverRegistry()

    /// Timer for polling registration status (main-thread confined)
    private var registrationTimer: Timer?

    /// Timer for registration timeout (main-thread confined)
    private var registrationTimeoutTimer: Timer?

    /// Completion of the in-flight registration poll (main-thread confined).
    /// Held so a superseding poll can still deliver `false` to the previous
    /// caller — dropping it silently would wedge `isRegisteringHelper`.
    private var pendingRegistrationCompletion: (@Sendable (Bool) -> Void)?

    private init() {
        log.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        log.info("PingWardenMonitor v\(version) initializing (SMAppService + XPC)...")
        log.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        let status = helperService.status
        log.info("  Helper service status: \(self.statusDescription(status))")
        log.info("  XPC service name: \(self.xpcServiceName)")
        log.info("  Helper plist: \(self.helperPlistName)")

        // If helper is already registered, connect to it
        if status == .enabled {
            log.info("  Helper already enabled, connecting XPC...")
            connectXPC()

            // Check if we should restore monitoring state
            if PingWardenPreferences.shared.isMonitoringEnabled {
                log.info("  Restoring monitoring state from preferences")
                startMonitoring(persistUserPreference: false)
            }
        }

        log.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }

    // MARK: - Public API

    /// Check if helper is registered with SMAppService
    var isHelperRegistered: Bool {
        return helperService.status == .enabled
    }

    /// Check if helper needs system approval (user denied or not yet approved)
    var needsApproval: Bool {
        return helperService.status == .requiresApproval
    }

    /// Current registration status
    var registrationStatus: SMAppService.Status {
        return helperService.status
    }

    /// Check if monitoring is currently active (thread-safe)
    var isMonitoringActive: Bool {
        stateLock.lock()
        let active = _isMonitoring && _xpcConnection != nil
        stateLock.unlock()
        return active
    }

    /// Whether Ping Warden has requested protection, even if XPC is briefly
    /// reconnecting. UI that distinguishes "reconnecting" from "off" should
    /// use this alongside `isMonitoringActive`.
    var isMonitoringRequested: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isMonitoring
    }

    var isHelperConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _xpcConnection != nil
    }

    /// Adopt state that a signed extension already applied directly through
    /// the helper's authenticated XPC listener. The distributed notification
    /// that triggers this path is only a display invalidation signal and never
    /// causes a privileged command.
    func adoptExternallyAppliedMonitoringState(_ active: Bool) {
        stateLock.lock()
        _protectionOperationGeneration &+= 1
        _isMonitoring = active
        stateLock.unlock()
        notifyStateChange()
    }

    /// Register for monitor state changes. Returns a token that can be removed later.
    @discardableResult
    func addStateObserver(_ observer: @escaping @Sendable () -> Void) -> UUID {
        stateObservers.add(observer)
    }

    /// Remove a previously registered state observer.
    func removeStateObserver(_ token: UUID) {
        stateObservers.remove(token)
    }

    /// Validate that the helper binary and plist exist in the app bundle.
    /// Returns `nil` on success or a `ValidationFailure` describing the first
    /// missing/invalid piece. Logging is handled here so the underlying
    /// validator stays pure-Foundation and testable.
    private func validateHelperBundle() -> HelperBundleValidator.ValidationFailure? {
        let failure = HelperBundleValidator.validate(
            appBundlePath: Bundle.main.bundlePath,
            helperPlistName: helperPlistName
        )
        if let failure {
            log.error("Helper bundle validation failed at: \(failure.path, privacy: .public)")
        } else {
            log.debug("Helper bundle validation passed")
        }
        return failure
    }

    /// Register helper with SMAppService
    /// This triggers a one-time system approval prompt (not a password dialog)
    func registerHelper(completion: (@Sendable (Bool) -> Void)? = nil) {
        log.info("┌─────────────────────────────────────────────────────┐")
        log.info("│ registerHelper() called                             │")
        log.info("└─────────────────────────────────────────────────────┘")

        // Validate helper bundle before attempting registration
        if let failure = validateHelperBundle() {
            DispatchQueue.main.async { [weak self] in
                self?.showError(failure.userMessage)
            }
            completion?(false)
            return
        }

        let signpostID = signposter.makeSignpostID()
        let state = signposter.beginInterval("RegisterHelper", id: signpostID)

        let currentStatus = helperService.status
        log.info("Current status: \(self.statusDescription(currentStatus))")

        switch currentStatus {
        case .enabled:
            log.info("Helper already enabled")
            signposter.endInterval("RegisterHelper", state)
            connectXPC()
            completion?(true)
            return

        case .requiresApproval:
            log.info("Helper requires approval - opening System Settings")
            SMAppService.openSystemSettingsLoginItems()
            startPollingForRegistration(completion: completion)
            signposter.endInterval("RegisterHelper", state)
            return

        case .notRegistered, .notFound:
            log.info("Registering helper with SMAppService...")
            do {
                try helperService.register()
                log.info("Registration request submitted")
                // Start polling for approval
                startPollingForRegistration(completion: completion)
                signposter.endInterval("RegisterHelper", state)
            } catch let error as NSError {
                log.error("Registration failed: \(error.localizedDescription) (code: \(error.code))")
                signposter.endInterval("RegisterHelper", state)

                // Check if this is "Operation not permitted" - means user needs to approve first
                // Error domain is NSPOSIXErrorDomain with code 1 (EPERM), or
                // SMAppService may throw with domain NSCocoaErrorDomain
                let isPermissionError = error.localizedDescription.contains("Operation not permitted") ||
                                        error.localizedDescription.contains("not permitted") ||
                                        error.domain == "SMAppServiceErrorDomain" ||
                                        error.domain.contains("ServiceManagement") ||
                                        (error.domain == NSPOSIXErrorDomain && error.code == 1)

                if isPermissionError {
                    log.info("Registration requires user approval first - opening System Settings")
                    // Open System Settings to Login Items so user can approve
                    SMAppService.openSystemSettingsLoginItems()
                    // Start polling for the user to approve
                    startPollingForRegistration(completion: completion)
                } else {
                    DispatchQueue.main.async {
                        self.showError("Failed to register helper.\n\nError: \(error.localizedDescription)")
                    }
                    completion?(false)
                }
            }

        @unknown default:
            log.error("Unknown helper status: \(String(describing: currentStatus))")
            signposter.endInterval("RegisterHelper", state)
            completion?(false)
        }
    }

    /// Start monitoring - sends command to helper via XPC
    func startMonitoring(
        persistUserPreference: Bool = true,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        let operationID = beginProtectionOperation()
        startMonitoring(
            operationID: operationID,
            persistUserPreference: persistUserPreference,
            completion: completion
        )
    }

    private func startMonitoring(
        operationID: UInt64,
        persistUserPreference: Bool,
        completion: (@Sendable (Bool) -> Void)?
    ) {
        log.info("┌─────────────────────────────────────────────────────┐")
        log.info("│ startMonitoring() called                            │")
        log.info("└─────────────────────────────────────────────────────┘")

        // Check if helper is registered
        guard isHelperRegistered else {
            log.info("Helper not registered - starting registration flow")
            // Prevent recursive registration
            guard !isRegisteringHelper else {
                log.debug("Already registering helper, skipping")
                completion?(false)
                return
            }

            // Prevent infinite retry loops
            stateLock.lock()
            _registrationAttempts += 1
            let attempts = _registrationAttempts
            stateLock.unlock()

            if attempts > maxRegistrationAttempts {
                log.error("Max registration attempts (\(self.maxRegistrationAttempts)) exceeded, giving up")
                showError("Helper registration failed after multiple attempts.\n\nPlease try restarting the app or check System Settings → Login Items.")
                completion?(false)
                return
            }

            isRegisteringHelper = true
            registerHelper { [weak self] success in
                guard let self else { return }
                self.isRegisteringHelper = false
                guard self.isCurrentProtectionOperation(operationID) else {
                    completion?(false)
                    return
                }
                if success && self.isHelperRegistered {
                    // Reset attempts on success
                    self.stateLock.lock()
                    self._registrationAttempts = 0
                    self.stateLock.unlock()
                    self.startMonitoring(
                        operationID: operationID,
                        persistUserPreference: persistUserPreference,
                        completion: completion
                    )
                } else {
                    completion?(false)
                }
            }
            return
        }

        // Ensure XPC connection; connectXPC() resets the retry counter
        // internally once the helper answers a validation ping.
        if xpcConnection == nil {
            connectXPC()
        }

        // Send command to disable AWDL
        guard let proxy = getHelperProxy() else {
            log.error("Failed to get helper proxy")
            PingWardenPreferences.shared.effectiveMonitoringEnabled = false
            notifyStateChange()
            showError("Cannot connect to helper.\n\nTry restarting the app.")
            completion?(false)
            return
        }

        log.info("Sending setAWDLEnabled(false) via XPC...")

        let didComplete = LockedValue(false)
        let claimCompletion: @Sendable () -> Bool = {
            didComplete.withValue { completed in
                guard !completed else { return false }
                completed = true
                return true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard claimCompletion() else { return }
            guard let self, self.isCurrentProtectionOperation(operationID) else {
                completion?(false)
                return
            }
            log.error("Timed out while enabling Ping Protection")
            // XPC preserves message order. Queueing a compensating enable-AWDL
            // command keeps a timed-out transient request from leaving AWDL
            // blocked without a session or visible owner.
            self.stopMonitoring(persistUserPreference: false)
            PingWardenPreferences.shared.effectiveMonitoringEnabled = false
            self.notifyStateChange()
            completion?(false)
        }

        proxy.setAWDLEnabled(false, reply: { [weak self] success in
            guard let monitor = self else { return }
            DispatchQueue.main.async {
                guard claimCompletion() else { return }
                guard monitor.isCurrentProtectionOperation(operationID) else {
                    log.info("Ignoring stale enable-protection reply")
                    completion?(false)
                    return
                }
                if success {
                    monitor.isMonitoring = true
                    if persistUserPreference {
                        PingWardenPreferences.shared.isMonitoringEnabled = true
                    }
                    PingWardenPreferences.shared.effectiveMonitoringEnabled = true
                    PingWardenPreferences.shared.lastKnownState = "down"
                    monitor.notifyStateChange()
                    log.info("✅ AWDL monitoring started")
                    completion?(true)
                } else {
                    log.error("❌ Failed to disable AWDL")
                    PingWardenPreferences.shared.effectiveMonitoringEnabled = false
                    monitor.notifyStateChange()
                    monitor.showError("Failed to enable Ping Protection.\n\nThe helper may not be running correctly.")
                    completion?(false)
                }
            }
        })
    }

    /// Stop monitoring - sends command to helper via XPC
    func stopMonitoring(
        persistUserPreference: Bool = true,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        let operationID = beginProtectionOperation()
        log.info("┌─────────────────────────────────────────────────────┐")
        log.info("│ stopMonitoring() called                             │")
        log.info("└─────────────────────────────────────────────────────┘")

        if xpcConnection == nil {
            connectXPC()
        }

        guard let proxy = getHelperProxy() else {
            log.warning("No helper proxy - cannot confirm Ping Protection stopped")
            PingWardenPreferences.shared.lastKnownState = "unknown"
            notifyStateChange()
            if persistUserPreference || completion != nil {
                showError("Cannot connect to the helper to turn off Ping Protection.\n\nTry again or quit Ping Warden to restore wireless sharing.")
            }
            completion?(false)
            return
        }

        log.info("Sending setAWDLEnabled(true) via XPC...")

        let didComplete = LockedValue(false)
        let claimCompletion: @Sendable () -> Bool = {
            didComplete.withValue { completed in
                guard !completed else { return false }
                completed = true
                return true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard claimCompletion() else { return }
            guard let self, self.isCurrentProtectionOperation(operationID) else {
                completion?(false)
                return
            }
            log.error("Timed out while disabling Ping Protection")
            PingWardenPreferences.shared.lastKnownState = "unknown"
            self.notifyStateChange()
            completion?(false)
        }

        proxy.setAWDLEnabled(true, reply: { [weak self] success in
            guard let monitor = self else { return }
            DispatchQueue.main.async {
                guard monitor.isCurrentProtectionOperation(operationID) else {
                    log.info("Ignoring stale disable-protection reply")
                    if claimCompletion() { completion?(false) }
                    return
                }
                // Unlike the enable path, apply the state change even when a
                // timeout already claimed completion. The stop command is the
                // last message in flight, so a late success is the truth about
                // the radio; discarding it left _isMonitoring stuck true while
                // AirDrop was already restored. Completion is still reported
                // at most once.
                let reportCompletion = claimCompletion()
                if success {
                    monitor.isMonitoring = false
                    if persistUserPreference {
                        PingWardenPreferences.shared.isMonitoringEnabled = false
                    }
                    PingWardenPreferences.shared.effectiveMonitoringEnabled = false
                    PingWardenPreferences.shared.lastKnownState = "up"
                    monitor.notifyStateChange()
                    log.info("✅ AWDL monitoring stopped - AirDrop/Handoff available")
                } else {
                    log.error("❌ Failed to enable AWDL")
                    PingWardenPreferences.shared.lastKnownState = "unknown"
                    monitor.notifyStateChange()
                    if persistUserPreference || completion != nil {
                        monitor.showError("Failed to turn off Ping Protection.\n\nQuit Ping Warden to restore wireless sharing, then try again.")
                    }
                }
                guard reportCompletion else { return }
                completion?(success)
            }
        })
    }

    func setProtectionEnabled(
        _ enabled: Bool,
        persistUserPreference: Bool = true
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            if enabled {
                startMonitoring(persistUserPreference: persistUserPreference) { success in
                    continuation.resume(returning: success)
                }
            } else {
                stopMonitoring(persistUserPreference: persistUserPreference) { success in
                    continuation.resume(returning: success)
                }
            }
        }
    }

    /// Perform a health check on the helper.
    /// Must be called from a background thread — uses synchronous semaphore waits.
    func performHealthCheck() -> (isHealthy: Bool, message: String) {
        assert(!Thread.isMainThread, "performHealthCheck must not be called on the main thread")
        log.info("Performing health check...")

        // Check 1: Is helper registered?
        guard isHelperRegistered else {
            log.info("Health check: Helper not registered")
            return (false, "Helper not registered with system")
        }

        // Check 2: Can we connect via XPC?
        if xpcConnection == nil {
            connectXPC()
        }

        guard let proxy = getHelperProxy() else {
            log.info("Health check: Cannot connect to helper")
            return (false, "Cannot connect to helper via XPC")
        }

        // Check 3: Query helper status with proper timeout handling
        let helperStatus = LockedValue("Unknown")
        let helperVersion = LockedValue("Unknown")
        var statusTimedOut = false
        var versionTimedOut = false
        let statusSemaphore = DispatchSemaphore(value: 0)
        let versionSemaphore = DispatchSemaphore(value: 0)

        proxy.getAWDLStatus(reply: { status in
            helperStatus.withValue { $0 = status }
            statusSemaphore.signal()
        })
        if statusSemaphore.wait(timeout: .now() + 2.0) == .timedOut {
            log.warning("Health check: getAWDLStatus timed out")
            statusTimedOut = true
        }

        proxy.getVersion(reply: { version in
            helperVersion.withValue { $0 = version }
            versionSemaphore.signal()
        })
        if versionSemaphore.wait(timeout: .now() + 2.0) == .timedOut {
            log.warning("Health check: getVersion timed out")
            versionTimedOut = true
        }

        // If both timed out, helper is not responding
        if statusTimedOut && versionTimedOut {
            return (false, "Helper not responding to XPC calls (timed out)")
        }

        // Check 4: Check actual AWDL interface status
        let awdlStatus = getAWDLInterfaceStatus()
        log.debug("AWDL interface status: \(awdlStatus)")

        // Parse AWDL status - check for DOWN flag or absence of UP in flags section
        let isAWDLDown = awdlStatus.contains("<DOWN") ||
                         (awdlStatus.contains("flags=") && !awdlStatus.contains("<UP"))

        if isMonitoring && !isAWDLDown {
            log.warning("Health check: AWDL is UP despite monitoring being active")
            return (false, "Protection active but the wireless interface is still up - helper may not be functioning")
        }

        let finalHelperVersion = helperVersion.withValue { $0 }
        let protectionText = isAWDLDown
            ? "Ping Protection is on."
            : "Ping Protection is off."
        let message = "Helper connected (version \(finalHelperVersion)). \(protectionText)"
        log.info("Health check: \(message)")
        return (true, message)
    }
    
    /// Get the AWDL intervention count from the helper
    /// Returns the number of times AWDL was blocked from coming up
    func getInterventionCount(completion: @escaping @Sendable (Int?) -> Void) {
        guard let proxy = getHelperProxy() else {
            log.warning("Cannot get intervention count: No helper proxy")
            completion(nil)
            return
        }
        
        proxy.getAWDLInterventionCount(reply: { count in
            DispatchQueue.main.async {
                completion(Int(count))
            }
        })
    }

    /// Current awdl0 interface flags/status for diagnostics.
    func currentAWDLInterfaceStatus() -> String {
        getAWDLInterfaceStatus()
    }
    
    /// Reset the intervention counter in the helper
    func resetInterventionCount(completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        guard let proxy = getHelperProxy() else {
            log.warning("Cannot reset intervention count: No helper proxy")
            completion(false)
            return
        }
        
        proxy.resetAWDLInterventionCount(reply: { success in
            DispatchQueue.main.async {
                if success {
                    log.info("Intervention counter reset successfully")
                }
                completion(success)
            }
        })
    }

    // MARK: - Compatibility Checks

    /// Legacy check - now checks SMAppService status
    func isDaemonInstalled() -> Bool {
        return isHelperRegistered
    }

    /// Legacy check - now checks XPC connection
    func isDaemonVersionCompatible() -> Bool {
        // In v2.x, version is always compatible since helper is bundled
        return isHelperRegistered
    }

    // MARK: - XPC Connection Management

    private func beginProtectionOperation() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        _protectionOperationGeneration &+= 1
        return _protectionOperationGeneration
    }

    private func isCurrentProtectionOperation(_ operationID: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operationID == _protectionOperationGeneration
    }

    /// Atomically increment the XPC retry counter and return the new value.
    /// Using a single locked read-modify-write avoids the race window that a
    /// `xpcRetryCount += 1` through the property accessor would open between
    /// the read and the write.
    @discardableResult
    private func incrementXPCRetryCount() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        _xpcRetryCount += 1
        return _xpcRetryCount
    }

    /// Connect to helper via XPC
    private func connectXPC() {
        log.debug("Connecting to XPC service: \(self.xpcServiceName)")

        // Use .privileged for daemon registered via SMAppService
        // This is required because the daemon runs as root
        let connection = NSXPCConnection(machServiceName: xpcServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PingWardenHelperProtocol.self)

        connection.interruptionHandler = { [weak self] in
            log.warning("XPC connection interrupted")
            let monitor = self
            DispatchQueue.main.async {
                monitor?.handleXPCInterruption()
            }
        }

        let connectionID = ObjectIdentifier(connection)
        connection.invalidationHandler = { [weak self] in
            log.warning("XPC connection invalidated")
            let monitor = self
            DispatchQueue.main.async {
                monitor?.handleXPCInvalidation(for: connectionID)
            }
        }

        connection.activate()

        stateLock.lock()
        let previousConnection = _xpcConnection
        _xpcConnection = connection
        stateLock.unlock()

        previousConnection?.invalidate()

        log.info("XPC connection activated")

        // Validate connection asynchronously to avoid blocking UI paths.
        // The retry counter is reset only here, once the helper has actually
        // answered — activate() succeeding locally proves nothing about the
        // daemon. Resetting after activate() would let a dead helper produce
        // an infinite reconnect loop that never trips the max-retry cap.
        validateXPCConnection { [weak self] isValid in
            guard let self else { return }
            if isValid {
                self.xpcRetryCount = 0
                self.reassertMonitoringStateIfNeeded()
            }
        }
    }

    /// Validate XPC connection is actually working
    private func validateXPCConnection(completion: (@Sendable (Bool) -> Void)? = nil) {
        guard let proxy = getHelperProxy() else {
            log.warning("XPC validation: No proxy available")
            completion?(false)
            return
        }

        let didComplete = LockedValue(false)

        let finish: @Sendable (Bool) -> Bool = { isValid in
            let shouldFinish = didComplete.withValue { value in
                guard !value else { return false }
                value = true
                return true
            }
            guard shouldFinish else { return false }
            completion?(isValid)
            return true
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
            if finish(false) {
                log.warning("XPC validation: Connection timeout - helper may not be running")
            }
        }

        proxy.getVersion(reply: { version in
            if version.isEmpty {
                log.warning("XPC validation: Invalid response from helper")
                _ = finish(false)
            } else {
                log.debug("XPC validation: Connection verified successfully")
                _ = finish(true)
            }
        })
    }

    private func reassertMonitoringStateIfNeeded() {
        let shouldReassert = isMonitoring
        guard shouldReassert else {
            return
        }

        guard let proxy = getHelperProxy() else {
            log.warning("Skipping reassert: helper proxy unavailable")
            return
        }

        log.info("Reasserting AWDL blocking state after XPC reconnect")
        proxy.setAWDLEnabled(false, reply: { [weak self] success in
            guard let monitor = self else { return }
            DispatchQueue.main.async {
                // A stopMonitoring() may have raced the reassert; don't
                // stamp "protection on" state over the user's fresh stop.
                guard monitor.isMonitoring else {
                    log.info("Skipping reassert completion: monitoring was stopped meanwhile")
                    return
                }
                if success {
                    PingWardenPreferences.shared.effectiveMonitoringEnabled = true
                    PingWardenPreferences.shared.lastKnownState = "down"
                    monitor.notifyStateChange()
                } else {
                    log.error("Failed to reassert AWDL blocking state after reconnect")
                }
            }
        })
    }

    /// Handle XPC interruption (temporary disconnect)
    private func handleXPCInterruption() {
        // Interruption is recoverable - the connection can be resumed
        log.info("XPC interruption - connection may recover automatically")
    }

    /// Handle XPC invalidation (permanent disconnect)
    private func handleXPCInvalidation(for invalidatedConnectionID: ObjectIdentifier? = nil) {
        // Prevent re-entrant handling
        stateLock.lock()
        // Idempotency: a single helper drop fires BOTH the connection's
        // invalidationHandler and any in-flight remoteObjectProxyWithErrorHandler.
        // Each arrives as its own main-queue block, so `_isHandlingInvalidation`
        // (reset via defer before the second block runs) cannot dedupe across
        // them. If the connection was already torn down by the first handler,
        // the second must not run again and burn a second XPC retry slot —
        // which would surface "Lost connection" after 2 drops instead of 3.
        if invalidatedConnectionID != nil, _xpcConnection == nil {
            stateLock.unlock()
            log.debug("Ignoring duplicate XPC invalidation; connection already torn down")
            return
        }
        if let invalidatedConnectionID,
           let currentConnection = _xpcConnection,
           ObjectIdentifier(currentConnection) != invalidatedConnectionID {
            stateLock.unlock()
            log.debug("Ignoring stale XPC invalidation from a replaced connection")
            return
        }

        if _isHandlingInvalidation {
            stateLock.unlock()
            log.debug("Already handling XPC invalidation, skipping")
            return
        }
        _isHandlingInvalidation = true
        let abandonedConnection = _xpcConnection
        _xpcConnection = nil
        let wasMonitoring = _isMonitoring
        stateLock.unlock()

        // When this path is reached from a proxy error handler (not the
        // connection's own invalidationHandler), the connection object is
        // still live in the XPC runtime. Invalidate it explicitly or it —
        // and its mach resources and handler blocks — leak for the app's
        // lifetime. invalidate() is an idempotent no-op on an
        // already-invalidated connection.
        abandonedConnection?.invalidate()

        if wasMonitoring {
            PingWardenPreferences.shared.effectiveMonitoringEnabled = false
            notifyStateChange()
        }

        defer {
            stateLock.lock()
            _isHandlingInvalidation = false
            stateLock.unlock()
        }

        // If we were monitoring, try to reconnect with exponential backoff.
        // Snapshot the new retry count from a single atomic increment and use
        // the local for every read below, so we never see a torn value.
        if wasMonitoring {
            let currentRetry = incrementXPCRetryCount()
            if currentRetry <= maxXPCRetries {
                let delay = XPCReconnectPolicy.delayForAttempt(currentRetry)
                log.info("Attempting XPC reconnect in \(delay)s (attempt \(currentRetry)/\(self.maxXPCRetries))")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.connectXPC()
                }
            } else {
                log.error("Max XPC retry attempts exceeded")
                stateLock.lock()
                _isMonitoring = false
                stateLock.unlock()
                PingWardenPreferences.shared.effectiveMonitoringEnabled = false
                notifyStateChange()
                showError("Lost connection to helper.\n\nPlease restart the app.")
            }
        } else {
            PingWardenPreferences.shared.effectiveMonitoringEnabled = false
            notifyStateChange()
        }
    }

    /// Get the helper proxy for making XPC calls (thread-safe)
    /// Uses remoteObjectProxyWithErrorHandler to properly handle XPC errors
    private func getHelperProxy() -> PingWardenHelperProtocol? {
        // Get connection under lock to avoid TOCTOU race
        stateLock.lock()
        let currentConnection = _xpcConnection
        stateLock.unlock()

        guard let xpc = currentConnection else {
            log.warning("No XPC connection available")
            return nil
        }

        let xpcID = ObjectIdentifier(xpc)
        return xpc.remoteObjectProxyWithErrorHandler { [weak self] error in
            log.error("XPC proxy error: \(error.localizedDescription)")
            let monitor = self
            DispatchQueue.main.async {
                monitor?.handleXPCInvalidation(for: xpcID)
            }
        } as? PingWardenHelperProtocol
    }

    // MARK: - Registration Polling

    /// Poll for registration status change with timeout.
    /// Timer state and the pending completion are main-thread confined:
    /// callers can reach this from any thread (the singleton's init runs on
    /// whichever thread first touches `shared`), and a Timer scheduled on a
    /// background thread's never-spun run loop would simply never fire.
    private func startPollingForRegistration(completion: (@Sendable (Bool) -> Void)?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.startPollingForRegistration(completion: completion)
            }
            return
        }

        log.debug("Starting registration polling (timeout: \(self.registrationTimeoutSeconds)s)...")

        // A superseded poll must still deliver its completion — callers
        // (e.g. startMonitoring's isRegisteringHelper flag) wait on it.
        finishRegistrationPolling(success: false, reason: "superseded by a new registration poll")
        pendingRegistrationCompletion = completion

        // Set up timeout timer
        registrationTimeoutTimer = Timer.scheduledTimer(withTimeInterval: registrationTimeoutSeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            log.warning("Registration polling timed out after \(self.registrationTimeoutSeconds)s")
            self.showError("Registration timed out.\n\nPlease approve the helper in System Settings → Login Items and try again.")
            self.finishRegistrationPolling(success: false, reason: "timed out")
        }

        // Set up polling timer
        registrationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            let status = self.helperService.status
            log.debug("Polling: status = \(self.statusDescription(status))")

            switch status {
            case .enabled:
                log.info("✅ Helper registration approved")
                self.connectXPC()
                self.finishRegistrationPolling(success: true, reason: "approved")

            case .notRegistered:
                log.info("❌ Helper registration denied")
                self.finishRegistrationPolling(success: false, reason: "denied")

            case .requiresApproval, .notFound:
                // Keep polling
                break

            @unknown default:
                break
            }
        }
    }

    /// Tear down the polling timers and deliver the pending completion
    /// exactly once. Main-thread only.
    private func finishRegistrationPolling(success: Bool, reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        registrationTimer?.invalidate()
        registrationTimer = nil
        registrationTimeoutTimer?.invalidate()
        registrationTimeoutTimer = nil

        guard let completion = pendingRegistrationCompletion else { return }
        pendingRegistrationCompletion = nil
        log.debug("Registration polling finished (\(reason, privacy: .public))")
        completion(success)
    }

    // MARK: - Helper Methods

    private func notifyStateChange() {
        // Snapshot under the registry's own lock, then deliver outside it so
        // observers may freely call back into add/remove during their callback.
        let observers = stateObservers.snapshot()
        DispatchQueue.main.async {
            observers.forEach { $0() }
            NotificationCenter.default.post(name: .awdlMonitorStateChanged, object: nil)
        }
    }

    /// Get human-readable status description
    private func statusDescription(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "Not Registered"
        case .enabled: return "Enabled"
        case .requiresApproval: return "Requires Approval"
        case .notFound: return "Not Found"
        @unknown default: return "Unknown"
        }
    }

    /// Get current AWDL interface status via ifconfig
    private func getAWDLInterfaceStatus() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        task.arguments = ["awdl0"]

        let pipe = Pipe()
        task.standardOutput = pipe
        // Discard stderr so its pipe buffer can never fill up and block ifconfig.
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            // Read until EOF first; the pipe closes when the subprocess exits,
            // so the read unblocks at the same moment waitUntilExit would. The
            // reverse order (wait, then read) can deadlock if a subprocess
            // ever writes enough output to fill the pipe buffer.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""

            if let flagsLine = output.components(separatedBy: "\n").first(where: { $0.contains("flags=") }) {
                return flagsLine
            }
            return output
        } catch {
            log.error("Error getting AWDL status: \(error.localizedDescription)")
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Show error alert
    private func showError(_ message: String) {
        log.error("Showing error: \(message)")
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Error"
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
