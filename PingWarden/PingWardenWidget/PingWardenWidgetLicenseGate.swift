//
//  PingWardenWidgetLicenseGate.swift
//  PingWardenWidget
//
//  Read-only view of the main app's sealed license state, so the
//  widget honors the same enable-protection gate without its own
//  network calls or keychain access. Keys, the seal payload format, and
//  the seal secret must stay identical to LicenseManager,
//  LicensePolicy.sealPayload, and LicenseStateSeal in the app target.
//

import CryptoKit
import Foundation
import IOKit

enum PingWardenWidgetLicenseGate {
    private static let cachedValidKey = "LicenseCachedValid"
    private static let lastVerifiedKey = "LicenseLastVerifiedAt"
    private static let grandfatherDeadlineKey = "LicenseGrandfatherDeadline"
    private static let lastSeenKey = "LicenseLastSeenAt"
    private static let sealKey = "LicenseStateSeal"
    private static let offlineGraceInterval: TimeInterval = 14 * 24 * 3600
    /// Same build-time secret as LicenseStateSeal in the app target.
    private static let sealSecret = "pingwarden-license-seal-6f2c1a9e4b7d3c85e1f0a2b4c6d8e9f1-3579bdf02468ace1"

    /// Mirrors LicenseManager.canEnableProtection from the app target.
    /// The Core files cannot be shared into the widget without adding
    /// them to this target's synchronized group, so the small decision
    /// is duplicated here against the same shared keys and seal. Keep
    /// the two in sync when either changes.
    static func canEnableProtection(_ preferences: PingWardenPreferences) -> Bool {
        guard preferences.usesAppGroupSuite else { return false }

        let defaults = preferences.defaultsForLicenseGate
        let cachedValid = defaults.bool(forKey: cachedValidKey)
        let verifiedTimestamp = defaults.double(forKey: lastVerifiedKey)
        let grandfatherTimestamp = defaults.double(forKey: grandfatherDeadlineKey)
        let seenTimestamp = defaults.double(forKey: lastSeenKey)
        let now = Date().timeIntervalSince1970

        // Refuse anything the app did not seal for this Mac.
        let payload = sealPayload(
            cachedValid: cachedValid,
            verified: verifiedTimestamp,
            grandfather: grandfatherTimestamp,
            seen: seenTimestamp
        )
        guard sealMatches(defaults.string(forKey: sealKey), payload: payload) else {
            return false
        }

        // A clock rolled backwards past the sealed marks is not trusted.
        if verifiedTimestamp > 0, verifiedTimestamp - now > 3600 { return false }
        if seenTimestamp > 0, seenTimestamp - now > 24 * 3600 { return false }

        if cachedValid, verifiedTimestamp > 0,
           now - verifiedTimestamp <= offlineGraceInterval {
            return true
        }

        if grandfatherTimestamp > 0, now < grandfatherTimestamp {
            return true
        }

        return false
    }

    // MARK: - Seal (duplicate of LicensePolicy.sealPayload + LicenseStateSeal)

    private static func sealPayload(cachedValid: Bool, verified: Double, grandfather: Double, seen: Double) -> String {
        func stamp(_ value: Double) -> String {
            guard value > 0 else { return "0" }
            return String(Int(value.rounded(.down)))
        }
        return [
            "pwlic1",
            "valid=\(cachedValid ? "1" : "0")",
            "verified=\(stamp(verified))",
            "grandfather=\(stamp(grandfather))",
            "seen=\(stamp(seen))",
            "device=\(deviceIdentifier())",
        ].joined(separator: "|")
    }

    private static func sealMatches(_ stored: String?, payload: String) -> Bool {
        guard let stored, stored.count == 64 else { return false }
        let key = SymmetricKey(data: Data(sealSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        let expected = mac.map { String(format: "%02x", $0) }.joined()
        var diff: UInt8 = 0
        for (a, b) in zip(Array(stored.utf8), Array(expected.utf8)) {
            diff |= a ^ b
        }
        return diff == 0 && stored.utf8.count == expected.utf8.count
    }

    private static func deviceIdentifier() -> String {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return "no-platform-expert" }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String, !value.isEmpty else {
            return "no-platform-uuid"
        }
        return value
    }
}
