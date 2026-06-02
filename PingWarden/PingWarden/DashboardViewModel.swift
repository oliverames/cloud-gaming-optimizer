//
//  DashboardViewModel.swift
//  PingWarden
//
//  State container for DashboardSettingsContent. Owns the ping-history
//  buffer, timeline event log, intervention counter, and target selection
//  logic, including auto-selection of the lowest-latency target via TCPProbe.
//

import Foundation
import SwiftUI

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
    @Published private(set) var customTargets: [CustomPingTarget] = []

    private let pingMonitor = PingMonitor()
    nonisolated(unsafe) private var interventionTimer: Timer?
    private var gfnRefreshTask: Task<Void, Never>?
    private var baselineSelectionTask: Task<Void, Never>?
    private var isStarted = false
    private var gfnTargets: [PingTarget] = []
    private var lastGFNRefreshDate: Date = .distantPast
    private var previousInterventionCount: Int = 0
    private var hasInitializedInterventionBaseline = false

    private let userDefaults = UserDefaults.standard
    private let customTargetStore = CustomPingTargetStore(userDefaults: PingWardenPreferences.shared.defaults)

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
        customTargets = customTargetStore.load()
        targets = Self.baseTargets(localGateway: nil) + Self.toPingTargets(customTargets)

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

    // MARK: - Custom Targets

    /// Validate + persist a new custom target. Returns the validation error
    /// (if any) without mutating the store on failure.
    @discardableResult
    func addCustomTarget(displayName: String, host: String, port: Int) -> CustomPingTargetValidationError? {
        if let failure = CustomPingTargetStore.validate(displayName: displayName, host: host, port: port) {
            return failure
        }
        let target = CustomPingTarget(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: UInt16(port)
        )
        customTargets = customTargetStore.add(target)
        rebuildTargets()
        return nil
    }

    func removeCustomTarget(id: UUID) {
        customTargets = customTargetStore.remove(id: id)
        rebuildTargets()
    }

    @discardableResult
    func updateCustomTarget(id: UUID, displayName: String, host: String, port: Int) -> CustomPingTargetValidationError? {
        if let failure = CustomPingTargetStore.validate(displayName: displayName, host: host, port: port) {
            return failure
        }
        let updated = CustomPingTarget(
            id: id,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: UInt16(port)
        )
        customTargets = customTargetStore.update(updated)
        rebuildTargets()
        return nil
    }

    private static func toPingTargets(_ customs: [CustomPingTarget]) -> [PingTarget] {
        customs.map { custom in
            PingTarget(
                displayName: custom.displayName,
                host: custom.host,
                port: custom.port,
                source: .custom
            )
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
                self.targets = Self.baseTargets(localGateway: gateway)
                    + self.gfnTargets
                    + Self.toPingTargets(self.customTargets)
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

        // Populate GeForce NOW zones up front so they're already in the picker
        // when the user opens it. (Previously a Picker .onTapGesture tried to
        // do this on open, but Pickers swallow the tap so it rarely fired.)
        refreshGeForceNOWTargets(force: false)

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

    deinit {
        // Backstop in case onDisappear -> stop() is ever skipped. Timer
        // invalidation and Task cancellation are safe off the main actor;
        // @StateObject deallocation happens on the main thread in practice.
        interventionTimer?.invalidate()
        gfnRefreshTask?.cancel()
        baselineSelectionTask?.cancel()
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

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, !Task.isCancelled else { return }

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
        let customAsTargets = Self.toPingTargets(customTargets)

        var deduplicatedTargets: [PingTarget] = []
        var seenIDs = Set<String>()

        for target in baseTargets + sortedGFNTargets + customAsTargets {
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
