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
                return "AWDL intervention"
            }
            return "AWDL interventions (+\(delta))"
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
    static let excellent = Color(red: 0.16, green: 0.78, blue: 0.35)
    static let good = Color(red: 0.95, green: 0.72, blue: 0.05)
    static let fair = Color(red: 0.95, green: 0.49, blue: 0.12)
    static let poor = Color(red: 0.89, green: 0.20, blue: 0.18)
    
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
}

private extension View {
    /// Card chrome used by every dashboard card. Uses `.regularMaterial`
    /// instead of an opaque `unemphasizedSelectedContentBackgroundColor`
    /// fill so the cards render as translucent system material on macOS
    /// 13+ and inherit Liquid Glass treatment automatically on macOS 26+.
    /// One source of truth → applies to StatusCard, PingGraphCard,
    /// LatencyTimelineCard, InterventionsCard, ServerSelectionCard, and
    /// CustomServersCard simultaneously.
    func dashboardCardStyle() -> some View {
        self
            .padding(DashboardLayout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: DashboardLayout.cardCornerRadius, style: .continuous)
            )
    }
}

// MARK: - Dashboard Settings Content

struct DashboardSettingsContent: View {
    @StateObject private var viewModel = DashboardViewModel()
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DashboardLayout.sectionSpacing) {
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
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }
}

// MARK: - Status Card

struct StatusCard: View {
    @ObservedObject var viewModel: DashboardViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Network Quality")
                .font(.headline)
            
            HStack(alignment: .top, spacing: 24) {
                // Current Ping - Main display
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.0f", viewModel.stats.currentPing))
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(colorForQuality(viewModel.stats.quality))
                            .contentTransition(.numericText())
                        Text("ms")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    
                    Label(viewModel.stats.qualityDescription, systemImage: qualityIcon(viewModel.stats.quality))
                        .font(.subheadline)
                        .foregroundStyle(colorForQuality(viewModel.stats.quality))
                }
                .frame(minWidth: 120)
                
                Divider()
                    .frame(height: 80)
                
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        MetricRow(label: "Average", value: String(format: "%.0f ms", viewModel.stats.averagePing))
                        MetricRow(label: "Best", value: String(format: "%.0f ms", viewModel.stats.minimumPing))
                        MetricRow(label: "Worst", value: String(format: "%.0f ms", viewModel.stats.maximumPing))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        MetricRow(label: "Jitter", value: String(format: "%.1f ms", viewModel.stats.jitter))
                        MetricRow(label: "Packet Loss", value: String(format: "%.1f%%", viewModel.stats.packetLoss))
                        MetricRow(
                            label: "AWDL",
                            value: viewModel.isAWDLBlocking ? "Blocking" : "Allowed",
                            tint: viewModel.isAWDLBlocking ? .green : .orange,
                            useMonospacedValue: false
                        )
                    }
                }
            }
        }
        .dashboardCardStyle()
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

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)

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
    }
}

// MARK: - Ping Graph Card

struct PingGraphCard: View {
    @ObservedObject var viewModel: DashboardViewModel
    
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

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Text("Ping History")
                    .font(.headline)
                
                Spacer()
                
