//
//  LicenseManager.swift
//  PingWarden
//
//  Gumroad license verification and cached entitlement state for the
//  enable-protection gate. Network calls go to
//  api.gumroad.com/v2/licenses/verify; decisions are made by the pure
//  LicensePolicy in Core so they stay testable.
//
//  Storage: the license key and the one-shot grandfather marker live in
//  the keychain (service "com.amesvt.pingwarden.license"). The cached
//  gate state (cached-valid flag, verification time, grandfather
//  deadline, last-seen clock mark) lives in the shared App Group
//  defaults so the widget reads it too, and every read verifies an
//  HMAC seal bound to this Mac (LicenseStateSeal) so a hand-written
//  `defaults write` or a plist copied from another Mac is ignored.
//  Nothing about licensing is sent off-device beyond the verify request
//  itself.
//

import Foundation
import Security
import os.log

private let licenseLog = Logger(subsystem: "com.amesvt.pingwarden", category: "License")

@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    /// Gumroad product ID for Ping Warden License, from the Gumroad
    /// product admin (product "FmGG0pxyEyzJqp_BG4itFQ==", permalink
    /// "pingwarden").
    nonisolated static let gumroadProductID = "FmGG0pxyEyzJqp_BG4itFQ=="

    /// Where to buy a license. The Gumroad storefront moved from
    /// olivera40 to amesconsulting on 2026-09-03; the old host 404s.
    nonisolated static let purchaseURL = URL(string: "https://amesconsulting.gumroad.com/l/pingwarden")!

    nonisolated private static let appGroupSuiteName = "PV3W52NDZ3.com.amesvt.pingwarden"
    private let keychainService = "com.amesvt.pingwarden.license"
    private let keychainAccount = "gumroad-key"
    private let grandfatherMarkerAccount = "grandfather-checked"
    private let legacyMigrationMarkerAccount = "legacy-transition-migrated"
    nonisolated private static let cachedValidKey = "LicenseCachedValid"
    nonisolated private static let lastVerifiedKey = "LicenseLastVerifiedAt"
    nonisolated private static let grandfatherDeadlineKey = "LicenseGrandfatherDeadline"
    nonisolated private static let lastSeenKey = "LicenseLastSeenAt"
    nonisolated private static let sealKey = "LicenseStateSeal"
    private let legacyGrandfatherCheckedKey = "LicenseGrandfatherChecked"
    private let transitionNoticeShownKey = "LicenseTransitionNoticeShown"

    @Published private(set) var lastVerificationResult: LicensePolicy.Verification?
    @Published private(set) var isVerifying = false

    /// Invoked on the main actor after any re-verification settles, so
    /// the protection coordinator can enforce a fresh revocation.
    var onReverificationSettled: (@MainActor () -> Void)?

    private let defaults: UserDefaults
    private var periodicReverifyTimer: Timer?
    private var entitlementTimer: Timer?
    private var verificationGeneration: UInt64 = 0
    private var isRemoving = false

    private init() {
        defaults = Self.sharedDefaults()
    }

    nonisolated private static func sharedDefaults() -> UserDefaults {
        // Prefer the App Group suite so the widget sees the same gate
        // state; fall back the same way PingWardenPreferences does.
        UserDefaults(suiteName: appGroupSuiteName) ?? .standard
    }

    // MARK: - Sealed cache

    /// The gate inputs as last written by a successful verification,
    /// a revocation, or a grandfather grant. Absent when nothing was
    /// written yet or the seal does not match this Mac.
    nonisolated private struct SealedState {
        var cachedLicenseValid: Bool
        var lastVerifiedAt: Date?
        var grandfatherDeadline: Date?
        var lastSeenAt: Date?
    }

    nonisolated private static func readSealedState(from defaults: UserDefaults) -> SealedState? {
        func date(_ key: String) -> Date? {
            let timestamp = defaults.double(forKey: key)
            guard timestamp > 0 else { return nil }
            return Date(timeIntervalSince1970: timestamp)
        }
        let state = SealedState(
            cachedLicenseValid: defaults.bool(forKey: cachedValidKey),
            lastVerifiedAt: date(lastVerifiedKey),
            grandfatherDeadline: date(grandfatherDeadlineKey),
            lastSeenAt: date(lastSeenKey)
        )
        let payload = LicensePolicy.sealPayload(
            cachedLicenseValid: state.cachedLicenseValid,
            lastVerifiedAt: state.lastVerifiedAt,
            grandfatherDeadline: state.grandfatherDeadline,
            lastSeenAt: state.lastSeenAt,
            deviceIdentifier: LicenseStateSeal.deviceIdentifier()
        )
        guard LicenseStateSeal.matches(defaults.string(forKey: sealKey), payload: payload) else {
            return nil
        }
        return state
    }

    nonisolated private static func writeSealedState(_ state: SealedState, to defaults: UserDefaults) {
        func stamp(_ date: Date?) -> Double {
            guard let date else { return 0 }
            return date.timeIntervalSince1970.rounded(.down)
        }
        // Whole seconds on disk so the payload rebuilt on read matches
        // the one sealed on write.
        let normalized = SealedState(
            cachedLicenseValid: state.cachedLicenseValid,
            lastVerifiedAt: state.lastVerifiedAt.map { Date(timeIntervalSince1970: stamp($0)) },
            grandfatherDeadline: state.grandfatherDeadline.map { Date(timeIntervalSince1970: stamp($0)) },
            lastSeenAt: state.lastSeenAt.map { Date(timeIntervalSince1970: stamp($0)) }
        )
        defaults.set(normalized.cachedLicenseValid, forKey: cachedValidKey)
        defaults.set(stamp(normalized.lastVerifiedAt), forKey: lastVerifiedKey)
        defaults.set(stamp(normalized.grandfatherDeadline), forKey: grandfatherDeadlineKey)
        defaults.set(stamp(normalized.lastSeenAt), forKey: lastSeenKey)
        let payload = LicensePolicy.sealPayload(
            cachedLicenseValid: normalized.cachedLicenseValid,
            lastVerifiedAt: normalized.lastVerifiedAt,
            grandfatherDeadline: normalized.grandfatherDeadline,
            lastSeenAt: normalized.lastSeenAt,
            deviceIdentifier: LicenseStateSeal.deviceIdentifier()
        )
        defaults.set(LicenseStateSeal.seal(payload), forKey: sealKey)
    }

    private var sealedState: SealedState? {
        Self.readSealedState(from: defaults)
    }

    private func updateSealedState(_ mutate: (inout SealedState) -> Void) {
        var state = sealedState ?? SealedState(cachedLicenseValid: false)
        mutate(&state)
        Self.writeSealedState(state, to: defaults)
    }

    nonisolated private static func entitlement(from defaults: UserDefaults, now: Date) -> Bool {
        guard let state = readSealedState(from: defaults) else { return false }
        guard LicensePolicy.clockIsPlausible(
            now: now,
            lastVerifiedAt: state.lastVerifiedAt,
            lastSeenAt: state.lastSeenAt
        ) else {
            licenseLog.warning("Cached license state ignored: the clock moved backwards")
            return false
        }
        return LicensePolicy.canEnableProtection(
            cachedLicenseValid: state.cachedLicenseValid,
            lastVerifiedAt: state.lastVerifiedAt,
            now: now,
            grandfatherDeadline: state.grandfatherDeadline
        )
    }

    // MARK: - Entitlement

    /// Whether the AWDL-down feature may be enabled right now.
    /// Runs entirely from cached state; the caller decides whether to
    /// trigger a re-verify.
    var canEnableProtection: Bool {
        Self.entitlement(from: defaults, now: Date())
    }

    /// The same decision for code that runs before the main-actor
    /// singleton exists, such as PingWardenMonitor restoring persisted
    /// protection during its own initializer at launch.
    nonisolated static var launchGateAllowsProtection: Bool {
        entitlement(from: sharedDefaults(), now: Date())
    }

    /// Move the last-seen clock mark forward. Called at launch and on
    /// each periodic tick, so a later clock rollback is detectable.
    func recordClockObservation() {
        guard sealedState != nil else { return }
        updateSealedState { state in
            let now = Date()
            if let seen = state.lastSeenAt, seen > now { return }
            state.lastSeenAt = now
        }
    }

    /// Days remaining in an active grandfather window, for UI display.
    var grandfatherDaysRemaining: Int? {
        guard let deadline = grandfatherDeadline else { return nil }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        return Int(ceil(remaining / 86400))
    }

    private var grandfatherDeadline: Date? {
        sealedState?.grandfatherDeadline
    }

    /// True when this install is grandfathered (90-day transition
    /// window for existing users) and has not licensed yet.
    var isGrandfathered: Bool {
        guard let deadline = grandfatherDeadline else { return false }
        return Date() < deadline && !hasValidPaidLicense && canEnableProtection
    }

    var hasValidPaidLicense: Bool {
        guard let state = sealedState else { return false }
        let now = Date()
        return LicensePolicy.clockIsPlausible(now: now, lastVerifiedAt: state.lastVerifiedAt, lastSeenAt: state.lastSeenAt)
            && LicensePolicy.canEnableProtection(cachedLicenseValid: state.cachedLicenseValid,
                lastVerifiedAt: state.lastVerifiedAt, now: now, grandfatherDeadline: nil)
    }

    /// True when this install had a grandfather window and it has
    /// expired without a license. Wording for gate messages uses this
    /// to say the transition ended rather than implying the user never
    /// qualified.
    var grandfatherWindowExpired: Bool {
        guard let deadline = grandfatherDeadline else { return false }
        return Date() >= deadline && !hasValidPaidLicense
    }

    /// Address donors should email to convert a pre-license donation
    /// into a full license, honored manually by the developer.
    static let donationConversionEmail = "oliver@ames.consulting"

    /// Whether the one-time transition notice window has already been
    /// shown on this Mac. The notice explains the paid-model move once,
    /// on the first launch of the licensed build; the License pane
    /// carries the ongoing messaging afterward.
    var transitionNoticeShown: Bool {
        get { defaults.bool(forKey: transitionNoticeShownKey) }
        set { defaults.set(newValue, forKey: transitionNoticeShownKey) }
    }

    /// One-time grandfathering for the licensed build's first launch:
    /// installs that already had protection enabled get 90 days of
    /// continued entitlement. The grant needs two signs of a real prior
    /// install, the persisted protection intent and an already-approved
    /// helper, because a fresh install cannot have approved the helper
    /// before its first launch. The one-shot marker lives in the
    /// keychain so wiping the App Group defaults cannot re-arm it.
    func establishGrandfatheringIfNeeded(helperEnabled: Bool) {
        let alreadyChecked = keychainMarkerExists(account: grandfatherMarkerAccount)
        let legacyChecked = defaults.bool(forKey: legacyGrandfatherCheckedKey)
        let migrationChecked = keychainMarkerExists(account: legacyMigrationMarkerAccount)
        if !migrationChecked { setKeychainMarker(account: legacyMigrationMarkerAccount) }
        // Only an absent legacy seal can migrate. An invalid existing seal
        // means the cached state was modified, not that it needs repair.
        if !migrationChecked, defaults.string(forKey: Self.sealKey) == nil,
           let originalDeadline = LicensePolicy.legacyGrandfatherDeadline(
            timestamp: defaults.double(forKey: Self.grandfatherDeadlineKey),
            previouslyChecked: alreadyChecked || legacyChecked,
            helperEnabled: helperEnabled,
            now: Date()
        ) {
            updateSealedState { state in
                state.grandfatherDeadline = originalDeadline
                state.lastSeenAt = Date()
            }
        }
        guard !alreadyChecked else { return }
        setKeychainMarker(account: grandfatherMarkerAccount)
        defaults.removeObject(forKey: legacyGrandfatherCheckedKey)

        // A prior decision is final, even if protection is temporarily off.
        guard !legacyChecked, grandfatherDeadline == nil else { return }

        guard defaults.bool(forKey: "AWDLMonitoringEnabled") else {
            licenseLog.info("No grandfathering: protection was not enabled before the licensed build")
            return
        }
        guard helperEnabled else {
            licenseLog.info("No grandfathering: the helper was never approved on this Mac")
            return
        }

        let deadline = Date().addingTimeInterval(LicensePolicy.grandfatherInterval)
        updateSealedState { state in
            state.grandfatherDeadline = deadline
            state.lastSeenAt = Date()
        }
        licenseLog.info("Grandfathering existing install for 90 days")
    }

    // MARK: - Periodic re-verification

    /// Re-verify roughly every six hours while the app is running, so a
    /// refund or disabled key disables protection within the day
    /// rather than at next launch. Offline failures are harmless: the
    /// grace window keeps licensed users running.
    func startPeriodicReverification() {
        guard periodicReverifyTimer == nil, !isRemoving else { return }
        let entitlementTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRemoving else { return }
                self.recordClockObservation()
                self.objectWillChange.send()
                self.onReverificationSettled?()
            }
        }
        RunLoop.main.add(entitlementTimer, forMode: .common)
        self.entitlementTimer = entitlementTimer
        let timer = Timer.scheduledTimer(
            withTimeInterval: 6 * 3600,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRemoving else { return }
                self.recordClockObservation()
                if self.storedLicenseKey != nil { await self.reverify() }
                guard !self.isRemoving else { return }
                self.onReverificationSettled?()
            }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        periodicReverifyTimer = timer
    }

    /// Re-verify a stored key once at launch. Offline launches keep the
    /// sealed cache inside its grace window; an online launch refreshes
    /// the verification stamp and catches refunds the moment the app
    /// starts.
    func reverifyAtLaunchIfNeeded() {
        recordClockObservation()
        guard storedLicenseKey != nil else { return }
        Task { @MainActor in
            await reverify()
            guard !isRemoving else { return }
            onReverificationSettled?()
        }
    }

    // MARK: - Keychain

    var storedLicenseKey: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    private func storeLicenseKey(_ key: String) {
        storeKeychainValue(Data(key.utf8), account: keychainAccount)
    }

    private func deleteLicenseKey() {
        deleteKeychainItem(account: keychainAccount)
    }

    private func keychainMarkerExists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func setKeychainMarker(account: String) {
        storeKeychainValue(Data("1".utf8), account: account)
    }

    private func storeKeychainValue(_ data: Data, account: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]

        // Update if present, insert otherwise.
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            licenseLog.error("Could not store keychain item \(account, privacy: .public) (OSStatus \(addStatus))")
        }
    }

    private func deleteKeychainItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Verification

    /// Verify a user-supplied key, store it on success, and publish
    /// the result. Returns true only when the key is entitled.
    @discardableResult
    func verify(key rawKey: String) async -> Bool {
        let entitled = await performVerification(key: rawKey)
        if !isRemoving { onReverificationSettled?() }
        return entitled
    }

    /// Verify the stored key against Gumroad and update cached state.
    /// Offline behavior: a cached-valid license inside its 14-day
    /// grace keeps `canEnableProtection` true without touching the
    /// network (see LicensePolicy.canEnableProtection).
    func reverify() async {
        guard let key = storedLicenseKey else {
            lastVerificationResult = .invalidKey
            return
        }
        _ = await performVerification(key: key)
    }

    private func performVerification(key rawKey: String) async -> Bool {
        guard !isRemoving else { return false }
        guard let key = LicensePolicy.normalizeKey(rawKey) else {
            lastVerificationResult = .invalidKey
            return false
        }

        // A verify already in flight owns the outcome. Re-entering would
        // duplicate the request and race two writes to the cached state,
        // so the second caller reports the current result instead.
        guard !isVerifying else {
            licenseLog.debug("Verification already in flight - skipping duplicate")
            return false
        }
        isVerifying = true
        defer { isVerifying = false }

        let generation = verificationGeneration
        let result = await Self.performVerifyRequest(key: key)
        guard !isRemoving, generation == verificationGeneration else { return false }

        switch result {
        case .success(let data):
            guard let verification = LicensePolicy.verifyResponse(data) else {
                licenseLog.error("Gumroad returned an unparsable response")
                lastVerificationResult = .unreachable
                return false
            }
            lastVerificationResult = verification
            switch verification {
            case .valid:
                storeLicenseKey(key)
                updateSealedState { state in
                    state.cachedLicenseValid = true
                    state.lastVerifiedAt = Date()
                    state.lastSeenAt = Date()
                }
                licenseLog.info("License verified")
                return true
            case .revoked, .invalidKey, .unreachable:
                applyRevocation()
                return false
            }

        case .failure(let error):
            // Network failure is not proof of revocation: leave cached
            // state alone so the offline grace window applies.
            licenseLog.warning("License verify unreachable: \(error.localizedDescription)")
            lastVerificationResult = .unreachable
            return false
        }
    }

    private func applyRevocation() {
        updateSealedState { state in
            state.cachedLicenseValid = false
            state.lastSeenAt = Date()
        }
        // Keep the key and timestamp: a refund that is later reversed
        // (or a transient seller-side disable) should not require the
        // user to retype the key.
    }

    /// The raw URLSession call, static so it never captures state and
    /// stays trivially nonisolated.
    private nonisolated static func performVerifyRequest(key: String) async -> Result<Data, Error> {
        guard let body = LicensePolicy.verifyRequest(
            licenseKey: key,
            productID: gumroadProductID
        ), let url = URL(string: "https://api.gumroad.com/v2/licenses/verify") else {
            return .failure(URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(URLError(.badServerResponse))
            }
            // 404 is Gumroad's authoritative "not entitled" answer, so
            // its body must flow through to verifyResponse, not be
            // treated as a transport failure.
            guard (200..<300).contains(http.statusCode) || http.statusCode == 404 else {
                return .failure(URLError(.badServerResponse))
            }
            return .success(data)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Teardown

    /// Remove every trace of licensing state. Called by uninstall.
    func resetForRemoval() {
        isRemoving = true
        verificationGeneration &+= 1
        periodicReverifyTimer?.invalidate()
        periodicReverifyTimer = nil
        entitlementTimer?.invalidate()
        entitlementTimer = nil
        onReverificationSettled = nil
        deleteLicenseKey()
        deleteKeychainItem(account: grandfatherMarkerAccount)
        deleteKeychainItem(account: legacyMigrationMarkerAccount)
        for key in [
            Self.cachedValidKey,
            Self.lastVerifiedKey,
            Self.grandfatherDeadlineKey,
            Self.lastSeenKey,
            Self.sealKey,
            legacyGrandfatherCheckedKey,
            transitionNoticeShownKey,
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}
