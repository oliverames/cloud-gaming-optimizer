import Foundation
import XCTest
@testable import PingWardenCore

final class ProtectedSessionAccumulatorTests: XCTestCase {
    func testSummaryCalculatesLatencyLossAndInterventionDelta() {
        let start = Date(timeIntervalSince1970: 1_000)
        var accumulator = ProtectedSessionAccumulator(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            startedAt: start,
            trigger: .manual,
            startingInterventionCount: 12
        )

        accumulator.record(PingSample(latencyMs: 20, success: true, timestamp: start))
        accumulator.record(PingSample(latencyMs: 40, success: true, timestamp: start.addingTimeInterval(1)))
        accumulator.record(PingSample(latencyMs: 1_000, success: false, timestamp: start.addingTimeInterval(2)))
        accumulator.record(PingSample(latencyMs: 30, success: true, timestamp: start.addingTimeInterval(3)))

        let summary = accumulator.finish(
            endedAt: start.addingTimeInterval(120),
            endingInterventionCount: 17,
            endReason: .protectionPaused,
            protectionWasInterrupted: true
        )

        XCTAssertEqual(summary.id, accumulator.id)
        XCTAssertEqual(summary.trigger, .manual)
        XCTAssertEqual(summary.duration, 120, accuracy: 0.001)
        XCTAssertEqual(summary.sampleCount, 4)
        XCTAssertEqual(summary.successfulSampleCount, 3)
        XCTAssertEqual(summary.medianLatencyMs, 30, accuracy: 0.001)
        XCTAssertEqual(summary.p95LatencyMs, 40, accuracy: 0.001)
        XCTAssertEqual(summary.jitterMs, 15, accuracy: 0.001)
        XCTAssertEqual(summary.packetLossPercent, 25, accuracy: 0.001)
        XCTAssertEqual(summary.interventionCount, 5)
        XCTAssertEqual(summary.endReason, .protectionPaused)
        XCTAssertTrue(summary.protectionWasInterrupted)
    }

    func testCounterRestartNeverProducesNegativeInterventions() {
        let start = Date()
        let accumulator = ProtectedSessionAccumulator(
            startedAt: start,
            trigger: .gameMode,
            startingInterventionCount: 9
        )

        let summary = accumulator.finish(
            endedAt: start.addingTimeInterval(30),
            endingInterventionCount: 2
        )

        XCTAssertEqual(summary.interventionCount, 2)
    }

    func testShareTextContainsNoNetworkTarget() {
        let summary = ProtectedSessionSummary(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 160),
            trigger: .manual,
            sampleCount: 10,
            successfulSampleCount: 9,
            medianLatencyMs: 28,
            p95LatencyMs: 52,
            jitterMs: 7,
            packetLossPercent: 10,
            interventionCount: 3
        )

