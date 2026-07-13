//
//  DashboardView.swift
//  PingWarden
//
//  Network quality dashboard for cloud gaming.
//  Shows real-time ping, graphs, and AWDL intervention stats.
//
//  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
//  Licensed under the MIT License.
//

import Foundation
import SwiftUI
import Charts
import AppKit
import Accessibility

struct PingTarget: Identifiable, Hashable {
    enum Source: Int {
        case local
        case publicDNS
        case geforceNow
        case gaming
        case custom
    }

    let id: String
    let displayName: String
    let host: String
    let port: UInt16
    let source: Source

    init(displayName: String, host: String, port: UInt16, source: Source) {
        self.displayName = displayName
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.source = source
        self.id = "\(self.host.lowercased()):\(port)"
    }
}

struct LatencyTimelineEvent: Identifiable {
    enum Kind {
        case latencySpike(latencyMs: Double)
        case awdlIntervention(delta: Int)
    }

    let id = UUID()
    let timestamp: Date
    let kind: Kind

    var label: String {
        switch kind {
        case .latencySpike(let latency):
            return String(format: "Latency spike: %.0f ms", latency)
        case .awdlIntervention(let delta):
            if delta == 1 {
                return "Protection event"
            }
            return "Protection events (+\(delta))"
        }
    }

    var symbol: String {
        switch kind {
        case .latencySpike:
            return "exclamationmark.triangle.fill"
        case .awdlIntervention:
            return "shield.lefthalf.filled.badge.checkmark"
        }
    }

    var color: Color {
        switch kind {
        case .latencySpike:
            return .orange
        case .awdlIntervention:
            return .green
        }
    }
}

enum DashboardConfig {
    static let intervalOptions: [TimeInterval] = [1, 2, 5, 10]
    static let timeframeOptions: [Int] = [1, 5, 15, 30, 60]
    static let defaultInterval: TimeInterval = 2
    static let gfnRefreshCooldownSeconds: TimeInterval = 15
    static let selectedTargetKey = "DashboardSelectedPingTargetID"
    static let updateIntervalKey = "DashboardUpdateInterval"
    static let historyRetentionSeconds: TimeInterval = 3900
    static let baselineSampleCount = 3
    static let baselineProbeTimeoutSeconds = 1
    static let baselineSampleSpacingNanoseconds: UInt64 = 100_000_000
}

private enum DashboardLayout {
    static let cardCornerRadius: CGFloat = 10
    static let cardPadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 12
}

private enum LatencyPalette {
    // Light variants are darker so they hit WCAG AA (>=4.5:1) against
    // .regularMaterial; dark variants keep the original vivid palette which
    // already met AA against dark material backgrounds. Verified with
    // python contrast calc, 2026-05-27. See PR for the table.
    static let excellent = adaptive(light: (0.00, 0.46, 0.12), dark: (0.30, 0.85, 0.45))
    static let good      = adaptive(light: (0.50, 0.37, 0.00), dark: (1.00, 0.80, 0.20))
    static let fair      = adaptive(light: (0.65, 0.26, 0.00), dark: (1.00, 0.55, 0.20))
    static let poor      = adaptive(light: (0.75, 0.08, 0.08), dark: (1.00, 0.45, 0.45))

    static func forLatency(_ latency: Double) -> Color {
        if latency < 20 { return excellent }
        if latency < 50 { return good }
        if latency < 100 { return fair }
        return poor
    }

    static func forQuality(_ quality: PingMonitor.Quality) -> Color {
        switch quality {
        case .excellent: return excellent
        case .good: return good
        case .fair: return fair
        case .poor: return poor
        }
    }

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1.0)
        })
    }
}

private extension View {
    /// Card chrome used by every dashboard card. On macOS 26+ we use
    /// `glassEffect` so the cards participate in the dashboard's
    /// `GlassEffectContainer` and visually morph between each other.
    /// On macOS 13-25 we fall back to `.regularMaterial`, the closest
    /// pre-Liquid-Glass equivalent. One source of truth → applies to
    /// StatusCard, PingGraphCard, LatencyTimelineCard, InterventionsCard,
    /// ServerSelectionCard, and CustomServersCard simultaneously.
    func dashboardCardStyle() -> some View {
        self
            .padding(DashboardLayout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(DashboardCardBackground())
    }
}

private struct DashboardCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DashboardLayout.cardCornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

// MARK: - Dashboard Settings Content

struct DashboardSettingsContent: View {
    @StateObject private var viewModel = DashboardViewModel()
    @ObservedObject private var sessionCoordinator = ProtectedSessionCoordinator.shared

