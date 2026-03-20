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

private enum DashboardConfig {
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
    func dashboardCardStyle() -> some View {
        self
            .padding(DashboardLayout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DashboardLayout.cardCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
            )
    }
}

private enum NetworkGatewayResolver {
    static func defaultGatewayAddress() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/route")
        process.arguments = ["-n", "get", "default"]
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        
        guard process.terminationStatus == 0 else {
            return nil
        }
        
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("gateway:") else { continue }
            
            let gateway = line.replacingOccurrences(of: "gateway:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !gateway.isEmpty, !gateway.hasPrefix("link#") else {
                return nil
            }
            
            return gateway
        }
        
        return nil
    }
}

private enum GeForceNOWDiscovery {
    private static let endpoint = URL(string: "https://status.geforcenow.com/api/v2/components.json")
    private static let zoneCodePattern = #"\bNP[A]?-[A-Z0-9-]+\b"#
    
    private struct ComponentsResponse: Decodable {
        let components: [Component]
    }
    
    private struct Component: Decodable {
        let name: String
    }
    
    static func fetchTargets() async -> [PingTarget] {
        guard let endpoint else { return [] }
        
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 8
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }
            
            let payload = try JSONDecoder().decode(ComponentsResponse.self, from: data)
            let codes = extractZoneCodes(from: payload.components.map(\.name))
            
            return codes.sorted().map { code in
                PingTarget(
                    displayName: "GeForce NOW (\(code))",
                    host: "\(code.lowercased()).cloudmatchbeta.nvidiagrid.net",
                    port: 443,
                    source: .geforceNow
                )
            }
        } catch {
            return []
        }
    }
    
    private static func extractZoneCodes(from componentNames: [String]) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: zoneCodePattern) else {
            return []
        }
        
        var codes = Set<String>()
        
        for name in componentNames {
            let uppercasedName = name.uppercased()
            let nameNSString = uppercasedName as NSString
            let range = NSRange(location: 0, length: nameNSString.length)
            let matches = regex.matches(in: uppercasedName, range: range)
            
            for match in matches {
                codes.insert(nameNSString.substring(with: match.range))
            }
        }
        
        return codes
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

// MARK: - Dashboard ViewModel

@MainActor
class DashboardViewModel: ObservableObject {
    @Published var stats = NetworkStatistics(
        currentPing: 0,
        averagePing: 0,
        minimumPing: 0,
        maximumPing: 0,
        jitter: 0,
        packetLoss: 0,
        quality: .poor
    )
    
    @Published var pingHistory: [PingMonitor.PingResult] = []
    @Published private(set) var timelineEvents: [LatencyTimelineEvent] = []
    @Published var interventionCount: Int = 0
    @Published var isAWDLBlocking: Bool = false
    @Published private(set) var baselineLatencyResults: [String: Double] = [:]
    @Published private(set) var isAutoSelectingTarget: Bool = false
    @Published var selectedTimeframe: Int = 15 { // minutes
        didSet {
            if !DashboardConfig.timeframeOptions.contains(selectedTimeframe) {
                selectedTimeframe = 15
            }
        }
    }
    @Published private(set) var targets: [PingTarget] = []
    @Published var selectedTargetID: String = "" {
        didSet {
            guard selectedTargetID != oldValue else { return }
            userDefaults.set(selectedTargetID, forKey: DashboardConfig.selectedTargetKey)
            restartMonitoring()
            
            if selectedTarget?.source == .geforceNow {
                refreshGeForceNOWTargets(force: false)
            }
        }
    }
    @Published var updateInterval: TimeInterval = DashboardConfig.defaultInterval {
        didSet {
            let sanitized = sanitizedInterval(updateInterval)
            if sanitized != updateInterval {
                updateInterval = sanitized
                return
            }
            guard updateInterval != oldValue else { return }
            userDefaults.set(updateInterval, forKey: DashboardConfig.updateIntervalKey)
            restartMonitoring()
        }
    }
    @Published private(set) var isRefreshingGFNServers: Bool = false
    
    private let pingMonitor = PingMonitor()
    private var interventionTimer: Timer?
    private var gfnRefreshTask: Task<Void, Never>?
    private var baselineSelectionTask: Task<Void, Never>?
    private var isStarted = false
    private var gfnTargets: [PingTarget] = []
    private var lastGFNRefreshDate: Date = .distantPast
    private var previousInterventionCount: Int = 0
    private var hasInitializedInterventionBaseline = false
    
    private let userDefaults = UserDefaults.standard
    