        let text = summary.privacySafeShareText
        XCTAssertTrue(text.contains("Ping Warden Latency Session"))
        XCTAssertTrue(text.contains("Probe Failures: 1 of 10 (10.0%)"))
        XCTAssertTrue(text.contains("3 wireless interruptions blocked"))
        XCTAssertFalse(text.contains("Packet loss"))
        XCTAssertFalse(text.contains("hostname"))
        XCTAssertFalse(text.contains("127.0.0.1"))
    }

    func testShareTextFormatsDurationWithoutPlatformSpecificFormatters() {
        let start = Date(timeIntervalSince1970: 100)
        let summary = ProtectedSessionSummary(
            id: UUID(),
            startedAt: start,
            endedAt: start.addingTimeInterval(3_660),
            trigger: .manual,
            sampleCount: 1,
            successfulSampleCount: 1,
            medianLatencyMs: 20,
            p95LatencyMs: 20,
            jitterMs: 0,
            packetLossPercent: 0,
            interventionCount: 0
        )

        XCTAssertTrue(summary.privacySafeShareText.contains("1 hour, 1 minute"))
    }

    func testShareTextDoesNotPresentZeroesAsMeasurementsWhenNoProbesComplete() {
        let start = Date(timeIntervalSince1970: 100)
        let summary = ProtectedSessionSummary(
            id: UUID(),
            startedAt: start,
            endedAt: start.addingTimeInterval(10),
            trigger: .manual,
            sampleCount: 0,
            successfulSampleCount: 0,
            medianLatencyMs: 0,
            p95LatencyMs: 0,
            jitterMs: 0,
            packetLossPercent: 0,
            interventionCount: 0
        )

        let text = summary.privacySafeShareText
        XCTAssertTrue(text.contains("No probes completed"))
        XCTAssertFalse(text.contains("0 ms"))
        XCTAssertFalse(text.contains("0.0%"))
    }

    func testShareTextDoesNotPresentLatencyZeroesWhenEveryProbeFails() {
        let start = Date(timeIntervalSince1970: 100)
        let summary = ProtectedSessionSummary(
            id: UUID(),
            startedAt: start,
            endedAt: start.addingTimeInterval(10),
            trigger: .manual,
            sampleCount: 3,
            successfulSampleCount: 0,
            medianLatencyMs: 0,
            p95LatencyMs: 0,
            jitterMs: 0,
            packetLossPercent: 100,
            interventionCount: 0
        )

        let text = summary.privacySafeShareText
        XCTAssertTrue(text.contains("No successful probes"))
        XCTAssertTrue(text.contains("Probe Failures: 3 of 3 (100.0%)"))
        XCTAssertFalse(text.contains("Median latency: 0 ms"))
        XCTAssertFalse(text.contains("P95 latency: 0 ms"))
    }

    func testLegacyStoredSummaryDecodesWithSafeDefaults() throws {
        let json = """
        {
          "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "startedAt": "1970-01-01T00:01:40Z",
          "endedAt": "1970-01-01T00:02:40Z",
          "trigger": "manual",
          "sampleCount": 2,
          "successfulSampleCount": 2,
          "medianLatencyMs": 20,
          "p95LatencyMs": 30,
          "jitterMs": 10,
          "packetLossPercent": 0,
          "interventionCount": 1
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(
            ProtectedSessionSummary.self,
            from: try XCTUnwrap(json.data(using: .utf8))
        )

        XCTAssertEqual(summary.endReason, .unknown)
        XCTAssertFalse(summary.protectionWasInterrupted)
    }

    func testNewSessionFieldsRoundTripThroughCodable() throws {
        let start = Date(timeIntervalSince1970: 100)
        let summary = ProtectedSessionSummary(
            id: UUID(),
            startedAt: start,
            endedAt: start.addingTimeInterval(60),
            trigger: .gameMode,
            sampleCount: 2,
            successfulSampleCount: 1,
            medianLatencyMs: 22,
            p95LatencyMs: 22,
            jitterMs: 0,
            packetLossPercent: 50,
            interventionCount: 2,
            endReason: .protectionFailed,
            protectionWasInterrupted: true
        )

        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(ProtectedSessionSummary.self, from: data)

        XCTAssertEqual(decoded, summary)
    }
}

final class ProtectedSessionStoreTests: XCTestCase {
    func testStorePersistsNewestSummariesWithinLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-warden-session-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProtectedSessionStore(directoryURL: directory, limit: 2)
        let summaries = (0..<3).map { index in
            ProtectedSessionSummary(
                id: UUID(),
                startedAt: Date(timeIntervalSince1970: TimeInterval(index * 60)),
                endedAt: Date(timeIntervalSince1970: TimeInterval(index * 60 + 30)),
                trigger: .manual,
                sampleCount: 1,
                successfulSampleCount: 1,
                medianLatencyMs: Double(index),
                p95LatencyMs: Double(index),
                jitterMs: 0,
                packetLossPercent: 0,
                interventionCount: index
            )
        }

        try summaries.forEach(store.save)

        let reloaded = ProtectedSessionStore(directoryURL: directory, limit: 2)
        XCTAssertEqual(try reloaded.load().map(\.id), summaries.suffix(2).reversed().map(\.id))

        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }
}

final class DiagnosticsPrivacyTests: XCTestCase {
    func testCustomTargetIsRedacted() {
        XCTAssertEqual(
            DiagnosticsPrivacy.targetDescription(
                selectedTargetID: "private.example:443",
                customTargetIDs: ["private.example:443"]
            ),
            "custom (redacted)"
        )
    }

    func testBuiltInAndMissingTargetsRevealNoHost() {
        XCTAssertEqual(
            DiagnosticsPrivacy.targetDescription(
                selectedTargetID: "8.8.8.8:53",
                customTargetIDs: []
            ),
            "built-in"
        )
        XCTAssertEqual(
            DiagnosticsPrivacy.targetDescription(selectedTargetID: nil, customTargetIDs: []),
            "not selected"
        )
    }
}

final class GameModePollingPolicyTests: XCTestCase {
    func testActiveDetectionUsesShortSafetyInterval() {
        XCTAssertEqual(GameModePollingPolicy.interval(isActive: true), 2)
    }

    func testInactiveDetectionUsesLowWakeupInterval() {
        XCTAssertEqual(GameModePollingPolicy.interval(isActive: false), 10)
    }

    func testIdleTierKeepsInactiveCadenceBelowThreshold() {
        XCTAssertLessThan(
            GameModePollingPolicy.idleStreakThreshold,
            Int.max
        )
        XCTAssertEqual(
            GameModePollingPolicy.interval(isActive: false, idleStreakTicks: 0),
            GameModePollingPolicy.inactiveInterval
        )
        XCTAssertEqual(
            GameModePollingPolicy.interval(
                isActive: false,
                idleStreakTicks: GameModePollingPolicy.idleStreakThreshold - 1
            ),
            GameModePollingPolicy.inactiveInterval
        )
    }

    func testDeepIdleDropsToIdleTierAtThreshold() {
        XCTAssertEqual(
            GameModePollingPolicy.interval(
                isActive: false,
                idleStreakTicks: GameModePollingPolicy.idleStreakThreshold
            ),
            GameModePollingPolicy.idleInterval
        )
        XCTAssertEqual(
            GameModePollingPolicy.interval(isActive: false, idleStreakTicks: .max),
            GameModePollingPolicy.idleInterval
        )
    }

    func testActiveModeIgnoresIdleStreak() {
        XCTAssertEqual(
            GameModePollingPolicy.interval(isActive: true, idleStreakTicks: 1_000),
            GameModePollingPolicy.activeInterval
        )
    }
}