    var body: some View {
        Group {
            if #available(macOS 26, *) {
                // Wrap all glass cards in one container so they sample each
                // other's refraction and morph cleanly when scrolled or laid out.
                // Per Liquid Glass guidance, scattering glass across multiple
                // containers produces inconsistent visual results.
                GlassEffectContainer {
                    cardStack
                }
            } else {
                cardStack
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private var cardStack: some View {
        VStack(alignment: .leading, spacing: DashboardLayout.sectionSpacing) {
            ProtectedSessionCard(coordinator: sessionCoordinator)

            // Current Status Card
            StatusCard(viewModel: viewModel)

            // Ping Graph
            PingGraphCard(viewModel: viewModel)

            // Latency Timeline
            LatencyTimelineCard(viewModel: viewModel)

            // AWDL Interventions Card
            InterventionsCard(viewModel: viewModel)

            // Server Selection
            ServerSelectionCard(viewModel: viewModel)

            // User-defined servers (issue #29)
            CustomServersCard(viewModel: viewModel)
        }
    }
}

// MARK: - Protected sessions

struct ProtectedSessionCard: View {
    @ObservedObject var coordinator: ProtectedSessionCoordinator
    @ObservedObject private var protectionExperience = ProtectionExperienceCoordinator.shared
    @State private var showingClearHistoryConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Latency Session")
                        .font(.headline)
                    Text(coordinator.isActive ? activeSubtitle : "Measure one game or call from start to finish")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Group {
                    if coordinator.isActive {
                        Button("End Session") {
                            Task { await protectionExperience.endManualSession() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .keyboardShortcut(".", modifiers: [.command, .shift])
                    } else {
                        Button("Start Session") {
                            Task { await protectionExperience.startManualSession() }
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                    }
                }
                .disabled(protectionExperience.isBusy)
            }

            if !coordinator.isActive {
                Label(
                    idleProtectionGuidance,
                    systemImage: "shield.lefthalf.filled"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let error = coordinator.lastError ?? protectionExperience.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Latency session error: \(error)")
            }

            if coordinator.isActive {
                activeSessionBody
            } else if let summary = coordinator.latestSummary {
                SessionRecapView(summary: summary)
            } else {
                Label(
                    "Recaps stay on this Mac and never include hostnames, IP addresses, or game names.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !coordinator.history.isEmpty && !coordinator.isActive {
                let recentSessions = Array(coordinator.history.dropFirst())

                if !recentSessions.isEmpty {
                    DisclosureGroup("Recent Latency Sessions (\(recentSessions.count))") {
                        VStack(spacing: 8) {
                            if recentSessions.count > 5 {
                                Text("Last 5 of \(recentSessions.count) sessions")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            ForEach(recentSessions.prefix(5)) { summary in
                                RecentSessionRow(summary: summary)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.caption)
                }

                HStack {
                    Spacer()
                    Button("Clear Latency Session History", role: .destructive) {
                        showingClearHistoryConfirmation = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
        .dashboardCardStyle()
        .confirmationDialog(
            "Clear Latency Session History?",
            isPresented: $showingClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                coordinator.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every saved latency session recap from this Mac.")
        }
    }

    private var activeSubtitle: String {
        let trigger = coordinator.activeTrigger == .gameMode ? "Game Mode" : "Manual"
        return "\(trigger) session, \(Self.durationText(coordinator.elapsed))"
    }

    private var idleProtectionGuidance: String {
        if protectionExperience.policyState.persistentProtectionEnabled {
            return "Ping Protection is already on and will stay on when the session ends."
        }
        return "Starting a session temporarily turns on Ping Protection, then turns it back off when the session ends."
    }

    private var activeSessionBody: some View {
        HStack(spacing: 12) {
            Group {
                if #available(macOS 14.0, *) {
                    if reduceMotion {
                        Image(systemName: "record.circle.fill")
                    } else {
                        Image(systemName: "record.circle.fill")
                            .symbolEffect(.pulse, options: .repeating)
                    }
                } else {
                    Image(systemName: "record.circle.fill")
                }
            }
            .foregroundStyle(.red)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Measuring latency locally")
                    .font(.subheadline)
                Text("Stopping creates a private recap without network addresses or raw samples.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Latency session active for \(Self.durationText(coordinator.elapsed))")
    }

    fileprivate static func durationText(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: max(0, duration)) ?? "0m"
    }
}

private struct SessionRecapView: View {
    let summary: ProtectedSessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Latest Latency Session", systemImage: "checkmark.shield.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                Spacer()
                if hasLatencyMeasurements {
                    ShareLink(item: summary.privacySafeShareText) {
                        Label("Share Recap", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .help("Share a recap without network targets or raw samples")
                }
            }

            if hasLatencyMeasurements {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { metrics }
                    VStack(alignment: .leading, spacing: 8) { metrics }
                }

                Text("Interventions count AWDL activity that Ping Warden blocked. They do not prove that a specific latency spike was avoided.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Label("Not Enough Measurements", systemImage: "chart.xyaxis.line")
                    .font(.subheadline)
                Text(insufficientMeasurementsMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 12) {
                Text("Ping Warden stays free. Donations help fund future releases.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Donate...") {
                    PingWardenPreferences.shared.supportOpenedDate = Date()
                    NSWorkspace.shared.open(DonationPromptView.donationURL)
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Opens the Ping Warden donation page in your browser")
            }
        }
    }

    private var hasLatencyMeasurements: Bool {
        summary.successfulSampleCount > 0
    }

    private var insufficientMeasurementsMessage: String {
        if summary.sampleCount == 0 {
            return "The recording stopped before the first latency probe finished."
        }
        return "The target did not return a successful latency measurement during this recording."
    }

    @ViewBuilder
    private var metrics: some View {
        SessionMetric(label: "Duration", value: ProtectedSessionCard.durationText(summary.duration))
        SessionMetric(label: "Median", value: String(format: "%.0f ms", summary.medianLatencyMs))
        SessionMetric(
            label: "P95",
            value: String(format: "%.0f ms", summary.p95LatencyMs),
            helpText: "95% of successful latency measurements were at or below this value"
        )
        SessionMetric(label: "Jitter", value: String(format: "%.0f ms", summary.jitterMs))
        SessionMetric(label: "Probe Failures", value: String(format: "%.1f%%", summary.packetLossPercent))
        SessionMetric(label: "Interventions", value: "\(summary.interventionCount)")
    }
}

private struct SessionMetric: View {
    let label: String
    let value: String
    var helpText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(helpText ?? "")
        .help(helpText ?? "\(label): \(value)")
    }
}

private struct RecentSessionRow: View {
    let summary: ProtectedSessionSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.startedAt, format: .dateTime.month().day().hour().minute())
                Text("\(ProtectedSessionCard.durationText(summary.duration)), \(summary.sampleCount) samples")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(summary.interventionCount) interventions")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Status Card

struct StatusCard: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject private var protectionExperience = ProtectionExperienceCoordinator.shared
    @ScaledMetric(relativeTo: .largeTitle) private var heroPingSize: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Network Quality")
                .font(.headline)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    currentPingBlock
                        .frame(minWidth: 120, alignment: .leading)

                    Divider()
                        .frame(height: 80)

                    metricGrid
                }

                VStack(alignment: .leading, spacing: 16) {
                    currentPingBlock
                    Divider()
                    metricGrid
                }
            }
        }
        .dashboardCardStyle()
    }

    private var currentPingBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch viewModel.latestProbeSucceeded {
            case nil:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Measuring...")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Measuring current latency")

            case false?:
                Label("Target Unreachable", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(LatencyPalette.poor)
                    .accessibilityLabel("Latency target unreachable")

            case true?:
                // ViewThatFits falls back to stacking the unit below the number
                // when the @ScaledMetric hero font grows past the card width
                // (AX5 + narrow Settings windows).
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        pingValueText
                        pingUnitText
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        pingValueText
                        pingUnitText
                    }
                }

                Label(viewModel.stats.qualityDescription, systemImage: qualityIcon(viewModel.stats.quality))
                    .font(.subheadline)
                    .foregroundStyle(colorForQuality(viewModel.stats.quality))
            }

            if let selectedTarget = viewModel.selectedTarget {
                Text(selectedTarget.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(currentPingAccessibilityLabel)
    }

    private var pingValueText: some View {
        Text(String(format: "%.0f", viewModel.stats.currentPing))
            .font(.system(size: heroPingSize, weight: .bold, design: .rounded))
            .foregroundStyle(colorForQuality(viewModel.stats.quality))
            .contentTransition(.numericText())
    }

    private var pingUnitText: some View {
        Text("ms")
            .font(.title2)
            .foregroundStyle(.secondary)
    }

    private var metricGrid: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                MetricRow(label: "Average", value: latencyMetric(viewModel.stats.averagePing))
                MetricRow(label: "Best", value: latencyMetric(viewModel.stats.minimumPing))
                MetricRow(label: "Worst", value: latencyMetric(viewModel.stats.maximumPing))
            }

            VStack(alignment: .leading, spacing: 10) {
                MetricRow(label: "Jitter", value: latencyMetric(viewModel.stats.jitter, decimals: 1))
                MetricRow(label: "Probe Failures", value: probeFailureMetric)
                MetricRow(
                    label: "Protection",
                    value: isProtectionActive ? "Active" : "Off",
                    tint: isProtectionActive ? .green : .orange,
                    useMonospacedValue: false
                )
            }
        }
    }

    private var isProtectionActive: Bool {
        protectionExperience.policyState.effectiveProtectionEnabled
    }

    private var currentPingAccessibilityLabel: String {
        let target = viewModel.selectedTarget?.displayName ?? "selected target"
        switch viewModel.latestProbeSucceeded {
        case nil:
            return "Measuring current latency to \(target)"
        case false?:
            return "Latency target unreachable: \(target)"
        case true?:
            return "Current ping \(Int(viewModel.stats.currentPing.rounded())) milliseconds to \(target), network quality \(viewModel.stats.qualityDescription)"
        }
    }

    private func latencyMetric(_ value: Double, decimals: Int = 0) -> String {
        guard viewModel.hasSuccessfulProbe else { return "--" }
        return String(format: "%.*f ms", decimals, value)
    }

    private var probeFailureMetric: String {
        guard viewModel.latestProbeSucceeded != nil else { return "--" }
        return String(format: "%.1f%%", viewModel.stats.packetLoss)
    }
    
    private func colorForQuality(_ quality: PingMonitor.Quality) -> Color {
        LatencyPalette.forQuality(quality)
    }
    
    private func qualityIcon(_ quality: PingMonitor.Quality) -> String {
        switch quality {
        case .excellent: return "checkmark.circle.fill"
        case .good: return "checkmark.circle"
        case .fair: return "exclamationmark.triangle"
        case .poor: return "xmark.circle.fill"
        }
    }
}

struct MetricRow: View {
    let label: String
    let value: String
    var tint: Color = .primary
    var useMonospacedValue: Bool = true

