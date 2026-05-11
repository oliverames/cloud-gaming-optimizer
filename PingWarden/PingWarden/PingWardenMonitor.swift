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

/// Controls the AWDL helper daemon via SMAppService and XPC
/// In v2.x, the helper runs as a bundled LaunchDaemon registered via SMAppService
/// No more password prompts - just one-time system approval
///
/// Architecture (v2.x):
/// - Helper binary bundled in Contents/MacOS/PingWardenHelper
/// - Plist bundled in Contents/Library/LaunchDaemons/com.amesvt.pingwarden.helper.plist
/// - Communication via XPC (com.amesvt.pingwarden.xpc)
/// - Helper exits when app quits (via XPC connection invalidation)
class PingWardenMonitor {
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
            _isRegisteringHelper = newValue
            stateLock.unlock()
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
            _xpcRetryCount = newValue
            stateLock.unlock()
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
            _isMonitoring = newValue
            stateLock.unlock()
        }
    }

    /// Thread-safe registry of state-change observer callbacks.
    private let stateObservers = StateObserverRegistry()

    /// Timer for polling registration status
    private var registrationTimer: Timer?

    /// Timer for registration timeout
    private var registrationTimeoutTimer: Timer?

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

    /// Register for monitor state changes. Returns a token that can be removed later.
    @discardableResult
    func addStateObserver(_ observer: @escaping () -> Void) -> UUID {
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
    func registerHelper(completion: ((Bool) -> Void)? = nil) {
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
    func startMonitoring(persistUserPreference: Bool = true) {
        log.info("┌─────────────────────────────────────────────────────┐")
        log.info("│ startMonitoring() called                            │")
        log.info("└─────────────────────────────────────────────────────┘")

        // Check if helper is registered
        guard isHelperRegistered else {
            log.info("Helper not registered - starting registration flow")
            // Prevent recursive registration
            guard !isRegisteringHelper else {
                log.debug("Already registering helper, skipping")
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
                return
            }

            isRegisteringHelper = true
            registerHelper { success in
                self.isRegisteringHelper = false
                if success && self.isHelperRegistered {
                    // Reset attempts on success
                    self.stateLock.lock()
                    self._registrationAttempts = 0
                    self.stateLock.unlock()
                    self.startMonitoring(persistUserPreference: persistUserPreference)
                }
            }
            return
        }

        // Ensure XPC connection; connectXPC() resets the retry counter
        // internally on successful activation.
        if xpcConnection == nil {
            connectXPC()
        }

        // Send command to disable AWDL
        guard let proxy = getHelperProxy() else {
            log.error("Failed to get helper proxy")
            PingWardenPreferences.shared.effectiveMonitoringEnabled = false
            notifyStateChange()
            showError("Cannot connect to helper.\n\nTry restarting the app.")
            return
        }

        log.info("Sending setAWDLEnabled(false) via XPC...")

        proxy.setAWDLEnabled(false, reply: { success in
            DispatchQueue.main.async {
                if success {
                    self.isMonitoring = true
                    if persistUserPreference {
                        PingWardenPreferences.shared.isMonitoringEnabled = true
                    }
                    PingWardenPreferences.shared.effectiveMonitoringEnabled = true
                    PingWardenPreferences.shared.lastKnownState = "down"
                    self.notifyStateChange()
                    log.info("✅ AWDL monitoring started")
                } else {
                    log.error("❌ Failed to disable AWDL")
                    PingWardenPreferences.shared.effectiveMonitoringEnabled = false
                    self.notifyStateChange()
                    self.showError("Failed to disable AWDL.\n\nThe helper may not be running correctly.")
                }
            }
        })
    }

    /// Stop monitoring - sends command to helper via XPC
    func stopMonitoring(persistUserPreference: Bool = true) {
        log.info("┌─────────────────────────────────────────────────────┐")
        log.info("│ stopMonitoring() called                             │")
        log.info("└─────────────────────────────────────────────────────┘")

        guard let proxy = getHelperProxy() else {
            log.warning("No helper proxy - updating state anyway")
            stateLock.lock()
            _isMonitoring = false
            stateLock.unlock()
            if persistUserPreference {
                PingWardenPreferences.shared.isMonitoringEnabled = false
            }
            PingWardenPreferences.shared.effectiveMonitoringEnabled = false
            PingWardenPreferences.shared.lastKnownState = "up"
            notifyStateChange()
            return
        }

        log.info("Sending setAWDLEnabled(true) via XPC...")

        proxy.setAWDLEnabled(true, reply: { success in
            DispatchQueue.main.async {
                if success {
                    self.stateLock.lock()
                    self._isMonitoring = false
                    self.stateLock.unlock()
                    if persistUserPreference {
                        PingWardenPreferences.shared.isMonitoringEnabled = false
                    }
                    PingWardenPreferences.shared.effectiveMonitoringEnabled = false
                    PingWardenPreferences.shared.lastKnownState = "up"
                    self.notifyStateChange()
                    log.info("✅ AWDL monitoring stopped - AirDrop/Handoff available")
                } else {
                    log.error("❌ Failed to enable AWDL")
                }
            }
        })
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
        var helperStatus = "Unknown"
        var helperVersion = "Unknown"
        var statusTimedOut = false
        var versionTimedOut = false
        let statusSemaphore = DispatchSemaphore(value: 0)
        let versionSemaphore = DispatchSemaphore(value: 0)

        proxy.getAWDLStatus(reply: { status in
            helperStatus = status
            statusSemaphore.signal()
        })
        if statusSemaphore.wait(timeout: .now() + 2.0) == .timedOut {
            log.warning("Health check: getAWDLStatus timed out")
            statusTimedOut = true
        }

        proxy.getVersion(reply: { version in
            helperVersion = version
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
            return (false, "Monitoring active but AWDL is UP - helper may not be functioning")
        }

        let message = "Helper healthy: v\(helperVersion), Status: \(helperStatus)"
        log.info("Health check: \(message)")
        return (true, message)
    }
    
    /// Get the AWDL intervention count from the helper
    /// Returns the number of times AWDL was blocked from coming up
    func getInterventionCount(completion: @escaping (Int) -> Void) {
        guard let proxy = getHelperProxy() else {
            log.warning("Cannot get intervention count: No helper proxy")
            completion(0)
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
    func resetInterventionCount(completion: @escaping (Bool) -> Void = { _ in }) {
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

    /// Test the helper response time (for Testing Mode feature)
    /// Note: This test only works when monitoring is active, as it relies on
    /// the helper bringing AWDL back down after we bring it up.
    func testHelperResponseTime(iterations: Int = 5, completion: @escaping ([(passed: Bool, responseTime: TimeInterval)]) -> Void) {
        log.info("Testing helper response time (\(iterations) iterations)...")

        // Warn if monitoring is not active - test results won't be meaningful
        guard isMonitoringActive else {
            log.warning("testHelperResponseTime called but monitoring is not active - test will fail")
            DispatchQueue.main.async {
                // Return all failures since monitoring isn't active
                let results = (0..<iterations).map { _ in (passed: false, responseTime: 0.0) }
                completion(results)
            }
            return
        }

        var results: [(passed: Bool, responseTime: TimeInterval)] = []

        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<iterations {
                let startTime = Date()

                // Bring AWDL up
                self.runIfconfig(up: true)

                // Small delay for system to process
                Thread.sleep(forTimeInterval: 0.001)

                // Check if AWDL is still down (helper should have caught it)
                let status = self.getAWDLInterfaceStatus()
                let endTime = Date()

                let responseTime = endTime.timeIntervalSince(startTime)
                let passed = !status.contains("UP") || status.contains("<DOWN")

                results.append((passed: passed, responseTime: responseTime))
                log.debug("Test \(i + 1): passed=\(passed), time=\(String(format: "%.3f", responseTime * 1000))ms")

                // Small delay between tests
                if i < iterations - 1 {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }

            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    // MARK: - Legacy API Support (for compatibility)

    /// Legacy method - redirects to registerHelper
    func installAndStartMonitoring() {
        log.info("installAndStartMonitoring() called - redirecting to registerHelper()")
        registerHelper { success in
            if success {
                self.startMonitoring()

                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Setup Complete!"
                    alert.informativeText = "Ping Warden is now running.\n\nYour network is protected from wireless interference that causes lag spikes.\n\nYou can toggle protection from the menu bar."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

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

        // Invalidate existing connection if any
        stateLock.lock()
        _xpcConnection?.invalidate()
        stateLock.unlock()

        // Use .privileged for daemon registered via SMAppService
        // This is required because the daemon runs as root
        let connection = NSXPCConnection(machServiceName: xpcServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PingWardenHelperProtocol.self)

        connection.interruptionHandler = { [weak self] in
            log.warning("XPC connection interrupted")
            DispatchQueue.main.async {
                self?.handleXPCInterruption()
            }
        }

        connection.invalidationHandler = { [weak self] in
            log.warning("XPC connection invalidated")
            DispatchQueue.main.async {
                self?.handleXPCInvalidation()
            }
        }

        connection.activate()

        stateLock.lock()
        _xpcConnection = connection
        stateLock.unlock()

        // Reset retry count on successful activation
        xpcRetryCount = 0

        log.info("XPC connection activated")

        // Validate connection asynchronously to avoid blocking UI paths.
        validateXPCConnection { [weak self] isValid in
            guard let self else { return }
            if isValid {
                self.reassertMonitoringStateIfNeeded()
            }
        }
    }

    /// Validate XPC connection is actually working
    private func validateXPCConnection(completion: ((Bool) -> Void)? = nil) {
        guard let proxy = getHelperProxy() else {
            log.warning("XPC validation: No proxy available")
            completion?(false)
            return
        }

        let completionLock = NSLock()
        var didComplete = false

        let finish: (Bool) -> Void = { isValid in
            completionLock.lock()
            defer { completionLock.unlock() }
            guard !didComplete else { return }
            didComplete = true
            completion?(isValid)
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
            log.warning("XPC validation: Connection timeout - helper may not be running")
            finish(false)
        }

        proxy.getVersion(reply: { version in
            if version.isEmpty {
                log.warning("XPC validation: Invalid response from helper")
                finish(false)
            } else {
                log.debug("XPC validation: Connection verified successfully")
                finish(true)
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
        proxy.setAWDLEnabled(false, reply: { success in
            DispatchQueue.main.async {
                if success {
                    PingWardenPreferences.shared.effectiveMonitoringEnabled = true
                    PingWardenPreferences.shared.lastKnownState = "down"
                    self.notifyStateChange()
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
    private func handleXPCInvalidation() {
        // Prevent re-entrant handling
        stateLock.lock()
        if _isHandlingInvalidation {
            stateLock.unlock()
            log.debug("Already handling XPC invalidation, skipping")
            return
        }
        _isHandlingInvalidation = true
        _xpcConnection = nil
        let wasMonitoring = _isMonitoring
        stateLock.unlock()

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

        return xpc.remoteObjectProxyWithErrorHandler { error in
            log.error("XPC proxy error: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.handleXPCInvalidation()
            }
        } as? PingWardenHelperProtocol
    }

    // MARK: - Registration Polling

    /// Poll for registration status change with timeout
    private func startPollingForRegistration(completion: ((Bool) -> Void)?) {
        log.debug("Starting registration polling (timeout: \(self.registrationTimeoutSeconds)s)...")

        // Cancel any existing timers
        registrationTimer?.invalidate()
        registrationTimeoutTimer?.invalidate()

        // Set up timeout timer
        registrationTimeoutTimer = Timer.scheduledTimer(withTimeInterval: registrationTimeoutSeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            log.warning("Registration polling timed out after \(self.registrationTimeoutSeconds)s")
            self.registrationTimer?.invalidate()
            self.registrationTimer = nil
            self.registrationTimeoutTimer = nil

            DispatchQueue.main.async {
                self.showError("Registration timed out.\n\nPlease approve the helper in System Settings → Login Items and try again.")
            }
            completion?(false)
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
                timer.invalidate()
                self.registrationTimer = nil
                self.registrationTimeoutTimer?.invalidate()
                self.registrationTimeoutTimer = nil
                log.info("✅ Helper registration approved")
                self.connectXPC()
                completion?(true)

            case .notRegistered:
                timer.invalidate()
                self.registrationTimer = nil
                self.registrationTimeoutTimer?.invalidate()
                self.registrationTimeoutTimer = nil
                log.info("❌ Helper registration denied")
                completion?(false)

            case .requiresApproval, .notFound:
                // Keep polling
                break

            @unknown default:
                break
            }
        }
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

    /// Run ifconfig to bring AWDL up or down (for testing only).
    /// Returns true if the command succeeded. The unprivileged app typically
    /// cannot modify network interfaces, so this is expected to fail — the
    /// test relies on the *helper* reacting to the route change.
    @discardableResult
    private func runIfconfig(up: Bool) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        task.arguments = ["awdl0", up ? "up" : "down"]
        // Output is not consumed here; route both streams to /dev/null so a
        // verbose subprocess cannot fill an unread pipe buffer and block.
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                log.debug("ifconfig awdl0 \(up ? "up" : "down") exited with status \(task.terminationStatus) (expected for unprivileged process)")
                return false
            }
            return true
        } catch {
            log.error("Error running ifconfig: \(error.localizedDescription)")
            return false
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
