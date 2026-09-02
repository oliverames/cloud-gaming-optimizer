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

enum LicensePolicy {

    /// How a Gumroad verify response maps to an entitlement decision.
    enum Verification: Equatable {
        /// The key is valid and entitled. Carries the server timestamp
        /// of the verification for offline-grace bookkeeping.
        case valid(verifiedAt: Date)
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

    /// Grandfathered installs keep entitlement for 90 days from the
    /// first launch of the licensed build that observed protection
    /// already enabled.
    static let grandfatherInterval: TimeInterval = 90 * 24 * 3600

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

        guard json["success"] as? Bool == true else {
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

        return .valid(verifiedAt: Date())
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
    /// here so the request shape is tested. `incrementUsesCount` is
    /// omitted: the desktop client does not consume seat counts.
    static func verifyRequest(
        licenseKey: String,
        productID: String
    ) -> Data? {
        let fields: [String: String] = [
            "product_id": productID,
            "license_key": licenseKey,
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