    /// Label-column width tracks the .caption font's Dynamic Type. At AX5
    /// the labels ("Probe Failures", "Average") need roughly 2x the room they
    /// do at default size; the previous fixed 74pt truncated long ones.
    @ScaledMetric(relativeTo: .caption) private var labelColumnWidth: CGFloat = 74

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: labelColumnWidth, alignment: .leading)

            if useMonospacedValue {
                Text(value)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(tint)
            } else {
                Text(value)
                    .font(.callout)
                    .foregroundStyle(tint)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Ping Graph Card

struct PingGraphCard: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var emptyChartIconSize: CGFloat = 36

    private let timeframeOptions: [(minutes: Int, label: String)] = [
        (1, "1 min"),
        (5, "5 min"),
        (15, "15 min"),
        (30, "30 min"),
        (60, "1 hour")
    ]

    var body: some View {
        let windowEnd = Date()
        let windowStart = windowEnd.addingTimeInterval(-TimeInterval(viewModel.selectedTimeframe * 60))
        let xDomain = windowStart...windowEnd
        let yDomain = 0...chartYUpperBound

        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Ping History")
                        .font(.headline)

                    Spacer(minLength: 12)

                    timeframePicker
                        .frame(maxWidth: 390)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Ping History")
                        .font(.headline)

                    timeframePicker
                        .frame(maxWidth: 390)
                }
            }

