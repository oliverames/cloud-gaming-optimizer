//
//  LicenseGateParityTests.swift
//  PingWardenCoreTests
//
//  The Control Center widget cannot link the Core module, so it carries a
//  hand-copied license gate: the same seal secret, payload fields, offline
//  grace, and clock-rollback thresholds as LicensePolicy and
//  LicenseStateSeal. Nothing in the compiler catches the copies drifting
//  apart, so this suite reads the three source files as text and asserts
//  the values match. A failure here means the widget and the app would
//  disagree about who is licensed.
//

import Foundation
import XCTest

final class LicenseGateParityTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PingWardenCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private var policy = ""
    private var seal = ""
    private var widget = ""

    override func setUpWithError() throws {
        policy = try Self.source("PingWarden/PingWarden/Core/LicensePolicy.swift")
        seal = try Self.source("PingWarden/PingWarden/LicenseStateSeal.swift")
        widget = try Self.source("PingWarden/PingWardenWidget/PingWardenWidgetLicenseGate.swift")
    }

    private func firstMatch(_ pattern: String, in text: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captured = Range(match.range(at: 1), in: text) else {
            XCTFail("pattern not found: \(pattern)", file: file, line: line)
            return ""
        }
        return String(text[captured])
    }

    func testSealSecretIsIdenticalInAppAndWidget() {
        let appSecret = firstMatch(#"private static let secret = "([^"]+)""#, in: seal)
        let widgetSecret = firstMatch(#"private static let sealSecret = "([^"]+)""#, in: widget)
        XCTAssertFalse(appSecret.isEmpty)
        XCTAssertEqual(appSecret, widgetSecret, "LicenseStateSeal.secret and PingWardenWidgetLicenseGate.sealSecret drifted")
    }

    func testSealPayloadFieldsMatchInOrder() {
        let fields = ["\"pwlic1\"", "\"valid=", "\"verified=", "\"grandfather=", "\"seen=", "\"device="]
        func order(in text: String) -> [Int] {
            fields.map { field -> Int in
                guard let range = text.range(of: field) else { return -1 }
                return text.distance(from: text.startIndex, to: range.lowerBound)
            }
        }
        let policyOrder = order(in: policy)
        let widgetOrder = order(in: widget)
        XCTAssertFalse(policyOrder.contains(-1), "a payload field is missing from LicensePolicy: \(policyOrder)")
        XCTAssertFalse(widgetOrder.contains(-1), "a payload field is missing from the widget gate: \(widgetOrder)")
        XCTAssertEqual(policyOrder, policyOrder.sorted(), "LicensePolicy payload fields are out of order")
        XCTAssertEqual(widgetOrder, widgetOrder.sorted(), "widget payload fields are out of order")
    }

    func testOfflineGraceIntervalMatches() {
        let app = firstMatch(#"static let offlineGraceInterval: TimeInterval = ([^\n]+)"#, in: policy)
        let gate = firstMatch(#"private static let offlineGraceInterval: TimeInterval = ([^\n]+)"#, in: widget)
        XCTAssertEqual(app.trimmingCharacters(in: .whitespaces), gate.trimmingCharacters(in: .whitespaces))
    }

    func testClockRollbackThresholdsMatch() {
        // App: lastVerifiedAt more than 3600 s ahead, lastSeenAt more than a day ahead.
        XCTAssertTrue(policy.contains("lastVerifiedAt.timeIntervalSince(now) > 3600"))
        XCTAssertTrue(policy.contains("lastSeenAt.timeIntervalSince(now) > 24 * 3600"))
        // Widget: same two thresholds, expressed on raw timestamps.
        XCTAssertTrue(widget.contains("verifiedTimestamp - now > 3600"))
        XCTAssertTrue(widget.contains("seenTimestamp - now > 24 * 3600"))
    }

    func testWidgetReadsTheSameDefaultsKeys() throws {
        let manager = try Self.source("PingWarden/PingWarden/LicenseManager.swift")
        for key in ["LicenseCachedValid", "LicenseLastVerifiedAt", "LicenseGrandfatherDeadline", "LicenseLastSeenAt", "LicenseStateSeal"] {
            XCTAssertTrue(manager.contains("\"\(key)\""), "LicenseManager lost key \(key)")
            XCTAssertTrue(widget.contains("\"\(key)\""), "widget gate lost key \(key)")
        }
    }
}
