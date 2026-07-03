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
                return
            }
            refreshFilteredHistory()
        }
    }
    @Published private(set) var targets: [PingTarget] = []
    @Published var selectedTargetID: String = "" {
        didSet {
            guard selectedTargetID != oldValue else { return }
            if !isApplyingProgrammaticSelection {
                // An explicit user selection supersedes a saved target that
                // is still waiting for its async source (gateway/GFN zones).
                pendingSavedTargetID = nil
            }
            // Never overwrite the persisted selection with a temporary
            // fallback while the saved target is still pending — otherwise a
            // saved GFN zone (or gateway) never survives a relaunch.
            if pendingSavedTargetID == nil {
                userDefaults.set(selectedTargetID, forKey: DashboardConfig.selectedTargetKey)
            }
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
    /// Saved target id from a previous session whose source (local gateway,
    /// GFN zone list) hasn't been resolved yet this session. Re-applied the
    /// moment the async source delivers it.
    private var pendingSavedTargetID: String?
    private var isApplyingProgrammaticSelection = false

    private let userDefaults = UserDefaults.standard
    private let customTargetStore = CustomPingTargetStore(userDefaults: PingWardenPreferences.shared.defaults)

    var selectedTarget: PingTarget? {
        targets.first { $0.id == selectedTargetID }
    }

    /// Filtered + downsampled ping history for the chart, memoized per
    /// update. The chart body reads this several times per render; as a
    /// computed property that meant 5+ O(n) filters over ~3900 samples every
    /// second, and Swift Charts degrades sharply past ~1000 marks — burning
    /// CPU exactly during the gaming sessions the app exists to protect.
    @Published private(set) var filteredHistory: [PingMonitor.PingResult] = []

    private static let maxChartPoints = 720

    private func refreshFilteredHistory() {
        let cutoff = Date().addingTimeInterval(-TimeInterval(selectedTimeframe * 60))
        let windowed = pingHistory.filter { $0.timestamp > cutoff && $0.success }
        filteredHistory = Self.downsample(windowed, maxCount: Self.maxChartPoints)
    }

    /// Uniform-stride downsampling that always keeps latency spikes
    /// (>=100 ms) and the newest sample, so thinning the line never hides
    /// the events the chart exists to show.
    private static func downsample(_ points: [PingMonitor.PingResult], maxCount: Int) -> [PingMonitor.PingResult] {
        guard points.count > maxCount else { return points }
        let strideLength = Double(points.count) / Double(maxCount)
        var kept: [PingMonitor.PingResult] = []
        kept.reserveCapacity(maxCount + 16)
        var nextIndex = 0.0
        for (index, point) in points.enumerated() {
            let onStride = Double(index) >= nextIndex
            if onStride || point.latencyMs >= 100 || index == points.count - 1 {
                kept.append(point)
                if onStride {
                    nextIndex += strideLength
                }
            }
        }
        return kept
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
        targets = Self.dedupe(Self.baseTargets(localGateway: nil) + Self.toPingTargets(customTargets))

        if let savedInterval = userDefaults.object(forKey: DashboardConfig.updateIntervalKey) as? Double {
            updateInterval = sanitizedInterval(savedInterval)
        }

        let savedTargetID = normalizedSavedTargetID(userDefaults.string(forKey: DashboardConfig.selectedTargetKey))
        if let savedTargetID, targets.contains(where: { $0.id == savedTargetID }) {
            selectedTargetID = savedTargetID
        } else {
            // The saved target may belong to an async source (gateway, GFN
            // zone). Keep it pending and fall back for now; property
            // observers don't fire during init, so the persisted key is
            // not clobbered by the fallback.
            pendingSavedTargetID = savedTargetID
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
                self.targets = Self.dedupe(
                    Self.baseTargets(localGateway: gateway)
                        + self.gfnTargets.sorted { $0.displayName < $1.displayName }
                        + Self.toPingTargets(self.customTargets)
                )
                self.reapplySelectionAfterTargetsChanged(previousSelection: previousSelection)
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
        // Re-baseline the intervention counter on the next start; otherwise
        // interventions that happened while the dashboard was hidden get
        // logged as one bogus timeline event timestamped at reopen.
        hasInitializedInterventionBaseline = false
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
            refreshFilteredHistory()
        }

        pingMonitor.start(server: target.host, port: target.port, interval: updateInterval)
    }

    private func handlePingResult(_ result: PingMonitor.PingResult) {
        pingHistory.append(result)

        // Keep only a bit over one hour of data to support all dashboard windows.
        let cutoff = Date().addingTimeInterval(-DashboardConfig.historyRetentionSeconds)
        pingHistory.removeAll { $0.timestamp < cutoff }

        refreshFilteredHistory()

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
                // nil = fetch failed. Keep whatever zones we already have —
                // wiping them would reset the user's selected GFN target and
                // clear their chart history over a transient network blip.
                guard let discoveredTargets else { return }
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

        targets = Self.dedupe(baseTargets + sortedGFNTargets + customAsTargets)
        reapplySelectionAfterTargetsChanged(previousSelection: selectedTargetID)
    }

    /// Duplicate host:port combinations (e.g. a custom target that shadows a
    /// built-in) would produce duplicate SwiftUI identifiers in the picker;
    /// the first occurrence wins.
    private static func dedupe(_ list: [PingTarget]) -> [PingTarget] {
        var deduplicated: [PingTarget] = []
        var seenIDs = Set<String>()
        for target in list where seenIDs.insert(target.id).inserted {
            deduplicated.append(target)
        }
        return deduplicated
    }

    /// Re-resolve the selection after the target list changed: a saved-but-
    /// pending target wins the moment its source delivers it, then the
    /// previous selection if still present, then the local-gateway/first
    /// fallback.
    private func reapplySelectionAfterTargetsChanged(previousSelection: String) {
        if let pending = pendingSavedTargetID, targets.contains(where: { $0.id == pending }) {
            pendingSavedTargetID = nil
            applyProgrammaticSelection(pending)
            return
        }
        if targets.contains(where: { $0.id == previousSelection }) {
            if selectedTargetID != previousSelection {
                applyProgrammaticSelection(previousSelection)
            }
            return
        }
        applyProgrammaticSelection(
            targets.first(where: { $0.source == .local })?.id ?? targets.first?.id ?? ""
        )
    }

    /// Selection changes made by the model itself (fallbacks, restoring a
    /// pending saved target) must not discard the pending saved target the
    /// way an explicit user pick does.
    private func applyProgrammaticSelection(_ id: String) {
        isApplyingProgrammaticSelection = true
        selectedTargetID = id
        isApplyingProgrammaticSelection = false
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

    /// Dedicated queue for the blocking baseline probes. Running them
    /// directly inside task-group children would block Swift-concurrency
    /// cooperative-pool threads for seconds (timeout × samples × targets),
    /// starving every other async task in the app.
    nonisolated private static let baselineProbeQueue = DispatchQueue(
        label: "com.amesvt.pingwarden.baselineprobe",
        qos: .utility,
        attributes: .concurrent
    )

    nonisolated private static func measureLatencyOffPool(
        host: String,
        port: UInt16,
        timeoutSeconds: Int
    ) async -> Double? {
        await withCheckedContinuation { continuation in
            baselineProbeQueue.async {
                continuation.resume(returning: TCPProbe.measureLatency(
                    host: host,
                    port: port,
                    timeoutSeconds: timeoutSeconds
                ))
            }
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

                        if let latency = await measureLatencyOffPool(
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