            Text("Showing the last \(timeframeLabel(for: viewModel.selectedTimeframe))")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            if viewModel.filteredProbeHistory.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: emptyChartIconSize))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(emptyStateText())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 170)
                .frame(maxWidth: .infinity)
            } else {
                Chart {
                    ForEach(latencyThresholds, id: \.value) { threshold in
                        RuleMark(y: .value(threshold.label, threshold.value))
                            .foregroundStyle(threshold.color.opacity(0.28))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }

                    ForEach(successfulSegments.indices, id: \.self) { segmentIndex in
                        ForEach(successfulSegments[segmentIndex]) { dataPoint in
                            LineMark(
                                x: .value("Time", dataPoint.timestamp),
                                y: .value("Ping", dataPoint.latencyMs),
                                series: .value("Successful Run", segmentIndex)
                            )
                            .foregroundStyle(seriesColor)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                            AreaMark(
                                x: .value("Time", dataPoint.timestamp),
                                y: .value("Ping", dataPoint.latencyMs),
                                series: .value("Successful Run", segmentIndex)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [seriesColor.opacity(0.22), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        }
                    }

                    ForEach(spikePoints) { dataPoint in
                        PointMark(
                            x: .value("Time", dataPoint.timestamp),
                            y: .value("Ping", dataPoint.latencyMs)
                        )
                        .foregroundStyle(colorForLatency(dataPoint.latencyMs))
                        .symbolSize(18)
                    }

                    if let latestPoint {
                        PointMark(
                            x: .value("Latest Time", latestPoint.timestamp),
                            y: .value("Latest Ping", latestPoint.latencyMs)
                        )
                        .foregroundStyle(seriesColor)
                        .symbolSize(42)
                        .annotation(position: .top, alignment: .trailing) {
                            Text("\(Int(latestPoint.latencyMs.rounded())) ms")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.quaternary.opacity(0.35), in: Capsule())
                        }
                    }

                    ForEach(viewModel.filteredTimelineEvents) { event in
                        RuleMark(x: .value("Event", event.timestamp))
                            .foregroundStyle(event.color.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }

                    ForEach(failedProbePoints) { dataPoint in
                        RuleMark(x: .value("Failed Probe", dataPoint.timestamp))
                            .foregroundStyle(LatencyPalette.poor.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

                        PointMark(
                            x: .value("Failed Probe Time", dataPoint.timestamp),
                            y: .value("Failed Probe", 0)
                        )
                        .foregroundStyle(LatencyPalette.poor)
                        .symbolSize(34)
                    }
                }
                .chartXScale(domain: xDomain)
                .chartYScale(domain: yDomain)
                .chartPlotStyle { plotArea in
                    plotArea
                        .padding(.trailing, 34)
                }
                .chartXAxis {
                    AxisMarks(values: xAxisTickDates(windowStart: windowStart, windowEnd: windowEnd)) { value in
                        AxisGridLine()
                        AxisTick()
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                if viewModel.selectedTimeframe == 1 {
                                    Text(date, format: .dateTime.minute().second())
                                        .font(.caption2.monospacedDigit())
                                } else {
                                    Text(date, format: .dateTime.hour().minute())
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let intValue = value.as(Int.self) {
                                Text("\(intValue) ms")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 190)
                .accessibilityLabel("Ping latency chart")
                .accessibilityValue(chartAccessibilityValue)
                .accessibilityChartDescriptor(
                    PingChartDescriptor(
                        probeResults: viewModel.filteredProbeHistory,
                        timeframeMinutes: viewModel.selectedTimeframe
                    )
                )
            }
            
            // Legend
            legend
        }
        .dashboardCardStyle()
    }
    
    private func emptyStateText() -> String {
        if viewModel.pingHistory.isEmpty {
            return "Collecting ping data..."
        }

        return "No successful ping samples in last \(timeframeLabel(for: viewModel.selectedTimeframe))."
    }

    /// Summary read by VoiceOver instead of the chart's default mark-by-mark
    /// announcements. Designed to give a sighted-equivalent snapshot in one
    /// breath: how many samples, current value, average, peak, and whether
    /// any protection events fired during the window.
    private var chartAccessibilityValue: String {
        let probes = viewModel.filteredProbeHistory
        let history = probes.filter(\.success)
        let timeframe = timeframeLabel(for: viewModel.selectedTimeframe)
        guard !probes.isEmpty else {
            return "No samples in the last \(timeframe)."
        }
        let failures = probes.count - history.count
        guard !history.isEmpty else {
            return "\(probes.count) failed probe\(probes.count == 1 ? "" : "s") in the last \(timeframe). The target did not return a successful latency measurement."
        }
        let pings = history.map(\.latencyMs)
        let current = Int((pings.last ?? 0).rounded())
        let avg = Int((pings.reduce(0, +) / Double(pings.count)).rounded())
        let peak = Int((pings.max() ?? 0).rounded())
        let events = viewModel.filteredTimelineEvents.count
        let eventPhrase = events == 0
            ? ""
            : ", with \(events) protection event\(events == 1 ? "" : "s") in this window"
        let failurePhrase = failures == 0
            ? ""
            : ", and \(failures) failed probe\(failures == 1 ? "" : "s")"
        return "\(history.count) successful samples over the last \(timeframe)\(failurePhrase). Current ping \(current) milliseconds, average \(avg), peak \(peak)\(eventPhrase)."
    }
    
    private func timeframeLabel(for minutes: Int) -> String {
        if minutes == 1 {
            return "1 minute"
        }
        if minutes == 60 {
            return "1 hour"
        }
        return "\(minutes) minutes"
    }

    private var xAxisTickCount: Int {
        if viewModel.selectedTimeframe <= 5 {
            return 4
        }
        return 5
    }

    private func xAxisTickDates(windowStart: Date, windowEnd: Date) -> [Date] {
        let duration = windowEnd.timeIntervalSince(windowStart)
        guard duration > 0 else { return [] }

        return (1...xAxisTickCount).map { index in
            windowStart.addingTimeInterval(duration * Double(index) / Double(xAxisTickCount + 1))
        }
    }

    private var chartYUpperBound: Double {
        let padded = max(125, viewModel.maxPingInView * 1.15)
        return (padded / 25).rounded(.up) * 25
    }

    private var seriesColor: Color {
        if let latestPoint {
            return colorForLatency(latestPoint.latencyMs)
        }
        return LatencyPalette.excellent
    }

    private var latestPoint: PingMonitor.PingResult? {
        guard viewModel.filteredProbeHistory.last?.success == true else { return nil }
        return viewModel.filteredProbeHistory.last
    }

    private var spikePoints: [PingMonitor.PingResult] {
        viewModel.filteredHistory.filter { $0.latencyMs >= 100 }
    }

    private var failedProbePoints: [PingMonitor.PingResult] {
        viewModel.filteredProbeHistory.filter { !$0.success }
    }

    /// Swift Charts connects every mark in a series. Give each uninterrupted
    /// run of successful probes its own series so failed probes create honest
    /// gaps instead of a line that visually bridges the outage.
    private var successfulSegments: [[PingMonitor.PingResult]] {
        var segments: [[PingMonitor.PingResult]] = []
        var current: [PingMonitor.PingResult] = []

        for probe in viewModel.filteredProbeHistory {
            if probe.success {
                current.append(probe)
            } else if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }

        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    private var latencyThresholds: [(value: Double, label: String, color: Color)] {
        [
            (20, "Good", LatencyPalette.good),
            (50, "Fair", LatencyPalette.fair),
            (100, "Poor", LatencyPalette.poor)
        ]
    }

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                legendItems
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 6) {
                legendItems
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var legendItems: some View {
        LegendItem(color: LatencyPalette.excellent, label: "Excellent", range: "<20ms")
        LegendItem(color: LatencyPalette.good, label: "Good", range: "20-50ms")
        LegendItem(color: LatencyPalette.fair, label: "Fair", range: "50-100ms")
        LegendItem(color: LatencyPalette.poor, label: "Poor", range: ">100ms")
        ChartEventLegendItem(color: LatencyPalette.poor, systemImage: "xmark.circle.fill", label: "Failed probe")
        ChartEventLegendItem(color: .orange, systemImage: "exclamationmark.triangle.fill", label: "Latency spike")
        ChartEventLegendItem(color: .green, systemImage: "shield.lefthalf.filled.badge.checkmark", label: "Protection event")
    }

    private var timeframePicker: some View {
        Picker(
            "Timeframe",
            selection: Binding(
                get: { viewModel.selectedTimeframe },
                set: { newTimeframe in
                    if reduceMotion {
                        viewModel.selectedTimeframe = newTimeframe
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.selectedTimeframe = newTimeframe
                        }
                    }
                }
            )
        ) {
            ForEach(timeframeOptions, id: \.minutes) { option in
                Text(option.label).tag(option.minutes)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityLabel("Ping history timeframe")
    }
    
    private func colorForLatency(_ latency: Double) -> Color {
        LatencyPalette.forLatency(latency)
    }
}

struct LegendItem: View {
    let color: Color
    let label: String
    let range: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("\(label) (\(range))")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) range: \(range)")
    }
}

private struct ChartEventLegendItem: View {
    let color: Color
    let systemImage: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(label)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// VoiceOver chart descriptor for `PingGraphCard`. Provides rotor-navigable
/// access to the ping time series so VoiceOver users can browse individual
/// samples instead of relying solely on the summary `accessibilityValue`.
private struct PingChartDescriptor: AXChartDescriptorRepresentable {
    let probeResults: [PingMonitor.PingResult]
    let timeframeMinutes: Int

    func makeChartDescriptor() -> AXChartDescriptor {
        let dataPoints = probeResults.filter(\.success)
        let failedProbes = probeResults.filter { !$0.success }
        let xs = dataPoints.map { $0.timestamp.timeIntervalSince1970 }
        let ys = dataPoints.map { $0.latencyMs }
        let allXs = probeResults.map { $0.timestamp.timeIntervalSince1970 }
        let xMin = allXs.min() ?? 0
        let xMax = allXs.max() ?? (xMin + 1)
        let yMax = max(100, ys.max() ?? 0)

        let xAxis = AXNumericDataAxisDescriptor(
            title: "Time",
            range: xMin...max(xMax, xMin + 1),
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                Date(timeIntervalSince1970: value)
                    .formatted(date: .omitted, time: .standard)
            }
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Latency",
            range: 0...yMax,
            gridlinePositions: [],
            valueDescriptionProvider: { "\(Int($0)) milliseconds" }
        )
        var series: [AXDataSeriesDescriptor] = []
        if !dataPoints.isEmpty {
            series.append(AXDataSeriesDescriptor(
                name: "Ping latency",
                isContinuous: true,
                dataPoints: zip(xs, ys).map { AXDataPoint(x: $0.0, y: $0.1) }
            ))
        }
        if !failedProbes.isEmpty {
            series.append(AXDataSeriesDescriptor(
                name: "Failed probes",
                isContinuous: false,
                dataPoints: failedProbes.map {
                    AXDataPoint(x: $0.timestamp.timeIntervalSince1970, y: 0)
                }
            ))
        }
        return AXChartDescriptor(
            title: "Ping latency over time",
            summary: "Line chart of ping latency and failed probes over the last \(timeframeMinutes) minute\(timeframeMinutes == 1 ? "" : "s")",
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: series
        )
    }
}

struct LatencyTimelineCard: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Latency Timeline")
                    .font(.headline)
                Spacer()
                Text("Spikes + protection events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.filteredTimelineEvents.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text("No notable events in selected timeframe.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.filteredTimelineEvents.suffix(8).reversed()) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: event.symbol)
                                .foregroundStyle(event.color)
                                .frame(width: 14)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.label)
                                    .font(.caption)
                                Text(event.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(event.label) at \(event.timestamp.formatted(date: .omitted, time: .standard))")
                    }
                }
            }
        }
        .dashboardCardStyle()
    }
}

