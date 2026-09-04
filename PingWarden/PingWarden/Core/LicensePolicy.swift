//
//  LicensePolicy.swift
//  PingWarden
//
//  Pure-Foundation decision logic for Gumroad license enforcement.
//  No network, no Keychain, no UserDefaults — every input is a value
//  the caller supplies, so the whole enforcement surface is testable
//  under `swift test` on both macOS and Linux.
//
//  Enforcement model: an unlicensed copy may use the entire app
//  except enabling Ping Protection (the AWDL-down feature). Turning
//  protection off, sessions' read-only UI, diagnostics, and updates
//  stay available to everyone.
//

import Foundation
import CoreFoundation

enum LicensePolicy {

    /// How a Gumroad verify response maps to an entitlement decision.
    enum Verification: Equatable {
        /// The key is valid and entitled. The caller stamps its own
        /// verification time, so this carries no clock and the whole
        /// policy stays a pure function of its inputs.
        case valid
        /// The key is real but no longer entitled (refund, chargeback,
        /// disabled, revoked subscription).
        case revoked
        /// The API is reachable and says the key does not exist for
        /// this product.
        case invalidKey
        /// The network request could not complete. Offline grace rules
        /// decide what happens next.
        case unreachable
    }

    /// The full entitlement decision for the enable-protection path.
    /// `grandfatherDeadline` is the 90-day entitlement window written
    /// on first launch of the licensed build for installs that already
    /// had protection enabled (see LicenseManager.grandfatherDeadline).
    static func canEnableProtection(
        cachedLicenseValid: Bool,
        lastVerifiedAt: Date?,
        now: Date,
        offlineGraceInterval: TimeInterval = offlineGraceInterval,
        grandfatherDeadline: Date?
    ) -> Bool {
        if cachedLicenseValid,
           let lastVerifiedAt,
           now.timeIntervalSince(lastVerifiedAt) <= offlineGraceInterval {
            return true
        }

        if let grandfatherDeadline, now < grandfatherDeadline {
            return true
        }

        return false
    }

    /// A cached license survives offline only within the grace window
    /// after the last successful verification.
    static let offlineGraceInterval: TimeInterval = 14 * 24 * 3600

    /// Cached state is only trusted when the wall clock has not moved
    /// backwards past it. A verification stamped in the future, or a
    /// last-seen mark more than a day ahead of now, means the clock was
    /// rolled back to stretch the grace window, so the cache is ignored
    /// until the next successful online verification.
    static func clockIsPlausible(
        now: Date,
        lastVerifiedAt: Date?,
        lastSeenAt: Date?
    ) -> Bool {
        if let lastVerifiedAt, lastVerifiedAt.timeIntervalSince(now) > 3600 {
            return false
        }
        if let lastSeenAt, lastSeenAt.timeIntervalSince(now) > 24 * 3600 {
            return false
        }
        return true
    }

    /// The canonical string the app and the widget seal with an HMAC so
    /// the cached gate state in the shared App Group defaults cannot be
    /// forged with `defaults write` or copied from another Mac. Both
    /// targets must build the identical payload, so the format lives
    /// here and nowhere else. Dates are whole seconds since 1970; a
    /// missing date is 0.
    static func sealPayload(
        cachedLicenseValid: Bool,
        lastVerifiedAt: Date?,
        grandfatherDeadline: Date?,
        lastSeenAt: Date?,
        deviceIdentifier: String
    ) -> String {
        func stamp(_ date: Date?) -> String {
            guard let date else { return "0" }
            return String(Int(date.timeIntervalSince1970.rounded(.down)))
        }
        return [
            "pwlic1",
            "valid=\(cachedLicenseValid ? "1" : "0")",
            "verified=\(stamp(lastVerifiedAt))",
            "grandfather=\(stamp(grandfatherDeadline))",
            "seen=\(stamp(lastSeenAt))",
            "device=\(deviceIdentifier)",
        ].joined(separator: "|")
    }

    /// Grandfathered installs keep entitlement for 90 days from the
    /// first launch of the licensed build that observed protection
    /// already enabled.
    static let grandfatherInterval: TimeInterval = 90 * 24 * 3600

    /// Preserve the original 4.0.0 transition, including an expired deadline.
    /// The helper and one-shot marker establish prior use; a future deadline
    /// beyond the original maximum window is not a plausible migration.
    static func legacyGrandfatherDeadline(
        timestamp: Double,
        previouslyChecked: Bool,
        helperEnabled: Bool,
        now: Date
    ) -> Date? {
        guard previouslyChecked, helperEnabled, timestamp.isFinite, timestamp > 0,
              timestamp <= now.addingTimeInterval(grandfatherInterval).timeIntervalSince1970 else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    /// Map a Gumroad `POST /v2/licenses/verify` payload to a
    /// Verification value. Accepts the response body as `Data`
    /// (already UTF-8) so the network layer stays swappable.
    ///
    /// Contract, per Gumroad's open-source controller: a valid,
    /// enabled license returns `{"success":true, "uses":N,
    /// "purchase":{...}}` where the purchase carries `refunded` and
    /// `chargebacked` flags plus `subscription_ended_at` /
    /// `subscription_cancelled_at`. A disabled or unknown key returns
    /// HTTP 404 with `{"success":false}`. The client treats any
    /// `success:false` payload as authoritative (invalid/revoked),
    /// never as offline-unreachable.
    static func verifyResponse(_ data: Data) -> Verification? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let success = json["success"] as? NSNumber,
              CFGetTypeID(success) == CFBooleanGetTypeID() else {
            return nil
        }
        guard success.boolValue else {
            // The API answered, so the key is not entitled. 404 bodies
            // and "license disabled" bodies both land here.
            return .revoked
        }

        if let purchase = json["purchase"] as? [String: Any] {
            if purchase["refunded"] as? Bool == true
                || purchase["chargebacked"] as? Bool == true {
                return .revoked
            }
            // A membership purchase whose subscription lapsed or was
            // cancelled is no longer entitled.
            let ended = purchase["subscription_ended_at"] as? String
            let cancelled = purchase["subscription_cancelled_at"] as? String
            if ended != nil || cancelled != nil {
                return .revoked
            }
        }

        return .valid
    }

    /// Normalize user input into a canonical license key shape.
    /// Gumroad keys are uppercase alphanumerics with optional dashes;
    /// callers pass whatever the user typed and get back the form to
    /// store and send. Returns nil when the input cannot be a key.
    static func normalizeKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    /// The product ID lives in the app target (it is a build-time
    /// constant, not decision logic), but the request builder stays
    /// here so the request shape is tested. Gumroad defaults to incrementing
    /// uses, so every verification explicitly opts out of seat counting.
    static func verifyRequest(
        licenseKey: String,
        productID: String
    ) -> Data? {
        let fields: [String: String] = [
            "product_id": productID,
            "license_key": licenseKey,
            "increment_uses_count": "false",
        ]
        return fields
            .map { "\($0.key)=\(percentEncode($0.value))" }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
