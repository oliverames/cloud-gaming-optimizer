import Foundation

enum ProtectedSessionTrigger: String, Codable, CaseIterable, Sendable {
    case manual
    case gameMode
}

enum ProtectedSessionEndReason: String, Codable, CaseIterable, Sendable {
    case endedByUser
    case protectionTurnedOff
    case protectionPaused
    case gameModeEnded
    case applicationTerminated
    case protectionFailed
    case unknown
}

struct ProtectedSessionSummary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let trigger: ProtectedSessionTrigger
    let sampleCount: Int
    let successfulSampleCount: Int
    let medianLatencyMs: Double
    let p95LatencyMs: Double
    let jitterMs: Double
    let packetLossPercent: Double
    let interventionCount: Int
    let endReason: ProtectedSessionEndReason
    let protectionWasInterrupted: Bool

    init(
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        trigger: ProtectedSessionTrigger,
        sampleCount: Int,
        successfulSampleCount: Int,
        medianLatencyMs: Double,
        p95LatencyMs: Double,
        jitterMs: Double,
        packetLossPercent: Double,
        interventionCount: Int,
        endReason: ProtectedSessionEndReason = .endedByUser,
        protectionWasInterrupted: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.trigger = trigger
        self.sampleCount = sampleCount
        self.successfulSampleCount = successfulSampleCount
        self.medianLatencyMs = medianLatencyMs
        self.p95LatencyMs = p95LatencyMs
        self.jitterMs = jitterMs
        self.packetLossPercent = packetLossPercent
        self.interventionCount = interventionCount
        self.endReason = endReason
        self.protectionWasInterrupted = protectionWasInterrupted
    }

    var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }

    var probeFailureCount: Int {
        max(0, sampleCount - successfulSampleCount)
    }

    var privacySafeShareText: String {
        let durationText = Self.formatDuration(duration)
        let interruptionNoun = interventionCount == 1 ? "interruption" : "interruptions"
        var lines = [
            "Ping Warden Latency Session",
            "Duration: \(durationText)",
        ]

        if sampleCount == 0 {
            lines.append("Measurements: No probes completed")
        } else {
            if successfulSampleCount > 0 {
                lines.append("Median latency: \(Self.formatMilliseconds(medianLatencyMs))")
                lines.append("P95 latency: \(Self.formatMilliseconds(p95LatencyMs))")
                lines.append("Jitter: \(Self.formatMilliseconds(jitterMs))")
            } else {
                lines.append("Latency measurements: No successful probes")
            }

            lines.append(
                "Probe Failures: \(probeFailureCount) of \(sampleCount) "
                    + "(\(String(format: "%.1f%%", packetLossPercent)))"
            )
        }

        if interventionCount > 0 {
            lines.append("\(interventionCount) wireless \(interruptionNoun) blocked")
        } else {
            lines.append("No wireless interruptions were recorded")
        }

        if protectionWasInterrupted {
            lines.append("Protection: Interrupted before the session ended")
        }

        return lines.joined(separator: "\n")
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = Int(max(0, duration) / 60)
        guard totalMinutes > 0 else { return "under a minute" }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
        let minuteText = minutes == 1 ? "1 minute" : "\(minutes) minutes"

        if hours == 0 { return minuteText }
        if minutes == 0 { return hourText }
        return "\(hourText), \(minuteText)"
    }

    private static func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.0f ms", value)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case startedAt
        case endedAt
        case trigger
        case sampleCount
        case successfulSampleCount
        case medianLatencyMs
        case p95LatencyMs
        case jitterMs
        case packetLossPercent
        case interventionCount
        case endReason
        case protectionWasInterrupted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        trigger = try container.decode(ProtectedSessionTrigger.self, forKey: .trigger)
        sampleCount = try container.decode(Int.self, forKey: .sampleCount)
        successfulSampleCount = try container.decode(Int.self, forKey: .successfulSampleCount)
        medianLatencyMs = try container.decode(Double.self, forKey: .medianLatencyMs)
        p95LatencyMs = try container.decode(Double.self, forKey: .p95LatencyMs)
        jitterMs = try container.decode(Double.self, forKey: .jitterMs)
        packetLossPercent = try container.decode(Double.self, forKey: .packetLossPercent)
        interventionCount = try container.decode(Int.self, forKey: .interventionCount)

        let rawEndReason = try container.decodeIfPresent(String.self, forKey: .endReason)
        endReason = rawEndReason.flatMap(ProtectedSessionEndReason.init(rawValue:)) ?? .unknown
        protectionWasInterrupted = try container.decodeIfPresent(
            Bool.self,
            forKey: .protectionWasInterrupted
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(sampleCount, forKey: .sampleCount)
        try container.encode(successfulSampleCount, forKey: .successfulSampleCount)
        try container.encode(medianLatencyMs, forKey: .medianLatencyMs)
        try container.encode(p95LatencyMs, forKey: .p95LatencyMs)
        try container.encode(jitterMs, forKey: .jitterMs)
        try container.encode(packetLossPercent, forKey: .packetLossPercent)
        try container.encode(interventionCount, forKey: .interventionCount)
        try container.encode(endReason.rawValue, forKey: .endReason)
        try container.encode(protectionWasInterrupted, forKey: .protectionWasInterrupted)
    }
}

