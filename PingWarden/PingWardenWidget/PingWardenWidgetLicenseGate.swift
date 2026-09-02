//
//  PingWardenWidgetLicenseGate.swift
//  PingWardenWidget
//
//  Read-only view of the main app's cached license state, so the
//  widget honors the same enable-protection gate without its own
//  network calls or keychain access. Keys must stay identical to
//  LicenseManager's App Group writes.
//

import Foundation

enum PingWardenWidgetLicenseGate {
    private static let cachedValidKey = "LicenseCachedValid"
    private static let lastVerifiedKey = "LicenseLastVerifiedAt"
    private static let grandfatherDeadlineKey = "LicenseGrandfatherDeadline"
    private static let offlineGraceInterval: TimeInterval = 14 * 24 * 3600

    /// Mirrors LicensePolicy.canEnableProtection from the app target.
    /// The Core file cannot be shared into the widget without adding
    /// it to this target's synchronized group, so the small decision
    /// is duplicated here against the same shared keys. Keep the two
    /// in sync when either changes.
    static func canEnableProtection(_ preferences: PingWardenPreferences) -> Bool {
        guard preferences.usesAppGroupSuite else { return false }

        let defaults = preferences.defaultsForLicenseGate
        let cachedValid = defaults.bool(forKey: cachedValidKey)
        let verifiedTimestamp = defaults.double(forKey: lastVerifiedKey)
        let grandfatherTimestamp = defaults.double(forKey: grandfatherDeadlineKey)
        let now = Date().timeIntervalSince1970

        if cachedValid, verifiedTimestamp > 0,
           now - verifiedTimestamp <= offlineGraceInterval {
            return true
        }

        if grandfatherTimestamp > 0, now < grandfatherTimestamp {
            return true
        }

        return false
    }
}