// MARK: - Interventions Card

struct InterventionsCard: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject private var protectionExperience = ProtectionExperienceCoordinator.shared
    @ScaledMetric(relativeTo: .largeTitle) private var heroCountSize: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Ping Protection")
                    .font(.headline)
                Spacer()
                Button(protectionActionTitle) {
                    changeProtectionState()
                }
                .buttonStyle(.borderedProminent)
                .disabled(protectionExperience.isBusy)
            }

            if let error = protectionExperience.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 32) {
                    interventionCountBlock
                        .frame(width: 245, alignment: .leading)

                    interventionStatusBlock
                        .frame(minWidth: 320, maxWidth: 560, alignment: .leading)
                        .layoutPriority(1)

                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 14) {
                    interventionCountBlock
                    interventionStatusBlock
                }
            }
        }
        .dashboardCardStyle()
    }

    private var protectionActionTitle: String {
        let monitor = PingWardenMonitor.shared
        guard monitor.isHelperRegistered else { return "Finish Setup..." }
        return monitor.isMonitoringRequested || monitor.isMonitoringActive
            ? "Turn Off"
            : "Turn On"
    }

    private func changeProtectionState() {
        let monitor = PingWardenMonitor.shared
        guard monitor.isHelperRegistered else {
            monitor.registerHelper { success in
                guard success else { return }
                Task { @MainActor in
                    await protectionExperience.setPersistentProtection(true)
                }
            }
            return
        }

        let shouldEnable = !monitor.isMonitoringRequested && !monitor.isMonitoringActive
        Task {
            await protectionExperience.setPersistentProtection(shouldEnable)
        }
    }

    private var interventionCountBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Interventions Since Launch")
                .font(.caption)
                .foregroundStyle(.secondary)

            // ViewThatFits drops the interruption caption below
            // the hero count when the @ScaledMetric font + caption width
            // would overflow the card (AX5 + narrow windows).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    interventionCountText
                    interventionUnitText
                }
                VStack(alignment: .leading, spacing: 4) {
                    interventionCountText
                    interventionUnitText
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Interventions since launch: \(viewModel.interventionCount) AWDL activation attempts blocked")
    }

    private var interventionCountText: some View {
        Text("\(viewModel.interventionCount)")
            .font(.system(size: heroCountSize, weight: .bold, design: .rounded))
            .foregroundStyle(.green)
            .contentTransition(.numericText())
    }

    private var interventionUnitText: some View {
        Text("AWDL activation attempts blocked")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var interventionStatusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.interventionCount > 0 {
                Label("AWDL activity blocked", systemImage: "shield.lefthalf.filled.badge.checkmark")
                    .font(.subheadline)
                    .foregroundStyle(.orange)

                Text("Ping Warden stopped \(viewModel.interventionCount) AWDL activation attempt\(viewModel.interventionCount == 1 ? "" : "s") while protection was active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(
                    isProtectionActive ? "No activation attempts recorded" : "Protection is off",
                    systemImage: isProtectionActive ? "checkmark.shield" : "pause.circle"
                )
                .font(.subheadline)
                .foregroundStyle(isProtectionActive ? .green : .orange)

                Text(isProtectionActive ? "Ping Protection is active." : "Turn on Ping Protection to block AWDL activation attempts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(InnerCalloutBackground(cornerRadius: 8, fallbackOpacity: 0.28))
    }

    private var isProtectionActive: Bool {
        protectionExperience.policyState.effectiveProtectionEnabled
    }
}

/// Subtle inner-callout chrome for recessed panels *inside* dashboard cards
/// (the interventions status block, the Welcome info banner). These sit on top
/// of a surface that is itself glass on macOS 26 (see `DashboardCardBackground`),
/// so they use a plain quaternary fill on every OS version rather than a second
/// glass layer. Glass-over-glass reads as muddy frost-on-frost and isn't what
/// the material is for — Liquid Glass floats over *content*, not over more glass.
struct InnerCalloutBackground: ViewModifier {
    let cornerRadius: CGFloat
    let fallbackOpacity: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.background(
                .quaternary.opacity(fallbackOpacity),
                in: ConcentricRectangle(corners: .concentric(minimum: .fixed(cornerRadius)), isUniform: true)
            )
        } else {
            content.background(
                .quaternary.opacity(fallbackOpacity),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }
}

// MARK: - Server Selection Card

struct ServerSelectionCard: View {
    @ObservedObject var viewModel: DashboardViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connection Settings")
                .font(.headline)
            
            VStack(spacing: 0) {
                DashboardControlRow("Ping Server", description: "Target used for latency measurements") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Server", selection: $viewModel.selectedTargetID) {
                            ForEach(viewModel.targets) { target in
                                Text(target.displayName).tag(target.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityLabel("Ping server")
                        .frame(maxWidth: 360, alignment: .leading)
                        .disabled(viewModel.targets.isEmpty)

                        if let selectedTarget = viewModel.selectedTarget {
                            Text("\(selectedTarget.host):\(selectedTarget.port)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if viewModel.isRefreshingGFNServers {
                            Text("Refreshing GeForce NOW zones...")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            Button {
                                viewModel.autoSelectNearestEndpoint()
                            } label: {
                                if viewModel.isAutoSelectingTarget {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Finding Fastest Target...")
                                    }
                                } else {
                                    Text("Find Fastest Target")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.isAutoSelectingTarget || viewModel.targets.isEmpty)
                            .accessibilityLabel(
                                viewModel.isAutoSelectingTarget
                                    ? "Finding fastest latency target"
                                    : "Find fastest latency target"
                            )

                            if let selectedTarget = viewModel.selectedTarget,
                               let baseline = viewModel.baselineLatencyResults[selectedTarget.id] {
                                Text(String(format: "Baseline %.0f ms", baseline))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let autoSelectionError = viewModel.autoSelectionError {
                            Label(autoSelectionError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .accessibilityLabel("Target selection error: \(autoSelectionError)")
                        }
                    }
                }
                
                Divider()
                
                DashboardControlRow("Update Interval", description: "How often ping samples are captured") {
                    Picker("Interval", selection: $viewModel.updateInterval) {
                        Text("1 second").tag(TimeInterval(1))
                        Text("2 seconds").tag(TimeInterval(2))
                        Text("5 seconds").tag(TimeInterval(5))
                        Text("10 seconds").tag(TimeInterval(10))
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Update interval")
                    .frame(maxWidth: 150, alignment: .leading)
                }
            }
        }
        .dashboardCardStyle()
    }
}

// MARK: - Custom Servers Card

/// Lets the user add their own ping targets (issue #29). Persists through
/// `DashboardViewModel.addCustomTarget` / `removeCustomTarget` so the same
/// validation path runs whether input comes from this UI or from a future
/// import/config-file flow.
struct CustomServersCard: View {
    private enum Field: Hashable {
        case name
        case host
        case port
    }

    @ObservedObject var viewModel: DashboardViewModel
    @State private var isAdding = false
    @State private var newName = ""
    @State private var newHost = ""
    @State private var newPortText = "53"
    @State private var validationMessage: String?
    @FocusState private var focusedField: Field?
    @AccessibilityFocusState private var validationErrorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Custom Servers")
                    .font(.headline)
                Spacer()
                if !isAdding {
                    Button {
                        beginAdd()
                    } label: {
                        Label("Add Server", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if viewModel.customTargets.isEmpty && !isAdding {
                Text("Add your own DNS or ping targets (e.g. NextDNS, Control D) to monitor latency to servers we don't ship with.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !viewModel.customTargets.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.customTargets.enumerated()), id: \.element.id) { index, target in
                        if index > 0 {
                            Divider()
                        }
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.displayName)
                                    .font(.body)
                                Text("\(target.host):\(target.port)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                viewModel.removeCustomTarget(id: target.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(target.displayName)")
                            .help("Remove \(target.displayName)")
                        }
                        .padding(.vertical, 8)
                    }
                }
            }

            if isAdding {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("For example, NextDNS", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .name)
                            .accessibilityLabel("Server name")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Host")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Hostname or IP address", text: $newHost)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .host)
                            .accessibilityLabel("Server host")
                    }

                    HStack(spacing: 8) {
                        Text("Port")
                            .foregroundStyle(.secondary)
                        TextField("53", text: $newPortText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .focused($focusedField, equals: .port)
                            .accessibilityLabel("Port")
                            .onChangeCompat(of: newPortText) { newValue in
                                let filtered = newValue.filter(\.isNumber)
                                if filtered != newValue {
                                    newPortText = filtered
                                }
                            }
                        Spacer()
                    }

                    if let validationMessage {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Validation error: \(validationMessage)")
                            .accessibilityFocused($validationErrorFocused)
                    }

                    HStack {
                        Spacer()
                        Button("Cancel") {
                            cancelAdd()
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                        Button("Save") {
                            commitAdd()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.top, 4)
            }
        }
        .dashboardCardStyle()
    }

    private func beginAdd() {
        newName = ""
        newHost = ""
        newPortText = "53"
        validationMessage = nil
        validationErrorFocused = false
        isAdding = true
        Task { @MainActor in
            focusedField = .name
        }
    }

    private func cancelAdd() {
        isAdding = false
        validationMessage = nil
        validationErrorFocused = false
        focusedField = nil
    }

    private func commitAdd() {
        let port = Int(newPortText) ?? 0
        let host = newHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if (1...65_535).contains(port),
           viewModel.targets.contains(where: { $0.id == "\(host):\(port)" }) {
            showValidationError("A server with this host and port already exists.")
            return
        }

        if let failure = viewModel.addCustomTarget(displayName: newName, host: newHost, port: port) {
            showValidationError(failure.userMessage)
            return
        }
        validationMessage = nil
        validationErrorFocused = false
        isAdding = false
        focusedField = nil
    }

    private func showValidationError(_ message: String) {
        validationErrorFocused = false
        validationMessage = message
        Task { @MainActor in
            validationErrorFocused = true
        }
    }
}

struct DashboardControlRow<Content: View>: View {
    let title: String
    let description: String?
    let content: Content
    @ScaledMetric(relativeTo: .body) private var labelColumnWidth: CGFloat = 220

    init(_ title: String, description: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 28) {
                labelColumn
                    .frame(width: labelColumnWidth, alignment: .leading)

                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }

            VStack(alignment: .leading, spacing: 8) {
                labelColumn
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 10)
    }

    private var labelColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.body)
            if let description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Previews

#Preview("Dashboard") {
    DashboardSettingsContent()
        .frame(width: 500, height: 700)
}

#Preview("Dashboard — Dynamic Type AX5") {
    DashboardSettingsContent()
        .frame(width: 500, height: 700)
        .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Dashboard — Light mode") {
    DashboardSettingsContent()
        .frame(width: 500, height: 700)
        .preferredColorScheme(.light)
}