    var selectedTarget: PingTarget? {
        targets.first { $0.id == selectedTargetID }
    }
    
    /// Filtered ping history based on selected timeframe
    var filteredHistory: [PingMonitor.PingResult] {
        let cutoff = Date().addingTimeInterval(-TimeInterval(selectedTimeframe * 60))
        return pingHistory.filter { $0.timestamp > cutoff && $0.success }
    }

    var filteredTimelineEvents: [LatencyTimelineEvent] {
        let cutoff = Date().addingTimeInterval(-TimeInterval(selectedTimeframe * 60))
        return timelineEvents.filter { $0.timestamp > cutoff }
    }
    
    var maxPingInView: Double {
        let max = filteredHistory.map(\.latencyMs).max() ?? 0
        // Add some headroom and ensure minimum scale
        return Swift.max(100, max * 1.1)
    }
    
    init() {
        // Initialize with base targets (no local gateway yet — resolved async in start())
        targets = Self.baseTargets(localGateway: nil)

        if let savedInterval = userDefaults.object(forKey: DashboardConfig.updateIntervalKey) as? Double {
            updateInterval = sanitizedInterval(savedInterval)
        }

        if let savedTargetID = normalizedSavedTargetID(userDefaults.string(forKey: DashboardConfig.selectedTargetKey)),
           targets.contains(where: { $0.id == savedTargetID }) {
            selectedTargetID = savedTargetID
        } else {
            selectedTargetID = targets.first?.id ?? ""
        }
    }
    
