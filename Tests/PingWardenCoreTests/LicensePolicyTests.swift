//
//  LicensePolicyTests.swift
//  PingWardenCoreTests
//
//  XCTest suite for LicensePolicy: offline grace, grandfathering,
//  Gumroad response mapping, key normalization, and request building.
//

import Foundation
import XCTest
@testable import PingWardenCore

final class LicensePolicyTests: XCTestCase {

    // MARK: - canEnableProtection

    func testVerifiedLicenseWithinGraceCanEnable() {
        let now = Date()
        XCTAssertTrue(LicensePolicy.canEnableProtection(
            cachedLicenseValid: true,
            lastVerifiedAt: now.addingTimeInterval(-13 * 86400),
            now: now,
            grandfatherDeadline: nil
        ))
    }

    func testVerifiedLicensePastGraceCannotEnable() {
        let now = Date()
        XCTAssertFalse(LicensePolicy.canEnableProtection(
            cachedLicenseValid: true,
            lastVerifiedAt: now.addingTimeInterval(-15 * 86400),
            now: now,
            grandfatherDeadline: nil
        ))
    }

    func testGraceBoundaryIsInclusive() {
        let now = Date()
        XCTAssertTrue(LicensePolicy.canEnableProtection(
            cachedLicenseValid: true,
            lastVerifiedAt: now.addingTimeInterval(-LicensePolicy.offlineGraceInterval),
            now: now,
            grandfatherDeadline: nil
        ))
    }

    func testCachedValidWithoutTimestampCannotEnable() {
        XCTAssertFalse(LicensePolicy.canEnableProtection(
            cachedLicenseValid: true,
            lastVerifiedAt: nil,
            now: Date(),
            grandfatherDeadline: nil
        ))
    }

    func testUnlicensedCannotEnable() {
        XCTAssertFalse(LicensePolicy.canEnableProtection(
            cachedLicenseValid: false,
            lastVerifiedAt: nil,
            now: Date(),
            grandfatherDeadline: nil
        ))
    }

    func testGrandfatherWindowGrantsEntitlement() {
        let now = Date()
        XCTAssertTrue(LicensePolicy.canEnableProtection(
            cachedLicenseValid: false,
            lastVerifiedAt: nil,
            now: now,
            grandfatherDeadline: now.addingTimeInterval(89 * 86400)
        ))
    }

    func testExpiredGrandfatherWindowDoesNotGrantEntitlement() {
        let now = Date()
        XCTAssertFalse(LicensePolicy.canEnableProtection(
            cachedLicenseValid: false,
            lastVerifiedAt: nil,
            now: now,
            grandfatherDeadline: now.addingTimeInterval(-1)
        ))
    }

    func testGrandfatherOutranksStaleLicense() {
        let now = Date()
        XCTAssertTrue(LicensePolicy.canEnableProtection(
            cachedLicenseValid: false,
            lastVerifiedAt: now.addingTimeInterval(-60 * 86400),
            now: now,
            grandfatherDeadline: now.addingTimeInterval(30 * 86400)
        ))
    }

    // MARK: - verifyResponse