                Picker(
                    "Timeframe",
                    selection: Binding(
                        get: { viewModel.selectedTimeframe },
                        set: { newTimeframe in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.selectedTimeframe = newTimeframe
                            }
                        }
                    )
                ) {
                    ForEach(timeframeOptions, id: \.minutes) { option in
                        Text(option.label).tag(option.minutes)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 390)
                .accessibilityLabel("Ping history timeframe")
            }

            Text("Zoom: last \(timeframeLabel(for: viewModel.selectedTimeframe))")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            if viewModel.filteredHistory.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text(emptyStateText())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 170)
                .frame(maxWidth: .infinity)
            } else {
                Chart {
                    ForEach(viewModel.filteredHistory) { dataPoint in
                        LineMark(
                            x: .value("Time", dataPoint.timestamp),
                            y: .value("Ping", dataPoint.latencyMs)
                        )
                        .foregroundStyle(colorForLatency(dataPoint.latencyMs))
                        .lineStyle(StrokeStyle(lineWidth: 2))

                        AreaMark(
                            x: .value("Time", dataPoint.timestamp),
                            y: .value("Ping", dataPoint.latencyMs)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [colorForLatency(dataPoint.latencyMs).opacity(0.3), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        PointMark(
                            x: .value("Time", dataPoint.timestamp),
                            y: .value("Ping", dataPoint.latencyMs)
                        )
                        .foregroundStyle(colorForLatency(dataPoint.latencyMs))
                        .symbolSize(14)
                    }

                    ForEach(viewModel.filteredTimelineEvents) { event in
                        RuleMark(x: .value("Event", event.timestamp))
                            .foregroundStyle(event.color.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .chartXScale(domain: xDomain)
                .chartYScale(domain: 0...max(100, viewModel.maxPingInView))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: xAxisTickCount)) { value in
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
                    AxisMarks(position: .leading) { value in
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
            }
            
            // Legend
            HStack(spacing: 14) {
                LegendItem(color: LatencyPalette.excellent, label: "Excellent", range: "<20ms")
                LegendItem(color: LatencyPalette.good, label: "Good", range: "20-50ms")
                LegendItem(color: LatencyPalette.fair, label: "Fair", range: "50-100ms")
                LegendItem(color: LatencyPalette.poor, label: "Poor", range: ">100ms")
            }
            .font(.caption)
        }
        .dashboardCardStyle()
    }
    
    private func emptyStateText() -> String {
        if viewModel.pingHistory.isEmpty {
            return "Collecting ping data..."
        }
        
        return "No successful ping samples in last \(timeframeLabel(for: viewModel.selectedTimeframe))."
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
            Text("\(label) (\(range))")
                .foregroundStyle(.secondary)
        }
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
                Text("Spikes + AWDL interventions")
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.label)
                                    .font(.caption)
                                Text(event.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AWDL Protection")
                .font(.headline)
            
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Interventions Today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(viewModel.interventionCount)")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                            .contentTransition(.numericText())
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("lag spikes")
                            Text("prevented")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 8) {
                    if viewModel.interventionCount > 0 {
                        Label("AWDL tried to activate", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                        
                        Text("Ping Warden blocked it \(viewModel.interventionCount) times to keep your connection stable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label("No AWDL activation attempts detected", systemImage: "checkmark.shield")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                        Text("Protection is active and your connection is stable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .dashboardCardStyle()
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
                    .frame(width: 360, alignment: .leading)
                    .disabled(viewModel.targets.isEmpty)
                    .onTapGesture {
                        viewModel.refreshGeForceNOWTargetsOnDemand()
                    }

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
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Auto-Select Nearest")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isAutoSelectingTarget || viewModel.targets.isEmpty)

                        if let selectedTarget = viewModel.selectedTarget,
                           let baseline = viewModel.baselineLatencyResults[selectedTarget.id] {
                            Text(String(format: "Baseline %.0f ms", baseline))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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
                    .frame(width: 150, alignment: .leading)
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
    @ObservedObject var viewModel: DashboardViewModel
    @State private var isAdding = false
    @State private var newName = ""
    @State private var newHost = ""
    @State private var newPortText = "53"
    @State private var validationMessage: String?

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
                            .help("Remove \(target.displayName)")
                        }
                        .padding(.vertical, 8)
                    }
                }
            }

            if isAdding {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name (e.g. NextDNS)", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Host (hostname or IP)", text: $newHost)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        Text("Port")
                            .foregroundStyle(.secondary)
                        TextField("53", text: $newPortText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
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
                    }

                    HStack {
                        Spacer()
                        Button("Cancel") {
                            cancelAdd()
                        }
                        .buttonStyle(.bordered)
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
        isAdding = true
    }

    private func cancelAdd() {
        isAdding = false
        validationMessage = nil
    }

    private func commitAdd() {
        let port = Int(newPortText) ?? 0
        if let failure = viewModel.addCustomTarget(displayName: newName, host: newHost, port: port) {
            validationMessage = failure.userMessage
            return
        }
        validationMessage = nil
        isAdding = false
    }
}

struct DashboardControlRow<Content: View>: View {
    let title: String
    let description: String?
    let content: Content

    init(_ title: String, description: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Previews

#Preview("Dashboard") {
    DashboardSettingsContent()
        .frame(width: 500, height: 700)
}
