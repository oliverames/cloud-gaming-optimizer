//
//  LicenseManager.swift
//  PingWarden
//
//  Gumroad license verification and cached entitlement state for the
//  enable-protection gate. Network calls go to
//  api.gumroad.com/v2/licenses/verify; decisions are made by the pure
//  LicensePolicy in Core so they stay testable.
//
//  Storage: the license key and verification timestamp live in the
//  keychain (service "com.amesvt.pingwarden.license"). The grandfather
//  deadline and cached-valid flag live in the shared App Group
//  defaults so the widget reads them too. Nothing about licensing is
//  sent off-device beyond the verify request itself.
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

    private let keychainService = "com.amesvt.pingwarden.license"
    private let keychainAccount = "gumroad-key"
    private let cachedValidKey = "LicenseCachedValid"
    private let lastVerifiedKey = "LicenseLastVerifiedAt"
    private let grandfatherDeadlineKey = "LicenseGrandfatherDeadline"
    private let grandfatherCheckedKey = "LicenseGrandfatherChecked"
    private let transitionNoticeShownKey = "LicenseTransitionNoticeShown"

    @Published private(set) var lastVerificationResult: LicensePolicy.Verification?
    @Published private(set) var isVerifying = false

    /// Invoked on the main actor after any re-verification settles, so
    /// the protection coordinator can enforce a fresh revocation.
    var onReverificationSettled: (@MainActor () -> Void)?

    private let defaults: UserDefaults
    private var inFlightVerify: Task<Void, Never>?
    private var periodicReverifyTimer: Timer?

    private init() {
        // Prefer the App Group suite so the widget sees the same gate
        // state; fall back the same way PingWardenPreferences does.
        if let suite = UserDefaults(suiteName: "PV3W52NDZ3.com.amesvt.pingwarden") {
            defaults = suite
        } else {
            defaults = .standard
        }
    }

    // MARK: - Entitlement

    /// Whether the AWDL-down feature may be enabled right now.
    /// Runs entirely from cached state; the caller decides whether to
    /// trigger a re-verify.
    var canEnableProtection: Bool {
        let cachedValid = defaults.bool(forKey: cachedValidKey)
        let lastVerified: Date? = {
            let timestamp = defaults.double(forKey: lastVerifiedKey)
            guard timestamp > 0 else { return nil }
            return Date(timeIntervalSince1970: timestamp)
        }()

        return LicensePolicy.canEnableProtection(
            cachedLicenseValid: cachedValid,
            lastVerifiedAt: lastVerified,
            now: Date(),
            grandfatherDeadline: grandfatherDeadline
        )
    }

    /// Days remaining in an active grandfather window, for UI display.
    var grandfatherDaysRemaining: Int? {
        guard let deadline = grandfatherDeadline else { return nil }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        return Int(ceil(remaining / 86400))
    }

    private var grandfatherDeadline: Date? {
        let timestamp = defaults.double(forKey: grandfatherDeadlineKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    /// True when this install is grandfathered (90-day transition
    /// window for existing users) and has not licensed yet.
    var isGrandfathered: Bool {
        guard let deadline = grandfatherDeadline else { return false }
        return Date() < deadline && storedLicenseKey == nil
    }

    /// True when this install had a grandfather window and it has
    /// expired without a license. Wording for gate messages uses this
    /// to say the transition ended rather than implying the user never
    /// qualified.
    var grandfatherWindowExpired: Bool {
        guard let deadline = grandfatherDeadline else { return false }
        return Date() >= deadline && storedLicenseKey == nil
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
    /// continued entitlement. Called once from application launch.
    func establishGrandfatheringIfNeeded() {
        guard !defaults.bool(forKey: grandfatherCheckedKey) else { return }
        defaults.set(true, forKey: grandfatherCheckedKey)

        guard defaults.bool(forKey: "AWDLMonitoringEnabled") else {
            licenseLog.info("No grandfathering: protection was not enabled before the licensed build")
            return
        }

        let deadline = Date().addingTimeInterval(LicensePolicy.grandfatherInterval)
        defaults.set(deadline.timeIntervalSince1970, forKey: grandfatherDeadlineKey)
        licenseLog.info("Grandfathering existing install for 90 days")
    }

    // MARK: - Periodic re-verification

    /// Re-verify roughly every six hours while the app is running, so a
    /// refund or disabled key disables protection within the day
    /// rather than at next launch. Offline failures are harmless: the
    /// grace window keeps licensed users running.
    func startPeriodicReverification() {
        guard periodicReverifyTimer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: 6 * 3600,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.storedLicenseKey != nil else { return }
                await self.reverify()
                self.onReverificationSettled?()
            }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        periodicReverifyTimer = timer
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
        let data = Data(key.utf8)

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
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
            licenseLog.error("Could not store license key (OSStatus \(addStatus))")
        }
    }

    private func deleteLicenseKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Verification

    /// Verify a user-supplied key, store it on success, and publish
    /// the result. Returns true only when the key is entitled.
    @discardableResult
    func verify(key rawKey: String) async -> Bool {
        let entitled = await performVerification(key: rawKey)
        onReverificationSettled?()
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
        guard let key = LicensePolicy.normalizeKey(rawKey) else {
            lastVerificationResult = .invalidKey
            return false
        }

        // Coalesce concurrent verifies of the same key.
        if isVerifying { await inFlightVerify?.value }
        isVerifying = true
        defer { isVerifying = false }

        let result = await Self.performVerifyRequest(key: key)

        switch result {
        case .success(let data):
            guard let verification = LicensePolicy.verifyResponse(data) else {
                licenseLog.error("Gumroad returned an unparsable response")
                lastVerificationResult = .revoked
                applyRevocation()
                return false
            }
            lastVerificationResult = verification
            switch verification {
            case .valid:
                storeLicenseKey(key)
                defaults.set(true, forKey: cachedValidKey)
                defaults.set(Date().timeIntervalSince1970, forKey: lastVerifiedKey)
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
        defaults.set(false, forKey: cachedValidKey)
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
        deleteLicenseKey()
        defaults.removeObject(forKey: cachedValidKey)
        defaults.removeObject(forKey: lastVerifiedKey)
        defaults.removeObject(forKey: grandfatherDeadlineKey)
        defaults.removeObject(forKey: grandfatherCheckedKey)
        defaults.removeObject(forKey: transitionNoticeShownKey)
    }
}