struct ProtectedSessionAccumulator: Sendable {
    let id: UUID
    let startedAt: Date
    let trigger: ProtectedSessionTrigger
    let startingInterventionCount: Int

    private(set) var sampleCount = 0
    private(set) var successfulLatencies: [Double] = []

    init(
        id: UUID = UUID(),
        startedAt: Date,
        trigger: ProtectedSessionTrigger,
        startingInterventionCount: Int
    ) {
        self.id = id
        self.startedAt = startedAt
        self.trigger = trigger
        self.startingInterventionCount = max(0, startingInterventionCount)
    }

    mutating func record(_ sample: PingSample) {
        sampleCount += 1
        if sample.success {
            successfulLatencies.append(max(0, sample.latencyMs))
        }
    }

    func finish(
        endedAt: Date,
        endingInterventionCount: Int,
        endReason: ProtectedSessionEndReason = .endedByUser,
        protectionWasInterrupted: Bool = false
    ) -> ProtectedSessionSummary {
        let sortedLatencies = successfulLatencies.sorted()
        let medianLatency = Self.median(of: sortedLatencies)
        let p95Latency = Self.percentile95(of: sortedLatencies)
        let jitter = Self.meanAbsoluteConsecutiveDifference(of: successfulLatencies)
        let failureCount = max(0, sampleCount - successfulLatencies.count)
        let packetLoss = sampleCount == 0
            ? 0
            : Double(failureCount) / Double(sampleCount) * 100
        let endingCount = max(0, endingInterventionCount)
        let interventionDelta = endingCount >= startingInterventionCount
            ? endingCount - startingInterventionCount
            : endingCount

        return ProtectedSessionSummary(
            id: id,
            startedAt: startedAt,
            endedAt: max(endedAt, startedAt),
            trigger: trigger,
            sampleCount: sampleCount,
            successfulSampleCount: successfulLatencies.count,
            medianLatencyMs: medianLatency,
            p95LatencyMs: p95Latency,
            jitterMs: jitter,
            packetLossPercent: packetLoss,
            interventionCount: interventionDelta,
            endReason: endReason,
            protectionWasInterrupted: protectionWasInterrupted
        )
    }

    private static func median(of sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let middle = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[middle - 1] + sortedValues[middle]) / 2
        }
        return sortedValues[middle]
    }

    private static func percentile95(of sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let rank = Int(ceil(Double(sortedValues.count) * 0.95))
        return sortedValues[max(0, min(sortedValues.count - 1, rank - 1))]
    }

    private static func meanAbsoluteConsecutiveDifference(of values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let differences = zip(values.dropLast(), values.dropFirst()).map { abs($1 - $0) }
        return differences.reduce(0, +) / Double(differences.count)
    }
}

final class ProtectedSessionStore: @unchecked Sendable {
    let fileURL: URL

    private let limit: Int
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        directoryURL: URL? = nil,
        limit: Int = 50,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.limit = max(1, limit)

        let resolvedDirectory = directoryURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Ping Warden", isDirectory: true)
        fileURL = resolvedDirectory.appendingPathComponent("protected-sessions.json")
    }

    func load() throws -> [ProtectedSessionSummary] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    func save(_ summary: ProtectedSessionSummary) throws {
        lock.lock()
        defer { lock.unlock() }

        var summaries = try loadUnlocked()
        summaries.removeAll { $0.id == summary.id }
        summaries.insert(summary, at: 0)
        summaries = Array(summaries.prefix(limit))

        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(summaries)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func loadUnlocked() throws -> [ProtectedSessionSummary] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summaries = try decoder.decode(
            [ProtectedSessionSummary].self,
            from: Data(contentsOf: fileURL)
        )
        return Array(summaries.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }
}