    func start() {
        guard !isStarted else { return }
        isStarted = true

        // Resolve local gateway off main thread to avoid blocking UI
        Task.detached(priority: .utility) {
            let gateway = NetworkGatewayResolver.defaultGatewayAddress()
            guard let gateway else { return }
            await MainActor.run { [weak self] in
                guard let self, self.isStarted else { return }
                let previousSelection = self.selectedTargetID
                self.targets = Self.baseTargets(localGateway: gateway) + self.gfnTargets
                if self.targets.contains(where: { $0.id == previousSelection }) {
                    self.selectedTargetID = previousSelection
                } else {
                    self.selectedTargetID = self.targets.first(where: { $0.source == .local })?.id ?? self.targets.first?.id ?? ""
                }
            }
        }

        // Start ping monitoring
        pingMonitor.onPingResult = { [weak self] result in
            Task { @MainActor in
                self?.handlePingResult(result)
            }
        }
        
        pingMonitor.onStatsUpdate = { [weak self] stats in
            Task { @MainActor in
                self?.stats = stats
            }
        }
        
        startMonitoring(clearHistory: false)
        
        // Update AWDL status
        updateAWDLStatus()
        
        // Start intervention counter updates
        updateInterventionCount()
        interventionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateInterventionCount()
                self?.updateAWDLStatus()
            }
        }
        
    }
    
    func stop() {
        isStarted = false
        pingMonitor.onPingResult = nil
        pingMonitor.onStatsUpdate = nil
        pingMonitor.stop()
        interventionTimer?.invalidate()
        interventionTimer = nil
        gfnRefreshTask?.cancel()
        gfnRefreshTask = nil
        baselineSelectionTask?.cancel()
        baselineSelectionTask = nil
        isRefreshingGFNServers = false
        isAutoSelectingTarget = false
    }
    
    private func restartMonitoring() {
        guard isStarted else { return }
        startMonitoring(clearHistory: true)
    }
    
    private func startMonitoring(clearHistory: Bool) {
        guard let target = selectedTarget else { return }
        
        pingMonitor.stop()
        
        if clearHistory {
            pingMonitor.clearHistory()
            pingHistory.removeAll()
        }
        
        pingMonitor.start(server: target.host, port: target.port, interval: updateInterval)
    }
    
    private func handlePingResult(_ result: PingMonitor.PingResult) {
        pingHistory.append(result)
        
        // Keep only a bit over one hour of data to support all dashboard windows.
        let cutoff = Date().addingTimeInterval(-DashboardConfig.historyRetentionSeconds)
        pingHistory.removeAll { $0.timestamp < cutoff }

        if result.success {
            let spikeThreshold = max(100.0, stats.averagePing * 2.0)
            if result.latencyMs >= spikeThreshold {
                appendTimelineEvent(.init(timestamp: result.timestamp, kind: .latencySpike(latencyMs: result.latencyMs)))
            }
        }
    }
    
    private func updateInterventionCount() {
        PingWardenMonitor.shared.getInterventionCount { [weak self] count in
            Task { @MainActor in
                guard let self else { return }

                if !self.hasInitializedInterventionBaseline {
                    self.previousInterventionCount = count
                    self.interventionCount = count
                    self.hasInitializedInterventionBaseline = true
                    return
                }

                if count > self.previousInterventionCount {
                    let delta = count - self.previousInterventionCount
                    self.appendTimelineEvent(.init(timestamp: Date(), kind: .awdlIntervention(delta: delta)))
                }

                self.previousInterventionCount = count
                self.interventionCount = count
            }
        }
    }
    
    private func updateAWDLStatus() {
        isAWDLBlocking = PingWardenMonitor.shared.isMonitoringActive
    }
    
    func refreshGeForceNOWTargetsOnDemand() {
        refreshGeForceNOWTargets(force: true)
    }

    func autoSelectNearestEndpoint() {
        guard !targets.isEmpty else { return }

        baselineSelectionTask?.cancel()
        isAutoSelectingTarget = true

        let candidates = targets
        baselineSelectionTask = Task { [weak self] in
            let sampleCount = DashboardConfig.baselineSampleCount
            let measurements = await Self.collectBaselineMeasurements(
                candidates: candidates,
                sampleCount: sampleCount
            )

            await MainActor.run {
                guard let self else { return }

                self.isAutoSelectingTarget = false
                self.baselineLatencyResults = measurements.mapValues(Self.robustAverage(from:))

                guard let best = self.baselineLatencyResults.min(by: { $0.value < $1.value }),
                      self.targets.contains(where: { $0.id == best.key }) else {
                    return
                }

                self.selectedTargetID = best.key
            }
        }
    }
    
    private func refreshGeForceNOWTargets(force: Bool) {
        if !force,
           Date().timeIntervalSince(lastGFNRefreshDate) < DashboardConfig.gfnRefreshCooldownSeconds {
            return
        }
        
        gfnRefreshTask?.cancel()
        isRefreshingGFNServers = true
        lastGFNRefreshDate = Date()
        
        gfnRefreshTask = Task { [weak self] in
            let discoveredTargets = await GeForceNOWDiscovery.fetchTargets()
            
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.isRefreshingGFNServers = false
                self.gfnTargets = discoveredTargets
                self.rebuildTargets()
            }
        }
    }
    
    private func rebuildTargets() {
        // Use cached gateway from existing targets — do NOT call NetworkGatewayResolver
        // here since this runs on @MainActor and the resolver spawns a blocking Process.
        let gatewayHost = targets.first(where: { $0.source == .local })?.host
        let baseTargets = Self.baseTargets(localGateway: gatewayHost)
        let sortedGFNTargets = gfnTargets.sorted { $0.displayName < $1.displayName }
        
        var deduplicatedTargets: [PingTarget] = []
        var seenIDs = Set<String>()
        
        for target in baseTargets + sortedGFNTargets {
            if seenIDs.insert(target.id).inserted {
                deduplicatedTargets.append(target)
            }
        }
        
        targets = deduplicatedTargets
        
        if !targets.contains(where: { $0.id == selectedTargetID }) {
            selectedTargetID = targets.first(where: { $0.source == .local })?.id ?? targets.first?.id ?? ""
        }
    }
    
    private static func baseTargets(localGateway: String?) -> [PingTarget] {
        var targets: [PingTarget] = []
        
        if let localGateway, !localGateway.isEmpty {
            targets.append(PingTarget(
                displayName: "Local Gateway (\(localGateway))",
                host: localGateway,
                port: 53,
                source: .local
            ))
        }
        
        targets.append(PingTarget(
            displayName: "Cloudflare DNS (Global)",
            host: "1.1.1.1",
            port: 53,
            source: .publicDNS
        ))

        targets.append(PingTarget(
            displayName: "Cloudflare DNS Secondary (Global)",
            host: "1.0.0.1",
            port: 53,
            source: .publicDNS
        ))

        targets.append(PingTarget(
            displayName: "Google DNS (Global)",
            host: "8.8.8.8",
            port: 53,
            source: .publicDNS
        ))

        targets.append(PingTarget(
            displayName: "Google DNS Secondary (Global)",
            host: "8.8.4.4",
            port: 53,
            source: .publicDNS
        ))

        targets.append(PingTarget(
            displayName: "Quad9 DNS (Global)",
            host: "9.9.9.9",
            port: 53,
            source: .publicDNS
        ))

        targets.append(PingTarget(
            displayName: "Quad9 DNS Secondary (Global)",
            host: "149.112.112.112",
            port: 53,
            source: .publicDNS
        ))

        targets.append(PingTarget(
            displayName: "OpenDNS (Global)",
            host: "208.67.222.222",
            port: 53,
            source: .publicDNS
        ))

        targets.append(PingTarget(
            displayName: "OpenDNS Secondary (Global)",
            host: "208.67.220.220",
            port: 53,
            source: .publicDNS
        ))

        targets.append(PingTarget(
            displayName: "AdGuard DNS (Global)",
            host: "94.140.14.14",
            port: 53,
            source: .publicDNS
        ))

        targets.append(PingTarget(
            displayName: "AdGuard DNS Secondary (Global)",
            host: "94.140.15.15",
            port: 53,
            source: .publicDNS
        ))

        targets.append(PingTarget(
            displayName: "CleanBrowsing DNS (Global)",
            host: "185.228.168.9",
            port: 53,
            source: .publicDNS
        ))

        targets.append(PingTarget(
            displayName: "CleanBrowsing DNS Secondary (Global)",
            host: "185.228.169.9",
            port: 53,
            source: .publicDNS
        ))

        targets.append(PingTarget(
            displayName: "Valve Steam API",
            host: "api.steampowered.com",
            port: 443,
            source: .gaming
        ))

        targets.append(PingTarget(
            displayName: "Battle.net API",
            host: "us.api.blizzard.com",
            port: 443,
            source: .gaming
        ))

        targets.append(PingTarget(
            displayName: "GeForce NOW Routing API",
            host: "prod.cloudmatchbeta.nvidiagrid.net",
            port: 443,
            source: .geforceNow
        ))
        
        return targets
    }

    private func appendTimelineEvent(_ event: LatencyTimelineEvent) {
        if let last = timelineEvents.last,
           abs(last.timestamp.timeIntervalSince(event.timestamp)) < 2,
           last.label == event.label {
            return
        }

        timelineEvents.append(event)

        let cutoff = Date().addingTimeInterval(-DashboardConfig.historyRetentionSeconds)
        timelineEvents.removeAll { $0.timestamp < cutoff }
    }
    
    private func sanitizedInterval(_ rawInterval: TimeInterval) -> TimeInterval {
        guard rawInterval > 0 else {
            return DashboardConfig.defaultInterval
        }
        
        if DashboardConfig.intervalOptions.contains(rawInterval) {
            return rawInterval
        }
        
        return DashboardConfig.intervalOptions.min { abs($0 - rawInterval) < abs($1 - rawInterval) } ?? DashboardConfig.defaultInterval
    }
    
    private func normalizedSavedTargetID(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawValue.isEmpty else {
            return nil
        }
        
        if rawValue.contains(":") {
            return rawValue
        }
        
        switch rawValue {
        case "8.8.8.8":
            return "8.8.8.8:53"
        case "1.1.1.1":
            return "1.1.1.1:53"
        default:
            let defaultPort: UInt16 = rawValue.contains("nvidia") ? 443 : 53
            return "\(rawValue):\(defaultPort)"
        }
    }

    nonisolated private static func collectBaselineMeasurements(
        candidates: [PingTarget],
        sampleCount: Int
    ) async -> [String: [Double]] {
        await withTaskGroup(of: (String, [Double])?.self) { group in
            for target in candidates {
                group.addTask {
                    var samples: [Double] = []
                    for sampleIndex in 0..<sampleCount {
                        if Task.isCancelled {
                            return nil
                        }

                        if let latency = TCPProbe.measureLatency(
                            host: target.host,
                            port: target.port,
                            timeoutSeconds: DashboardConfig.baselineProbeTimeoutSeconds
                        ) {
                            samples.append(latency)
                        }

                        if sampleIndex < sampleCount - 1 {
                            try? await Task.sleep(nanoseconds: DashboardConfig.baselineSampleSpacingNanoseconds)
                        }
                    }

                    guard !samples.isEmpty else { return nil }
                    return (target.id, samples)
                }
            }

            var measurements: [String: [Double]] = [:]
            for await result in group {
                guard let (targetID, samples) = result else { continue }
                measurements[targetID] = samples
            }
            return measurements
        }
    }

    nonisolated private static func robustAverage(from values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count < 3 {
            return sorted.reduce(0, +) / Double(sorted.count)
        }

        // Drop one high and one low sample to reduce transient spikes.
        let trimmed = sorted.dropFirst().dropLast()
        return trimmed.reduce(0, +) / Double(trimmed.count)
    }
}

// MARK: - Previews

#Preview("Dashboard") {
    DashboardSettingsContent()
        .frame(width: 500, height: 700)
}