    private func gumroadBody(_ json: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: json)
    }

    func testSuccessfulVerifyResponseIsValid() {
        let data = gumroadBody([
            "success": true,
            "uses": 3,
            "purchase": [
                "id": "abc",
                "refunded": false,
                "chargebacked": false,
            ],
        ])
        guard case .valid = LicensePolicy.verifyResponse(data)! else {
            return XCTFail("Expected .valid")
        }
    }

    func testDisabledLicenseResponseIsRevoked() {
        let data = gumroadBody([
            "success": false,
            "message": "This license key has been disabled.",
        ])
        XCTAssertEqual(LicensePolicy.verifyResponse(data), .revoked)
    }

    func testNotFoundResponseIsRevoked() {
        let data = gumroadBody([
            "success": false,
            "message": "That license does not exist for the provided product.",
        ])
        XCTAssertEqual(LicensePolicy.verifyResponse(data), .revoked)
    }

    func testRefundedPurchaseIsRevoked() {
        let data = gumroadBody([
            "success": true,
            "uses": 1,
            "purchase": [
                "id": "abc",
                "refunded": true,
                "chargebacked": false,
            ],
        ])
        XCTAssertEqual(LicensePolicy.verifyResponse(data), .revoked)
    }

    func testChargebackedPurchaseIsRevoked() {
        let data = gumroadBody([
            "success": true,
            "uses": 1,
            "purchase": [
                "id": "abc",
                "refunded": false,
                "chargebacked": true,
            ],
        ])
        XCTAssertEqual(LicensePolicy.verifyResponse(data), .revoked)
    }

    func testLapsedSubscriptionIsRevoked() {
        let data = gumroadBody([
            "success": true,
            "uses": 1,
            "purchase": [
                "id": "abc",
                "refunded": false,
                "chargebacked": false,
                "subscription_ended_at": "2026-08-01T00:00:00Z",
            ],
        ])
        XCTAssertEqual(LicensePolicy.verifyResponse(data), .revoked)
    }

    func testCancelledSubscriptionIsRevoked() {
        let data = gumroadBody([
            "success": true,
            "uses": 1,
            "purchase": [
                "id": "abc",
                "refunded": false,
                "chargebacked": false,
                "subscription_cancelled_at": "2026-08-01T00:00:00Z",
            ],
        ])
        XCTAssertEqual(LicensePolicy.verifyResponse(data), .revoked)
    }

    func testUnparsableResponseReturnsNil() {
        XCTAssertNil(LicensePolicy.verifyResponse(Data("not json".utf8)))
    }

    func testMalformedSuccessDoesNotRevokeAnOfflineLicense() {
        for body in ["{}", "{\"success\":1}", "{\"success\":0}", "{\"success\":\"false\"}", "{\"success\":null}"] {
            XCTAssertNil(LicensePolicy.verifyResponse(Data(body.utf8)), body)
        }
    }

    func testImportedCustomerLicenseRemainsSupported() {
        XCTAssertEqual(LicensePolicy.verifyResponse(gumroadBody([
            "success": true, "imported_customer": ["id": "existing-customer"],
        ])), .valid)
    }

    func testLegacyTransitionKeepsOriginalDeadline() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for days in [-1.0, 30.0, 90.0] {
            let original = now.addingTimeInterval(days * 86400)
            XCTAssertEqual(LicensePolicy.legacyGrandfatherDeadline(
                timestamp: original.timeIntervalSince1970, previouslyChecked: true,
                helperEnabled: true, now: now), original)
        }
    }

    func testLegacyTransitionRejectsMissingEvidenceAndExtendedDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let deadline = now.addingTimeInterval(86400).timeIntervalSince1970
        XCTAssertNil(LicensePolicy.legacyGrandfatherDeadline(timestamp: deadline,
            previouslyChecked: false, helperEnabled: true, now: now))
        XCTAssertNil(LicensePolicy.legacyGrandfatherDeadline(timestamp: deadline,
            previouslyChecked: true, helperEnabled: false, now: now))
        for stamp in [0, Double.infinity, Double.nan, now.addingTimeInterval(91 * 86400).timeIntervalSince1970] {
            XCTAssertNil(LicensePolicy.legacyGrandfatherDeadline(timestamp: stamp,
                previouslyChecked: true, helperEnabled: true, now: now))
        }
    }

    // MARK: - normalizeKey

    func testNormalizeKeyTrimsAndUppercases() {
        XCTAssertEqual(LicensePolicy.normalizeKey("  abc-def-123 \n"), "ABC-DEF-123")
    }

    func testNormalizeKeyRejectsEmptyInput() {
        XCTAssertNil(LicensePolicy.normalizeKey("   "))
    }

    func testNormalizeKeyRejectsInvalidCharacters() {
        XCTAssertNil(LicensePolicy.normalizeKey("ABC DEF!"))
    }

    func testNormalizeKeyAcceptsPlainAlphanumeric() {
        XCTAssertEqual(LicensePolicy.normalizeKey("a1b2c3"), "A1B2C3")
    }

    // MARK: - verifyRequest

    func testVerifyRequestBodyContainsProductAndKey() {
        let data = LicensePolicy.verifyRequest(
            licenseKey: "ABC-123",
            productID: "9f8e7d6c"
        )
        let body = String(data: data!, encoding: .utf8)!
        XCTAssertTrue(body.contains("license_key=ABC-123"))
        XCTAssertTrue(body.contains("product_id=9f8e7d6c"))
        XCTAssertTrue(body.split(separator: "&").contains("increment_uses_count=false"))
        XCTAssertTrue(body.contains("&"))
    }

    func testVerifyRequestBodyPercentEncodesKey() {
        let data = LicensePolicy.verifyRequest(
            licenseKey: "ABC-123",
            productID: "id with spaces"
        )
        let body = String(data: data!, encoding: .utf8)!
        XCTAssertTrue(body.contains("product_id=id%20with%20spaces"))
        XCTAssertFalse(body.contains("id with spaces"))
    }

    // MARK: - Clock plausibility

    func testClockIsPlausibleForOrdinaryTimestamps() {
        let now = Date()
        XCTAssertTrue(LicensePolicy.clockIsPlausible(
            now: now,
            lastVerifiedAt: now.addingTimeInterval(-3600),
            lastSeenAt: now.addingTimeInterval(-60)
        ))
        XCTAssertTrue(LicensePolicy.clockIsPlausible(now: now, lastVerifiedAt: nil, lastSeenAt: nil))
    }

    func testClockRolledBackPastVerificationIsNotPlausible() {
        let now = Date()
        XCTAssertFalse(LicensePolicy.clockIsPlausible(
            now: now,
            lastVerifiedAt: now.addingTimeInterval(2 * 3600),
            lastSeenAt: nil
        ))
    }

    func testClockRolledBackPastLastSeenIsNotPlausible() {
        let now = Date()
        XCTAssertFalse(LicensePolicy.clockIsPlausible(
            now: now,
            lastVerifiedAt: nil,
            lastSeenAt: now.addingTimeInterval(2 * 86400)
        ))
    }

    func testSmallClockSkewStaysPlausible() {
        let now = Date()
        XCTAssertTrue(LicensePolicy.clockIsPlausible(
            now: now,
            lastVerifiedAt: now.addingTimeInterval(1800),
            lastSeenAt: now.addingTimeInterval(3600)
        ))
    }

    // MARK: - Seal payload

    func testSealPayloadIsCanonicalAndDeterministic() {
        let verified = Date(timeIntervalSince1970: 1_800_000_000.9)
        let deadline = Date(timeIntervalSince1970: 1_807_776_000)
        let payload = LicensePolicy.sealPayload(
            cachedLicenseValid: true,
            lastVerifiedAt: verified,
            grandfatherDeadline: deadline,
            lastSeenAt: nil,
            deviceIdentifier: "ABC-123"
        )
        XCTAssertEqual(payload, "pwlic1|valid=1|verified=1800000000|grandfather=1807776000|seen=0|device=ABC-123")
    }

    func testSealPayloadChangesWithEveryInput() {
        let base = LicensePolicy.sealPayload(
            cachedLicenseValid: false, lastVerifiedAt: nil, grandfatherDeadline: nil,
            lastSeenAt: nil, deviceIdentifier: "A"
        )
        XCTAssertNotEqual(base, LicensePolicy.sealPayload(
            cachedLicenseValid: true, lastVerifiedAt: nil, grandfatherDeadline: nil,
            lastSeenAt: nil, deviceIdentifier: "A"
        ))
        XCTAssertNotEqual(base, LicensePolicy.sealPayload(
            cachedLicenseValid: false, lastVerifiedAt: nil, grandfatherDeadline: nil,
            lastSeenAt: nil, deviceIdentifier: "B"
        ))
        XCTAssertNotEqual(base, LicensePolicy.sealPayload(
            cachedLicenseValid: false, lastVerifiedAt: nil,
            grandfatherDeadline: Date(timeIntervalSince1970: 1), lastSeenAt: nil, deviceIdentifier: "A"
        ))
    }
}
