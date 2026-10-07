import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps
import UniformTypeIdentifiers
import UserNotifications

enum MemoryPressure: Int, CaseIterable, Comparable, Codable {
    case normal = 1
    case elevated = 2
    case critical = 4

    static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .elevated: return "Elevated"
        case .critical: return "Critical"
        }
    }
}

struct MemorySnapshot: Equatable {
    let totalBytes: UInt64
    let appBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let cachedBytes: UInt64
    let swapUsedBytes: UInt64
    let swapTotalBytes: UInt64
    let swapIns: UInt64
    let swapOuts: UInt64
    let pressure: MemoryPressure

    static let empty = MemorySnapshot(
        totalBytes: ProcessInfo.processInfo.physicalMemory,
        appBytes: 0,
        wiredBytes: 0,
        compressedBytes: 0,
        cachedBytes: 0,
        swapUsedBytes: 0,
        swapTotalBytes: 0,
        swapIns: 0,
        swapOuts: 0,
        pressure: .normal
    )

    var usedBytes: UInt64 { min(totalBytes, appBytes &+ wiredBytes &+ compressedBytes) }
    var availableBytes: UInt64 { totalBytes > usedBytes ? totalBytes - usedBytes : 0 }
    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return min(100, Double(usedBytes) / Double(totalBytes) * 100)
    }
    var availablePercent: Int { max(0, 100 - Int(usedPercent.rounded())) }
}

struct MemoryHistoryPoint: Identifiable, Equatable, Codable {
    var id = UUID()
    let date: Date
    let usedPercent: Double
    let swapBytes: UInt64
    let pressure: MemoryPressure
    let cpuPercent: Double
    let diskReadBytesPerSecond: UInt64
    let diskWriteBytesPerSecond: UInt64
    let thermalLevel: ThermalLevel
    let powerWatts: Double?
}

enum PowerSourceKind: Equatable {
    case battery
    case acPower
    case unavailable
}

struct PowerSnapshot: Equatable {
    let source: PowerSourceKind
    let batteryPercent: Double?
    let watts: Double?
    let voltageVolts: Double?
    let currentAmps: Double?
    let isCharging: Bool
    let minutesRemaining: Int?
    let adapterRatedWatts: Int?
    let cycleCount: Int?
    let healthCondition: String?
    let fullChargeCapacity: Int?
    let designCapacity: Int?

    static let unavailable = PowerSnapshot(
        source: .unavailable, batteryPercent: nil, watts: nil,
        voltageVolts: nil, currentAmps: nil, isCharging: false,
        minutesRemaining: nil, adapterRatedWatts: nil, cycleCount: nil,
        healthCondition: nil, fullChargeCapacity: nil, designCapacity: nil
    )

    static func estimatedWatts(voltageMillivolts: Int, currentMilliamps: Int) -> Double? {
        guard voltageMillivolts > 0 else { return nil }
        return abs(Double(voltageMillivolts) * Double(currentMilliamps)) / 1_000_000
    }

    var capacityHealthPercent: Double? {
        guard let fullChargeCapacity, let designCapacity, designCapacity > 0 else { return nil }
        return min(100, max(0, Double(fullChargeCapacity) / Double(designCapacity) * 100))
    }
}

enum ThermalLevel: Int, Comparable, Equatable, Codable {
    case nominal
    case fair
    case serious
    case critical

    static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Warm"
        case .serious: return "High"
        case .critical: return "Critical"
        }
    }
}

struct CPUSnapshot: Equatable {
    let overallPercent: Double
    let userPercent: Double
    let systemPercent: Double
    let idlePercent: Double
    let perCorePercent: [Double]
    let logicalCoreCount: Int
    let activeCoreCount: Int

    static let empty = CPUSnapshot(
        overallPercent: 0, userPercent: 0, systemPercent: 0, idlePercent: 100,
        perCorePercent: [], logicalCoreCount: ProcessInfo.processInfo.processorCount,
        activeCoreCount: ProcessInfo.processInfo.activeProcessorCount
    )

    var equivalentCores: Double { Double(activeCoreCount) * overallPercent / 100 }
}

struct HardwareInfo: Equatable {
    let physicalCPUCount: Int
    let logicalCPUCount: Int
    let gpuName: String
    let gpuCoreCount: Int?

    static let loading = HardwareInfo(
        physicalCPUCount: ProcessInfo.processInfo.processorCount,
        logicalCPUCount: ProcessInfo.processInfo.processorCount,
        gpuName: "Detecting GPU…",
        gpuCoreCount: nil
    )
}

enum DashboardMode: String, CaseIterable, Identifiable {
    case memory
    case cpu
    case activity
    case storage
    case insights

    var id: String { rawValue }
    var label: String {
        switch self {
        case .memory: return "Memory"
        case .cpu: return "CPU"
        case .activity: return "Activity"
        case .storage: return "Storage"
        case .insights: return "Insights"
        }
    }
    var symbol: String {
        switch self {
        case .memory: return "memorychip"
        case .cpu: return "cpu"
        case .activity: return "waveform.path.ecg"
        case .storage: return "internaldrive"
        case .insights: return "lightbulb.max"
        }
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case hour
    case day
    case week

    var id: String { rawValue }
    var label: String {
        switch self {
        case .hour: return "1 Hour"
        case .day: return "24 Hours"
        case .week: return "7 Days"
        }
    }
    var duration: TimeInterval {
        switch self {
        case .hour: return 60 * 60
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        }
    }
}

struct MemoryTrendSample: Equatable {
    let date: Date
    let bytes: UInt64
    var cpuPercent: Double = 0
}

struct MemoryGrowthInsight: Identifiable, Equatable {
    let id: String
    let name: String
    let currentBytes: UInt64
    let growthBytes: UInt64
    let rateBytesPerMinute: Double
    let durationMinutes: Double
}

enum MemoryTrendAnalyzer {
    static func insight(key: String, name: String, samples: [MemoryTrendSample]) -> MemoryGrowthInsight? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let minutes = last.date.timeIntervalSince(first.date) / 60
        guard minutes >= 5, last.bytes > first.bytes else { return nil }
        let growth = last.bytes - first.bytes
        let rate = Double(growth) / minutes
        let steps = zip(samples, samples.dropFirst())
        let increases = steps.filter { $1.bytes >= $0.bytes }.count
        let totalSteps = max(1, samples.count - 1)
        guard growth >= 256 * 1_024 * 1_024,
              rate >= 8 * 1_024 * 1_024,
              Double(increases) / Double(totalSteps) >= 0.6
        else { return nil }
        return MemoryGrowthInsight(
            id: key, name: name, currentBytes: last.bytes, growthBytes: growth,
            rateBytesPerMinute: rate, durationMinutes: minutes
        )
    }
}

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case memory
    case cpu
    case both

    var id: String { rawValue }
    var label: String {
        switch self {
        case .memory: return "Memory"
        case .cpu: return "CPU"
        case .both: return "Memory and CPU"
        }
    }
}

enum AppSortMode: String, CaseIterable, Identifiable {
    case memoryDescending
    case memoryAscending
    case cpuDescending
    case cpuAscending
    case diskDescending
    case diskAscending
    case nameAscending
    case nameDescending

    var id: String { rawValue }
    var label: String {
        switch self {
        case .memoryDescending: return "Memory: High to Low"
        case .memoryAscending: return "Memory: Low to High"
        case .cpuDescending: return "CPU: High to Low"
        case .cpuAscending: return "CPU: Low to High"
        case .diskDescending: return "Disk Activity: High to Low"
        case .diskAscending: return "Disk Activity: Low to High"
        case .nameAscending: return "Name: A to Z"
        case .nameDescending: return "Name: Z to A"
        }
    }

    var isNameSort: Bool { self == .nameAscending || self == .nameDescending }

    /// Keeps name sorts across dashboards, but switches a metric sort to the
    /// dashboard's own metric so the CPU list isn't still ordered by memory.
    func adjusted(for mode: DashboardMode) -> AppSortMode {
        switch (mode, self) {
        case (_, .nameAscending), (_, .nameDescending),
             (.memory, .memoryDescending), (.memory, .memoryAscending),
             (.cpu, .cpuDescending), (.cpu, .cpuAscending),
             (.activity, .diskDescending), (.activity, .diskAscending),
             (.storage, _), (.insights, _):
            return self
        case (.memory, _): return .memoryDescending
        case (.cpu, _): return .cpuDescending
        case (.activity, _): return .diskDescending
        }
    }
}

struct AppMemory: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let bundleIdentifier: String?
    let memoryBytes: UInt64
    let memoryChangeBytes: Int64
    let cpuPercent: Double
    let diskReadBytesPerSecond: UInt64
    let diskWriteBytesPerSecond: UInt64
    let detachedProcessCount: Int
    let icon: NSImage
    let relatedPIDs: [pid_t]
    let processStartTimes: [pid_t: UInt64]
    let isPaused: Bool
    let isPausedByManager: Bool
    let isHelper: Bool
    let isFavorite: Bool
    let isIgnored: Bool
    let canControl: Bool
    let isSystemProcess: Bool

    var pid: pid_t { id }
    var preferenceKey: String? { isHelper || isSystemProcess ? nil : bundleIdentifier }

    func wholeMachineCPUPercent(activeProcessorCount: Int) -> Double {
        guard activeProcessorCount > 0 else { return 0 }
        return cpuPercent / Double(activeProcessorCount)
    }
}

enum ProcessActionError: LocalizedError {
    case appNotRunning
    case actionFailed(String)

    var errorDescription: String? {
        switch self {
        case .appNotRunning: return "That app is no longer running."
        case .actionFailed(let action): return "macOS did not allow Memory Manager to \(action) this app."
        }
    }
}

@MainActor
final class ProcessMonitor: ObservableObject {
    @Published private(set) var apps: [AppMemory] = []
    @Published private(set) var memory = MemorySnapshot.empty
    @Published private(set) var cpu = CPUSnapshot.empty
    @Published private(set) var hardware = HardwareInfo.loading
    @Published private(set) var thermalLevel = ThermalLevel(ProcessInfo.processInfo.thermalState)
    @Published private(set) var lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var diskReadBytesPerSecond: UInt64 = 0
    @Published private(set) var diskWriteBytesPerSecond: UInt64 = 0
    @Published private(set) var power = PowerSnapshot.unavailable
    @Published private(set) var history: [MemoryHistoryPoint] = []
    @Published private(set) var memoryGrowthInsights: [MemoryGrowthInsight] = []
    @Published private(set) var sessionEnergyWh = 0.0
    @Published private(set) var sessionAverageWatts = 0.0
    @Published private(set) var sessionPeakWatts = 0.0
    @Published private(set) var sessionStarted = Date()
    @Published private(set) var lastUpdated = Date()
    @Published var errorMessage: String?
    @Published var searchText = ""

    @Published var autoRefresh: Bool {
        didSet { defaults.set(autoRefresh, forKey: Keys.autoRefresh); scheduleTimer() }
    }
    @Published var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval); scheduleTimer() }
    }
    @Published var reduceBackgroundPolling: Bool {
        didSet { defaults.set(reduceBackgroundPolling, forKey: Keys.reduceBackgroundPolling); scheduleTimer() }
    }
    @Published var combineProcesses: Bool {
        didSet { defaults.set(combineProcesses, forKey: Keys.combineProcesses); refresh() }
    }
    @Published var showHistory: Bool {
        didSet { defaults.set(showHistory, forKey: Keys.showHistory) }
    }
    @Published var sortMode: AppSortMode {
        didSet { defaults.set(sortMode.rawValue, forKey: Keys.sortMode); applySortAndFilterMetadata() }
    }
    @Published var dashboardMode: DashboardMode {
        didSet {
            defaults.set(dashboardMode.rawValue, forKey: Keys.dashboardMode)
            let adjustedSort = sortMode.adjusted(for: dashboardMode)
            if adjustedSort != sortMode { sortMode = adjustedSort }
        }
    }
    @Published var menuBarMetric: MenuBarMetric {
        didSet { defaults.set(menuBarMetric.rawValue, forKey: Keys.menuBarMetric) }
    }
    @Published var alertsEnabled: Bool {
        didSet {
            defaults.set(alertsEnabled, forKey: Keys.alertsEnabled)
            if alertsEnabled { requestNotificationPermission() }
        }
    }
    @Published var pressureAlertsEnabled: Bool {
        didSet { defaults.set(pressureAlertsEnabled, forKey: Keys.pressureAlertsEnabled) }
    }
    @Published var swapAlertsEnabled: Bool {
        didSet { defaults.set(swapAlertsEnabled, forKey: Keys.swapAlertsEnabled) }
    }
    @Published var swapAlertThresholdBytes: UInt64 {
        didSet { defaults.set(swapAlertThresholdBytes, forKey: Keys.swapAlertThresholdBytes) }
    }
    @Published var cpuAlertsEnabled: Bool {
        didSet { defaults.set(cpuAlertsEnabled, forKey: Keys.cpuAlertsEnabled) }
    }
    @Published var cpuAlertThreshold: Double {
        didSet { defaults.set(cpuAlertThreshold, forKey: Keys.cpuAlertThreshold) }
    }
    @Published var thermalAlertsEnabled: Bool {
        didSet { defaults.set(thermalAlertsEnabled, forKey: Keys.thermalAlertsEnabled) }
    }
    @Published var growthAlertsEnabled: Bool {
        didSet { defaults.set(growthAlertsEnabled, forKey: Keys.growthAlertsEnabled) }
    }
    @Published var historyRange: HistoryRange {
        didSet { defaults.set(historyRange.rawValue, forKey: Keys.historyRange) }
    }
    @Published var ecoModeEnabled: Bool {
        didSet { defaults.set(ecoModeEnabled, forKey: Keys.ecoModeEnabled); scheduleTimer() }
    }

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []
    private var refreshInProgress = false
    private var appIsActive = true
    private var managedPausedPIDs: [pid_t: UInt64]
    private var favoriteBundleIDs: Set<String>
    private var ignoredBundleIDs: Set<String>
    private var previousMemoryByKey: [String: UInt64] = [:]
    private var previousCPUTicks: CPUTickSnapshot?
    private var previousProcessMetrics: [ProcessIdentity: ProcessCumulative] = [:]
    private var rememberedProcessOwners: [ProcessIdentity: pid_t] = [:]
    private var previousResourceSampleDate: Date?
    private var archivedHistory: [MemoryHistoryPoint] = []
    private var lastArchivedDate: Date?
    private var appMemoryTimelines: [String: [MemoryTrendSample]] = [:]
    private var lastEnergySampleDate: Date?
    private var accumulatedWattSeconds = 0.0
    private var accumulatedPowerSeconds = 0.0
    private var consecutivePressureSamples = 0
    private var consecutiveHighCPUSamples = 0
    private var lastPressureNotification = Date.distantPast
    private var lastSwapNotification = Date.distantPast
    private var lastCPUNotification = Date.distantPast
    private var lastThermalNotification = Date.distantPast
    private var lastGrowthNotifications: [String: Date] = [:]

    private enum Keys {
        static let autoRefresh = "autoRefresh"
        static let refreshInterval = "refreshInterval"
        static let reduceBackgroundPolling = "reduceBackgroundPolling"
        static let combineProcesses = "combineProcesses"
        static let showHistory = "showHistory"
        static let sortMode = "sortMode"
        static let dashboardMode = "dashboardMode"
        static let menuBarMetric = "menuBarMetric"
        static let alertsEnabled = "alertsEnabled"
        static let pressureAlertsEnabled = "pressureAlertsEnabled"
        static let swapAlertsEnabled = "swapAlertsEnabled"
        static let swapAlertThresholdBytes = "swapAlertThresholdBytes"
        static let cpuAlertsEnabled = "cpuAlertsEnabled"
        static let cpuAlertThreshold = "cpuAlertThreshold"
        static let thermalAlertsEnabled = "thermalAlertsEnabled"
        static let growthAlertsEnabled = "growthAlertsEnabled"
        static let historyRange = "historyRange"
        static let ecoModeEnabled = "ecoModeEnabled"
        static let managedPausedProcesses = "managedPausedProcesses"
        static let favoriteBundleIDs = "favoriteBundleIDs"
        static let ignoredBundleIDs = "ignoredBundleIDs"
    }

    init() {
        autoRefresh = defaults.object(forKey: Keys.autoRefresh) as? Bool ?? true
        refreshInterval = defaults.object(forKey: Keys.refreshInterval) as? Double ?? 3
        reduceBackgroundPolling = defaults.object(forKey: Keys.reduceBackgroundPolling) as? Bool ?? true
        combineProcesses = defaults.object(forKey: Keys.combineProcesses) as? Bool ?? true
        showHistory = defaults.object(forKey: Keys.showHistory) as? Bool ?? true
        let savedDashboard = DashboardMode(rawValue: defaults.string(forKey: Keys.dashboardMode) ?? "") ?? .memory
        let savedSort = AppSortMode(rawValue: defaults.string(forKey: Keys.sortMode) ?? "") ?? .memoryDescending
        sortMode = savedSort.adjusted(for: savedDashboard)
        dashboardMode = savedDashboard
        menuBarMetric = MenuBarMetric(rawValue: defaults.string(forKey: Keys.menuBarMetric) ?? "") ?? .both
        alertsEnabled = defaults.object(forKey: Keys.alertsEnabled) as? Bool ?? false
        pressureAlertsEnabled = defaults.object(forKey: Keys.pressureAlertsEnabled) as? Bool ?? true
        swapAlertsEnabled = defaults.object(forKey: Keys.swapAlertsEnabled) as? Bool ?? true
        swapAlertThresholdBytes = (defaults.object(forKey: Keys.swapAlertThresholdBytes) as? NSNumber)?.uint64Value ?? 4_294_967_296
        cpuAlertsEnabled = defaults.object(forKey: Keys.cpuAlertsEnabled) as? Bool ?? false
        cpuAlertThreshold = defaults.object(forKey: Keys.cpuAlertThreshold) as? Double ?? 90
        thermalAlertsEnabled = defaults.object(forKey: Keys.thermalAlertsEnabled) as? Bool ?? true
        growthAlertsEnabled = defaults.object(forKey: Keys.growthAlertsEnabled) as? Bool ?? true
        historyRange = HistoryRange(rawValue: defaults.string(forKey: Keys.historyRange) ?? "") ?? .hour
        ecoModeEnabled = defaults.object(forKey: Keys.ecoModeEnabled) as? Bool ?? true
        managedPausedPIDs = Self.loadManagedPauses(from: defaults)
        favoriteBundleIDs = Set(defaults.stringArray(forKey: Keys.favoriteBundleIDs) ?? [])
        ignoredBundleIDs = Set(defaults.stringArray(forKey: Keys.ignoredBundleIDs) ?? [])

        loadArchivedHistory()

        recoverPausesFromPreviousRun()
        configurePressureSource()
        configureApplicationObservers()
        scheduleTimer()
        refresh()
        loadHardwareInfo()
        if alertsEnabled { requestNotificationPermission() }
    }

    deinit {
        timer?.invalidate()
        pressureSource?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var filteredApps: [AppMemory] {
        let relevant = apps.filter { app in
            switch dashboardMode {
            case .cpu:
                return !app.isSystemProcess || app.cpuPercent >= 0.05
            case .activity:
                return !app.isSystemProcess
                    || app.diskReadBytesPerSecond > 0 || app.diskWriteBytesPerSecond > 0
            case .memory, .storage, .insights:
                return !app.isSystemProcess
            }
        }
        guard !searchText.isEmpty else { return relevant }
        return relevant.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) || String($0.pid).contains(searchText)
        }
    }
    var menuBarApps: [AppMemory] {
        let visible = apps.filter { !$0.isIgnored && !$0.isHelper }
        return Array(visible.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(6))
    }
    var menuBarTitle: String {
        switch menuBarMetric {
        case .memory: return "M \(Int(memory.usedPercent.rounded()))%"
        case .cpu: return "C \(Int(cpu.overallPercent.rounded()))%"
        case .both: return "M\(Int(memory.usedPercent.rounded())) C\(Int(cpu.overallPercent.rounded()))"
        }
    }
    var managedPauseCount: Int { managedPausedPIDs.count }
    var ecoModeActive: Bool {
        ecoModeEnabled && (lowPowerModeEnabled || thermalLevel >= .fair)
    }
    var effectiveRefreshInterval: Double {
        var interval = reduceBackgroundPolling && !appIsActive ? max(10, refreshInterval) : refreshInterval
        if ecoModeEnabled && lowPowerModeEnabled { interval = max(10, interval) }
        if ecoModeEnabled && thermalLevel >= .serious { interval = max(30, interval) }
        else if ecoModeEnabled && thermalLevel >= .fair { interval = max(10, interval) }
        return interval
    }
    var chartHistory: [MemoryHistoryPoint] {
        let cutoff = Date().addingTimeInterval(-historyRange.duration)
        let points = (archivedHistory + history).filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
        guard points.count > 1_500 else { return points }
        let stride = max(1, points.count / 1_500)
        return points.enumerated().compactMap { $0.offset.isMultiple(of: stride) ? $0.element : nil }
    }
    var historicalSampleCount: Int { archivedHistory.count + history.count }
    var sessionDuration: TimeInterval { Date().timeIntervalSince(sessionStarted) }

    /// Up to an hour of memory and CPU samples for an app; helpers aren't tracked.
    func timeline(for app: AppMemory) -> [MemoryTrendSample] {
        appMemoryTimelines[app.bundleIdentifier ?? "\(app.name)#\(app.pid)"] ?? []
    }

    func growthInsight(for app: AppMemory) -> MemoryGrowthInsight? {
        let key = app.bundleIdentifier ?? "\(app.name)#\(app.pid)"
        return memoryGrowthInsights.first { $0.id == key }
    }

    func refresh() {
        guard !refreshInProgress else { return }
        refreshInProgress = true

        let descriptors = NSWorkspace.shared.runningApplications
            .filter {
                $0.processIdentifier > 1 && $0.processIdentifier != getpid()
                    && !$0.isTerminated && $0.localizedName != nil
                    && $0.activationPolicy != .prohibited
            }
            .map { RunningAppDescriptor(app: $0) }
        let roots = Set(descriptors.map(\.pid))
        let combine = combineProcesses
        let managed = managedPausedPIDs
        let favorites = favoriteBundleIDs
        let ignored = ignoredBundleIDs
        let previousTicks = previousCPUTicks
        let previousProcesses = previousProcessMetrics
        let rememberedOwners = rememberedProcessOwners
        let previousSampleDate = previousResourceSampleDate
        let ownershipPrefixes = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.pid, $0.ownershipPrefixes) })

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sampleDate = Date()
            let readings = SystemReader.readProcessMemory(
                roots: roots,
                ownershipPrefixes: ownershipPrefixes,
                rememberedOwners: rememberedOwners,
                includeUnattributed: true
            )
            let snapshot = SystemReader.readSystemMemory()
            let cpuTicks = SystemReader.readCPUTicks()
            let cpuSnapshot = SystemReader.makeCPUSnapshot(previous: previousTicks, current: cpuTicks)
            let elapsed = max(0.001, sampleDate.timeIntervalSince(previousSampleDate ?? sampleDate))
            var rows = Self.makeRows(
                descriptors: descriptors,
                readings: readings,
                combine: combine,
                managedPauses: managed,
                favorites: favorites,
                ignored: ignored,
                previousProcesses: previousProcesses,
                elapsed: elapsed
            )
            rows.append(Self.untrackedCPURow(measuredRows: rows, cpu: cpuSnapshot))
            let currentProcesses = Dictionary(uniqueKeysWithValues: readings.map {
                (ProcessIdentity(pid: $0.pid, startTime: $0.startTime), ProcessCumulative(reading: $0))
            })
            let currentOwners = Dictionary(uniqueKeysWithValues: readings.compactMap { reading in
                reading.attributedOwnerPID.map {
                    (ProcessIdentity(pid: reading.pid, startTime: reading.startTime), $0)
                }
            })
            let readRate = rows.reduce(UInt64(0)) { $0 &+ $1.diskReadBytesPerSecond }
            let writeRate = rows.reduce(UInt64(0)) { $0 &+ $1.diskWriteBytesPerSecond }
            let thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            let power = SystemReader.readPowerSnapshot()

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.removeStaleManagedPauses()
                self.memory = snapshot
                self.cpu = cpuSnapshot
                self.thermalLevel = thermal
                self.lowPowerModeEnabled = lowPower
                self.diskReadBytesPerSecond = readRate
                self.diskWriteBytesPerSecond = writeRate
                self.power = power
                self.previousCPUTicks = cpuTicks
                self.previousProcessMetrics = currentProcesses
                self.rememberedProcessOwners = currentOwners
                self.previousResourceSampleDate = sampleDate
                self.appendHistory(
                    snapshot, cpu: cpuSnapshot, readRate: readRate,
                    writeRate: writeRate, thermal: thermal, power: power, date: sampleDate
                )
                self.updateMemoryTrends(with: rows, date: sampleDate)
                self.apps = self.addMemoryChanges(to: rows)
                self.applySortAndFilterMetadata()
                self.lastUpdated = Date()
                self.refreshInProgress = false
                self.evaluateAlerts(for: snapshot, cpu: cpuSnapshot, thermal: thermal)
            }
        }
    }

    func quit(_ app: AppMemory) {
        guard isSameProcess(app.pid, in: app) else { show(ProcessActionError.actionFailed("quit")); return }
        resumeManagedProcesses(in: app)
        if let running = NSRunningApplication(processIdentifier: app.pid), running.terminate() {
            scheduleRefresh(after: 0.5)
            return
        }
        guard kill(app.pid, SIGTERM) == 0 else { show(ProcessActionError.actionFailed("quit")); return }
        scheduleRefresh(after: 0.5)
    }

    func forceQuit(_ app: AppMemory) {
        guard isSameProcess(app.pid, in: app) else { show(ProcessActionError.actionFailed("force quit")); return }
        resumeManagedProcesses(in: app)
        let rootTerminated = NSRunningApplication(processIdentifier: app.pid)?.forceTerminate() ?? false
        for pid in app.relatedPIDs where pid != app.pid && isSameProcess(pid, in: app) {
            _ = kill(pid, SIGKILL)
        }
        if rootTerminated {
            scheduleRefresh(after: 0.4)
            return
        }
        guard kill(app.pid, SIGKILL) == 0 else { show(ProcessActionError.actionFailed("force quit")); return }
        scheduleRefresh(after: 0.4)
    }

    func togglePause(_ app: AppMemory) {
        let shouldResume = app.isPaused
        let signal = shouldResume ? SIGCONT : SIGSTOP
        let livePIDs = app.relatedPIDs.filter { isSameProcess($0, in: app) }
        // Prefer resuming only what Memory Manager paused, so processes stopped by a
        // debugger or shell job control are left alone.
        let managedPIDs = livePIDs.filter { managedPausedPIDs[$0] == app.processStartTimes[$0] }
        let resumePIDs = managedPIDs.isEmpty ? livePIDs : managedPIDs
        let orderedPIDs = shouldResume ? resumePIDs : livePIDs.reversed()
        var changed = false
        for pid in orderedPIDs {
            guard kill(pid, signal) == 0 else { continue }
            changed = true
            if shouldResume {
                managedPausedPIDs.removeValue(forKey: pid)
            } else if let startTime = app.processStartTimes[pid] {
                managedPausedPIDs[pid] = startTime
            }
        }
        guard changed else { show(ProcessActionError.actionFailed(shouldResume ? "resume" : "pause")); return }
        persistManagedPauses()
        scheduleRefresh(after: 0.15)
    }

    func resumeAllManaged() {
        for (pid, expectedStartTime) in managedPausedPIDs {
            guard SystemReader.processStartTime(for: pid) == expectedStartTime else { continue }
            _ = kill(pid, SIGCONT)
        }
        managedPausedPIDs.removeAll()
        persistManagedPauses()
        refresh()
    }

    func toggleFavorite(_ app: AppMemory) {
        guard let key = app.preferenceKey else { return }
        favoriteBundleIDs.formSymmetricDifference([key])
        defaults.set(Array(favoriteBundleIDs), forKey: Keys.favoriteBundleIDs)
        applySortAndFilterMetadata()
    }

    func toggleIgnored(_ app: AppMemory) {
        guard let key = app.preferenceKey else { return }
        ignoredBundleIDs.formSymmetricDifference([key])
        defaults.set(Array(ignoredBundleIDs), forKey: Keys.ignoredBundleIDs)
        applySortAndFilterMetadata()
    }

    func clearHistory() {
        history.removeAll()
        archivedHistory.removeAll()
        lastArchivedDate = nil
        try? FileManager.default.removeItem(at: Self.historyFileURL)
    }

    func resetEnergySession() {
        sessionStarted = Date()
        sessionEnergyWh = 0
        sessionAverageWatts = 0
        sessionPeakWatts = 0
        accumulatedWattSeconds = 0
        accumulatedPowerSeconds = 0
        lastEnergySampleDate = nil
    }

    nonisolated private static func makeRows(
        descriptors: [RunningAppDescriptor], readings: [ProcessReading], combine: Bool,
        managedPauses: [pid_t: UInt64], favorites: Set<String>, ignored: Set<String>,
        previousProcesses: [ProcessIdentity: ProcessCumulative] = [:], elapsed: TimeInterval = 0
    ) -> [AppMemory] {
        let ownPID = getpid()
        let readings = readings.filter { $0.pid != ownPID }
        let descriptorByPID = Dictionary(descriptors.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let roots = Set(descriptorByPID.keys)
        let parents = Dictionary(uniqueKeysWithValues: readings.map { ($0.pid, $0.parentPID) })
        let readingsByOwner = Dictionary(grouping: readings) {
            $0.attributedOwnerPID ?? SystemReader.ownerPID(for: $0.pid, parents: parents, roots: roots) ?? $0.pid
        }
        let systemReadings = readings.filter {
            $0.attributedOwnerPID == nil
                && SystemReader.ownerPID(for: $0.pid, parents: parents, roots: roots) == nil
        }
        let backgroundRows = systemRows(
            readings: systemReadings, previousProcesses: previousProcesses, elapsed: elapsed
        )

        if combine {
            return descriptors.map { descriptor in
                let related = readingsByOwner[descriptor.pid] ?? []
                let startTimes = Dictionary(uniqueKeysWithValues: related.map { ($0.pid, $0.startTime) })
                let key = descriptor.bundleIdentifier
                let activity = SystemReader.makeProcessActivity(
                    readings: related, previous: previousProcesses, elapsed: elapsed
                )
                return AppMemory(
                    id: descriptor.pid,
                    name: descriptor.name,
                    bundleIdentifier: key,
                    memoryBytes: related.reduce(0) { $0 &+ $1.footprintBytes },
                    memoryChangeBytes: 0,
                    cpuPercent: activity.cpuPercent,
                    diskReadBytesPerSecond: activity.readRate,
                    diskWriteBytesPerSecond: activity.writeRate,
                    detachedProcessCount: related.filter(\.isDetachedHelper).count,
                    icon: descriptor.icon,
                    relatedPIDs: related.map(\.pid),
                    processStartTimes: startTimes,
                    isPaused: related.contains(where: \.isStopped),
                    isPausedByManager: related.contains { managedPauses[$0.pid] == $0.startTime },
                    isHelper: false,
                    isFavorite: key.map(favorites.contains) ?? false,
                    isIgnored: key.map(ignored.contains) ?? false,
                    canControl: descriptor.pid > 1 && !isProtected(descriptor.bundleIdentifier),
                    isSystemProcess: false
                )
            } + backgroundRows
        }

        return readings.compactMap { reading in
            guard let ownerPID = reading.attributedOwnerPID
                    ?? SystemReader.ownerPID(for: reading.pid, parents: parents, roots: roots),
                  let owner = descriptorByPID[ownerPID] else { return nil }
            let isHelper = reading.pid != ownerPID
            let key = owner.bundleIdentifier
            let activity = SystemReader.makeProcessActivity(
                readings: [reading], previous: previousProcesses, elapsed: elapsed
            )
            return AppMemory(
                id: reading.pid,
                name: isHelper ? "\(owner.name) · \(reading.shortName)" : owner.name,
                bundleIdentifier: key,
                memoryBytes: reading.footprintBytes,
                memoryChangeBytes: 0,
                cpuPercent: activity.cpuPercent,
                diskReadBytesPerSecond: activity.readRate,
                diskWriteBytesPerSecond: activity.writeRate,
                detachedProcessCount: reading.isDetachedHelper ? 1 : 0,
                icon: owner.icon,
                relatedPIDs: [reading.pid],
                processStartTimes: [reading.pid: reading.startTime],
                isPaused: reading.isStopped,
                isPausedByManager: managedPauses[reading.pid] == reading.startTime,
                isHelper: isHelper,
                isFavorite: !isHelper && (key.map(favorites.contains) ?? false),
                isIgnored: !isHelper && (key.map(ignored.contains) ?? false),
                canControl: reading.pid > 1 && !isProtected(owner.bundleIdentifier),
                isSystemProcess: false
            )
        } + backgroundRows
    }

    nonisolated private static func systemRows(
        readings: [ProcessReading],
        previousProcesses: [ProcessIdentity: ProcessCumulative],
        elapsed: TimeInterval
    ) -> [AppMemory] {
        readings.map { reading in
            let activity = SystemReader.makeProcessActivity(
                readings: [reading], previous: previousProcesses, elapsed: elapsed
            )
            return AppMemory(
                id: reading.pid,
                name: SystemReader.processDisplayName(command: reading.command),
                bundleIdentifier: nil,
                memoryBytes: reading.footprintBytes,
                memoryChangeBytes: 0,
                cpuPercent: activity.cpuPercent,
                diskReadBytesPerSecond: activity.readRate,
                diskWriteBytesPerSecond: activity.writeRate,
                detachedProcessCount: 0,
                icon: NSImage(systemSymbolName: "gearshape.2.fill", accessibilityDescription: "System process")
                    ?? NSImage(),
                relatedPIDs: [reading.pid],
                processStartTimes: [reading.pid: reading.startTime],
                isPaused: reading.isStopped,
                isPausedByManager: false,
                isHelper: true,
                isFavorite: false,
                isIgnored: false,
                canControl: false,
                isSystemProcess: true
            )
        }
    }

    nonisolated private static func untrackedCPURow(
        measuredRows: [AppMemory], cpu: CPUSnapshot
    ) -> AppMemory {
        let totalCorePercent = cpu.overallPercent * Double(cpu.activeCoreCount)
        let measuredCorePercent = measuredRows.reduce(0) { $0 + $1.cpuPercent }
        let residualCorePercent = max(0, totalCorePercent - measuredCorePercent)
        return AppMemory(
            id: -1,
            name: "Kernel & untracked activity",
            bundleIdentifier: nil,
            memoryBytes: 0,
            memoryChangeBytes: 0,
            cpuPercent: residualCorePercent,
            diskReadBytesPerSecond: 0,
            diskWriteBytesPerSecond: 0,
            detachedProcessCount: 0,
            icon: NSImage(systemSymbolName: "cpu", accessibilityDescription: "Kernel activity") ?? NSImage(),
            relatedPIDs: [],
            processStartTimes: [:],
            isPaused: false,
            isPausedByManager: false,
            isHelper: true,
            isFavorite: false,
            isIgnored: false,
            canControl: false,
            isSystemProcess: true
        )
    }

    private func addMemoryChanges(to rows: [AppMemory]) -> [AppMemory] {
        var nextMemory: [String: UInt64] = [:]
        let updated = rows.map { row -> AppMemory in
            let key = row.bundleIdentifier.map { row.isHelper ? "\($0):\(row.pid)" : $0 } ?? "pid:\(row.pid)"
            let previous = previousMemoryByKey[key] ?? row.memoryBytes
            let change = Int64(clamping: row.memoryBytes) - Int64(clamping: previous)
            nextMemory[key] = row.memoryBytes
            return row.replacing(memoryChangeBytes: change)
        }
        previousMemoryByKey = nextMemory
        return updated
    }

    private func applySortAndFilterMetadata() {
        apps = apps.map { app in
            app.replacing(
                isFavorite: app.preferenceKey.map(favoriteBundleIDs.contains) ?? false,
                isIgnored: app.preferenceKey.map(ignoredBundleIDs.contains) ?? false
            )
        }.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            switch sortMode {
            case .memoryDescending:
                return lhs.memoryBytes == rhs.memoryBytes ? lhs.name < rhs.name : lhs.memoryBytes > rhs.memoryBytes
            case .memoryAscending:
                return lhs.memoryBytes == rhs.memoryBytes ? lhs.name < rhs.name : lhs.memoryBytes < rhs.memoryBytes
            case .cpuDescending:
                return lhs.cpuPercent == rhs.cpuPercent ? lhs.name < rhs.name : lhs.cpuPercent > rhs.cpuPercent
            case .cpuAscending:
                return lhs.cpuPercent == rhs.cpuPercent ? lhs.name < rhs.name : lhs.cpuPercent < rhs.cpuPercent
            case .diskDescending:
                let lhsDisk = lhs.diskReadBytesPerSecond &+ lhs.diskWriteBytesPerSecond
                let rhsDisk = rhs.diskReadBytesPerSecond &+ rhs.diskWriteBytesPerSecond
                return lhsDisk == rhsDisk ? lhs.name < rhs.name : lhsDisk > rhsDisk
            case .diskAscending:
                let lhsDisk = lhs.diskReadBytesPerSecond &+ lhs.diskWriteBytesPerSecond
                let rhsDisk = rhs.diskReadBytesPerSecond &+ rhs.diskWriteBytesPerSecond
                return lhsDisk == rhsDisk ? lhs.name < rhs.name : lhsDisk < rhsDisk
            case .nameAscending:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .nameDescending:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
            }
        }
    }

    private func appendHistory(
        _ snapshot: MemorySnapshot, cpu: CPUSnapshot, readRate: UInt64,
        writeRate: UInt64, thermal: ThermalLevel, power: PowerSnapshot, date: Date
    ) {
        let point = MemoryHistoryPoint(
            date: date, usedPercent: snapshot.usedPercent,
            swapBytes: snapshot.swapUsedBytes, pressure: snapshot.pressure,
            cpuPercent: cpu.overallPercent,
            diskReadBytesPerSecond: readRate,
            diskWriteBytesPerSecond: writeRate,
            thermalLevel: thermal,
            powerWatts: power.watts
        )
        history.append(point)
        if history.count > 1_200 { history.removeFirst(history.count - 1_200) }

        if lastArchivedDate.map({ date.timeIntervalSince($0) >= 60 }) ?? true {
            archivedHistory.append(point)
            let cutoff = date.addingTimeInterval(-HistoryRange.week.duration)
            archivedHistory.removeAll { $0.date < cutoff }
            lastArchivedDate = date
            persistArchivedHistory()
        }

        if let watts = power.watts {
            if let previous = lastEnergySampleDate {
                let elapsed = min(60, max(0, date.timeIntervalSince(previous)))
                accumulatedWattSeconds += watts * elapsed
                accumulatedPowerSeconds += elapsed
                sessionEnergyWh = accumulatedWattSeconds / 3_600
                sessionAverageWatts = accumulatedPowerSeconds > 0
                    ? accumulatedWattSeconds / accumulatedPowerSeconds : 0
            }
            sessionPeakWatts = max(sessionPeakWatts, watts)
            lastEnergySampleDate = date
        } else {
            lastEnergySampleDate = nil
        }
    }

    private func updateMemoryTrends(with rows: [AppMemory], date: Date) {
        let cutoff = date.addingTimeInterval(-60 * 60)
        for app in rows where !app.isHelper {
            let key = app.bundleIdentifier ?? "\(app.name)#\(app.pid)"
            var samples = appMemoryTimelines[key] ?? []
            samples.append(MemoryTrendSample(date: date, bytes: app.memoryBytes, cpuPercent: app.cpuPercent))
            samples.removeAll { $0.date < cutoff }
            appMemoryTimelines[key] = samples
        }
        let runningKeys = Set(rows.map { $0.bundleIdentifier ?? "\($0.name)#\($0.pid)" })
        appMemoryTimelines = appMemoryTimelines.filter { runningKeys.contains($0.key) }
        memoryGrowthInsights = rows.filter { !$0.isHelper }.compactMap { app in
            let key = app.bundleIdentifier ?? "\(app.name)#\(app.pid)"
            return MemoryTrendAnalyzer.insight(
                key: key, name: app.name, samples: appMemoryTimelines[key] ?? []
            )
        }.sorted { $0.rateBytesPerMinute > $1.rateBytesPerMinute }
    }

    private static var historyFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MemoryManager", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    private func loadArchivedHistory() {
        guard let data = try? Data(contentsOf: Self.historyFileURL),
              let decoded = try? JSONDecoder().decode([MemoryHistoryPoint].self, from: data)
        else { return }
        let cutoff = Date().addingTimeInterval(-HistoryRange.week.duration)
        archivedHistory = decoded.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
        lastArchivedDate = archivedHistory.last?.date
    }

    private func persistArchivedHistory() {
        let points = archivedHistory
        let url = Self.historyFileURL
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try JSONEncoder().encode(points).write(to: url, options: .atomic)
            } catch { }
        }
    }

    private func evaluateAlerts(for snapshot: MemorySnapshot, cpu: CPUSnapshot, thermal: ThermalLevel) {
        guard alertsEnabled else { return }
        let now = Date()
        let cooldown: TimeInterval = 15 * 60
        consecutivePressureSamples = snapshot.pressure >= .elevated ? consecutivePressureSamples + 1 : 0
        consecutiveHighCPUSamples = cpu.overallPercent >= cpuAlertThreshold ? consecutiveHighCPUSamples + 1 : 0

        if pressureAlertsEnabled, consecutivePressureSamples >= 2,
           now.timeIntervalSince(lastPressureNotification) > cooldown {
            postNotification(
                identifier: "memory-pressure",
                title: "Memory pressure is \(snapshot.pressure.label.lowercased())",
                body: "Memory Manager can show which apps are using the most memory."
            )
            lastPressureNotification = now
        }
        if swapAlertsEnabled, snapshot.swapUsedBytes >= swapAlertThresholdBytes,
           now.timeIntervalSince(lastSwapNotification) > cooldown {
            postNotification(
                identifier: "swap-usage",
                title: "Swap usage passed \(formatBytes(swapAlertThresholdBytes))",
                body: "Current swap usage is \(formatBytes(snapshot.swapUsedBytes))."
            )
            lastSwapNotification = now
        }
        if cpuAlertsEnabled, consecutiveHighCPUSamples >= 2,
           now.timeIntervalSince(lastCPUNotification) > cooldown {
            postNotification(
                identifier: "cpu-usage",
                title: "CPU usage is high",
                body: "Overall CPU usage is \(Int(cpu.overallPercent.rounded()))%."
            )
            lastCPUNotification = now
        }
        if thermalAlertsEnabled, thermal >= .serious,
           now.timeIntervalSince(lastThermalNotification) > cooldown {
            postNotification(
                identifier: "thermal-pressure",
                title: "Thermal pressure is \(thermal.label.lowercased())",
                body: "macOS may reduce performance until the computer cools down."
            )
            lastThermalNotification = now
        }
        if growthAlertsEnabled, let growth = memoryGrowthInsights.first,
           now.timeIntervalSince(lastGrowthNotifications[growth.id] ?? .distantPast) > 60 * 60 {
            postNotification(
                identifier: "memory-growth-\(growth.id.hashValue)",
                title: "\(growth.name) is steadily growing",
                body: "Memory increased by \(formatBytes(growth.growthBytes)) over \(Int(growth.durationMinutes)) minutes. This is a pattern to review, not proof of a leak."
            )
            lastGrowthNotifications[growth.id] = now
        }
    }

    func exportHistory() {
        let panel = NSSavePanel()
        panel.title = "Export Activity History"
        panel.nameFieldStringValue = "Memory Manager History.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var csv = "Timestamp,Memory Used %,Swap Bytes,Memory Pressure,CPU %,Disk Read B/s,Disk Write B/s,Thermal State,Battery Power W\n"
        let formatter = ISO8601DateFormatter()
        for point in (archivedHistory + history).sorted(by: { $0.date < $1.date }) {
            let watts = point.powerWatts.map { String($0) } ?? ""
            csv += "\(formatter.string(from: point.date)),\(point.usedPercent),\(point.swapBytes),\(point.pressure.label),\(point.cpuPercent),\(point.diskReadBytesPerSecond),\(point.diskWriteBytesPerSecond),\(point.thermalLevel.label),\(watts)\n"
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            show(error)
        }
    }

    func exportDiagnosticReport(storage: StorageMonitor) {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostic Snapshot"
        panel.nameFieldStringValue = "Memory Manager Diagnostic.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try diagnosticReport(storage: storage).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            show(error)
        }
    }

    func diagnosticReport(storage: StorageMonitor) -> String {
        let formatter = ISO8601DateFormatter()
        let powerText = power.watts.map { String(format: "%.1f W", $0) } ?? "Unavailable"
        let largest = apps.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(10)
            .map { "- \($0.name): \(formatBytes($0.memoryBytes)), CPU \(Int($0.cpuPercent.rounded()))%" }
            .joined(separator: "\n")
        let growth = memoryGrowthInsights.isEmpty ? "- No sustained rapid growth detected." :
            memoryGrowthInsights.map {
                "- \($0.name): +\(formatBytes($0.growthBytes)) over \(Int($0.durationMinutes)) minutes"
            }.joined(separator: "\n")
        let storageText = storage.lastScanned == nil
            ? "Storage has not been scanned in this session."
            : "Classified \(formatBytes(storage.scannedBytes)); \(storage.inaccessibleCount) inaccessible items."
        return """
        # Memory Manager Diagnostic Snapshot

        Generated: \(formatter.string(from: Date()))

        ## System

        - Memory: \(formatBytes(memory.usedBytes)) / \(formatBytes(memory.totalBytes)) (\(Int(memory.usedPercent.rounded()))%)
        - Memory pressure: \(memory.pressure.label)
        - Swap: \(formatBytes(memory.swapUsedBytes)) / \(formatBytes(memory.swapTotalBytes))
        - CPU: \(Int(cpu.overallPercent.rounded()))% (\(String(format: "%.1f", cpu.equivalentCores)) equivalent cores)
        - Thermal state: \(thermalLevel.label)
        - Low Power Mode: \(lowPowerModeEnabled ? "On" : "Off")
        - Eco Mode: \(ecoModeActive ? "Active" : ecoModeEnabled ? "Ready" : "Off")
        - Battery power: \(powerText)
        - Session energy: \(String(format: "%.3f Wh", sessionEnergyWh))
        - Disk: read \(formatBytes(diskReadBytesPerSecond))/s, write \(formatBytes(diskWriteBytesPerSecond))/s

        ## Largest Apps

        \(largest)

        ## Sustained Memory Growth

        \(growth)

        ## Storage

        - \(formatBytes(storage.volume.freeBytes)) free of \(formatBytes(storage.volume.totalBytes))
        - \(storageText)

        ## Notes

        Battery watts are voltage × current reported by macOS and do not represent whole-system wall draw while plugged in. Storage totals can differ because of APFS snapshots, shared blocks, purgeable data, and inaccessible files.
        """
    }

    private func loadHardwareInfo() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = SystemReader.readHardwareInfo()
            Task { @MainActor [weak self] in self?.hardware = info }
        }
    }

    private func postNotification(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func configurePressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main
        )
        source.setEventHandler { [weak self] in self?.refresh() }
        source.resume()
        pressureSource = source
    }

    private func configureApplicationObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.appIsActive = true
                self?.scheduleTimer()
                if self?.autoRefresh == true { self?.refresh() }
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.appIsActive = false; self?.scheduleTimer() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } })
        observers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.scheduleTimer()
                self?.refresh()
            }
        })
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.thermalLevel = ThermalLevel(ProcessInfo.processInfo.thermalState)
                self?.scheduleTimer()
            }
        })
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard autoRefresh else { return }
        timer = Timer.scheduledTimer(withTimeInterval: effectiveRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func scheduleRefresh(after seconds: Double) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds)); self?.refresh()
        }
    }

    private func resumeManagedProcesses(in app: AppMemory) {
        for pid in app.relatedPIDs {
            guard let expected = managedPausedPIDs.removeValue(forKey: pid) else { continue }
            if SystemReader.processStartTime(for: pid) == expected { _ = kill(pid, SIGCONT) }
        }
        persistManagedPauses()
    }

    /// True when `pid` still refers to the process that was listed, not a reused PID.
    private func isSameProcess(_ pid: pid_t, in app: AppMemory) -> Bool {
        guard pid > 1, pid != getpid(), let expected = app.processStartTimes[pid] else { return false }
        return SystemReader.processStartTime(for: pid) == expected
    }

    /// Apps whose loss would end the login session or break the desktop.
    nonisolated static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.loginwindow", "com.apple.dock", "com.apple.systemuiserver",
        "com.apple.WindowManager", "com.apple.controlcenter", "com.apple.notificationcenterui",
        "com.apple.coreservices.uiagent", "com.apple.SecurityAgent"
    ]

    nonisolated private static func isProtected(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(protectedBundleIdentifiers.contains) ?? false
    }

    private func removeStaleManagedPauses() {
        managedPausedPIDs = managedPausedPIDs.filter {
            SystemReader.processStartTime(for: $0.key) == $0.value
        }
        persistManagedPauses()
    }

    private func recoverPausesFromPreviousRun() {
        guard !managedPausedPIDs.isEmpty else { return }
        for (pid, startTime) in managedPausedPIDs where SystemReader.processStartTime(for: pid) == startTime {
            _ = kill(pid, SIGCONT)
        }
        managedPausedPIDs.removeAll()
        persistManagedPauses()
    }

    private static func loadManagedPauses(from defaults: UserDefaults) -> [pid_t: UInt64] {
        Dictionary((defaults.stringArray(forKey: Keys.managedPausedProcesses) ?? []).compactMap {
            let parts = $0.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let pid = pid_t(parts[0]), let start = UInt64(parts[1]) else { return nil }
            return (pid, start)
        }, uniquingKeysWith: { first, _ in first })
    }

    private func persistManagedPauses() {
        defaults.set(managedPausedPIDs.map { "\($0.key):\($0.value)" }, forKey: Keys.managedPausedProcesses)
    }

    private func show(_ error: Error) { errorMessage = error.localizedDescription }
}

private extension AppMemory {
    func replacing(
        memoryChangeBytes: Int64? = nil,
        isFavorite: Bool? = nil,
        isIgnored: Bool? = nil
    ) -> AppMemory {
        AppMemory(
            id: id, name: name, bundleIdentifier: bundleIdentifier,
            memoryBytes: memoryBytes, memoryChangeBytes: memoryChangeBytes ?? self.memoryChangeBytes,
            cpuPercent: cpuPercent,
            diskReadBytesPerSecond: diskReadBytesPerSecond,
            diskWriteBytesPerSecond: diskWriteBytesPerSecond,
            detachedProcessCount: detachedProcessCount,
            icon: icon, relatedPIDs: relatedPIDs, processStartTimes: processStartTimes,
            isPaused: isPaused, isPausedByManager: isPausedByManager, isHelper: isHelper,
            isFavorite: isFavorite ?? self.isFavorite, isIgnored: isIgnored ?? self.isIgnored,
            canControl: canControl, isSystemProcess: isSystemProcess
        )
    }
}

private struct RunningAppDescriptor: @unchecked Sendable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage
    let ownershipPrefixes: [String]

    init(app: NSRunningApplication) {
        pid = app.processIdentifier
        name = app.localizedName ?? "Unknown App"
        bundleIdentifier = app.bundleIdentifier
        icon = app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        var prefixes: [String] = []
        if let bundlePath = app.bundleURL?.resolvingSymlinksInPath().path {
            prefixes.append(bundlePath + "/")
        }
        if app.bundleIdentifier == "com.openai.codex" {
            prefixes.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path + "/")
        }
        ownershipPrefixes = prefixes
    }
}

struct ProcessReading: Equatable {
    let pid: pid_t
    let parentPID: pid_t
    let footprintBytes: UInt64
    let cpuTimeNanoseconds: UInt64
    let diskReadBytes: UInt64
    let diskWriteBytes: UInt64
    let startTime: UInt64
    let isStopped: Bool
    let command: String
    let attributedOwnerPID: pid_t?
    let isDetachedHelper: Bool

    var shortName: String {
        let value = URL(fileURLWithPath: command).lastPathComponent
        return value.isEmpty ? "Helper" : value
    }
}

struct ProcessIdentity: Hashable {
    let pid: pid_t
    let startTime: UInt64
}

struct ProcessCumulative: Equatable {
    let cpuTimeNanoseconds: UInt64
    let diskReadBytes: UInt64
    let diskWriteBytes: UInt64

    init(reading: ProcessReading) {
        cpuTimeNanoseconds = reading.cpuTimeNanoseconds
        diskReadBytes = reading.diskReadBytes
        diskWriteBytes = reading.diskWriteBytes
    }
}

struct CoreTicks: Equatable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var total: UInt64 { user &+ system &+ idle &+ nice }
    var busy: UInt64 { user &+ system &+ nice }
}

struct CPUTickSnapshot: Equatable {
    let cores: [CoreTicks]
}

enum SystemReader {
    private static func readSmartBatteryProperties() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else { return [:] }
        return dictionary
    }

    static func readPowerSnapshot() -> PowerSnapshot {
        var adapterRatedWatts: Int?
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() {
            adapterRatedWatts = ((adapter as NSDictionary)["Watts"] as? NSNumber)?.intValue
        }

        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return PowerSnapshot(
                source: .unavailable, batteryPercent: nil, watts: nil,
                voltageVolts: nil, currentAmps: nil, isCharging: false,
                minutesRemaining: nil, adapterRatedWatts: adapterRatedWatts,
                cycleCount: nil, healthCondition: nil,
                fullChargeCapacity: nil, designCapacity: nil
            )
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }
            let transport = description["Transport Type"] as? String
            let type = description["Type"] as? String
            guard transport == "Internal" || type == "InternalBattery" else { continue }

            let voltageMillivolts = (description["Voltage"] as? NSNumber)?.intValue
            let currentMilliamps = (description["Current"] as? NSNumber)?.intValue
            let voltage = voltageMillivolts.map { Double($0) / 1_000 }
            let current = currentMilliamps.map { Double($0) / 1_000 }
            let watts = voltageMillivolts.flatMap { millivolts in
                currentMilliamps.flatMap {
                    PowerSnapshot.estimatedWatts(
                        voltageMillivolts: millivolts, currentMilliamps: $0
                    )
                }
            }
            let currentCapacity = (description["Current Capacity"] as? NSNumber)?.doubleValue
            let maximumCapacity = (description["Max Capacity"] as? NSNumber)?.doubleValue
            let percent: Double? = {
                guard let currentCapacity, let maximumCapacity, maximumCapacity > 0 else { return nil }
                return min(100, max(0, currentCapacity / maximumCapacity * 100))
            }()
            let charging = (description["Is Charging"] as? NSNumber)?.boolValue ?? false
            let state = description["Power Source State"] as? String
            let sourceKind: PowerSourceKind = state == "Battery Power" ? .battery : .acPower
            let timeKey = charging ? "Time to Full Charge" : "Time to Empty"
            let rawMinutes = (description[timeKey] as? NSNumber)?.intValue
            let minutes = rawMinutes.flatMap { $0 >= 0 ? $0 : nil }
            let health = (description[kIOPSBatteryHealthConditionKey] as? String)
                ?? (description[kIOPSBatteryHealthKey] as? String)
            // IOPS reports Max Capacity as a percentage on Apple silicon, so read the
            // mAh capacities and cycle count from the battery's registry entry instead.
            let battery = readSmartBatteryProperties()
            let cycleCount = (battery["CycleCount"] as? NSNumber)?.intValue
            let fullCapacity = ((battery["AppleRawMaxCapacity"] ?? battery["NominalChargeCapacity"]) as? NSNumber)?.intValue
            let designCapacity = (battery["DesignCapacity"] as? NSNumber)?.intValue

            return PowerSnapshot(
                source: sourceKind, batteryPercent: percent, watts: watts,
                voltageVolts: voltage, currentAmps: current, isCharging: charging,
                minutesRemaining: minutes, adapterRatedWatts: adapterRatedWatts,
                cycleCount: cycleCount, healthCondition: health,
                fullChargeCapacity: fullCapacity, designCapacity: designCapacity
            )
        }

        return PowerSnapshot(
            source: .unavailable, batteryPercent: nil, watts: nil,
            voltageVolts: nil, currentAmps: nil, isCharging: false,
            minutesRemaining: nil, adapterRatedWatts: adapterRatedWatts,
            cycleCount: nil, healthCondition: nil,
            fullChargeCapacity: nil, designCapacity: nil
        )
    }

    static func readSystemMemory() -> MemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .empty }

        let page = UInt64(pageSize)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeablePages = UInt64(stats.purgeable_count)
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : internalPages
        let swap = readSwapUsage()
        return MemorySnapshot(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            appBytes: appPages * page,
            wiredBytes: UInt64(stats.wire_count) * page,
            compressedBytes: UInt64(stats.compressor_page_count) * page,
            cachedBytes: (UInt64(stats.external_page_count) + purgeablePages) * page,
            swapUsedBytes: swap.usedBytes,
            swapTotalBytes: swap.totalBytes,
            swapIns: UInt64(stats.swapins),
            swapOuts: UInt64(stats.swapouts),
            pressure: readPressureLevel()
        )
    }

    static func readProcessMemory(
        roots: Set<pid_t>,
        ownershipPrefixes: [pid_t: [String]] = [:],
        rememberedOwners: [ProcessIdentity: pid_t] = [:],
        includeUnattributed: Bool = false
    ) -> [ProcessReading] {
        guard let output = run("/bin/ps", arguments: ["-axo", "pid=,ppid=,rss=,state=,comm="]) else { return [] }
        let raw: [(pid: pid_t, parent: pid_t, rss: UInt64, stopped: Bool, command: String)] = output
            .split(separator: "\n").compactMap { line in
                let fields = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
                guard fields.count >= 5, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]),
                      let rssKB = UInt64(fields[2]) else { return nil }
                return (pid, parent, rssKB * 1_024, fields[3].contains("T"), String(fields[4]))
            }
        let parents = Dictionary(uniqueKeysWithValues: raw.map { ($0.pid, $0.parent) })
        let automaticBundleRules = raw.compactMap { process -> (prefix: String, ownerPID: pid_t)? in
            guard roots.contains(process.pid),
                  let appEnd = process.command.range(of: ".app/")?.upperBound else { return nil }
            return (String(process.command[..<appEnd]), process.pid)
        }
        let configuredPathRules = ownershipPrefixes.flatMap { ownerPID, prefixes in
            prefixes.map { (prefix: $0, ownerPID: ownerPID) }
        }
        let pathRules = (configuredPathRules + automaticBundleRules)
            .sorted { $0.prefix.count > $1.prefix.count }
        let rememberedByPID = Dictionary(uniqueKeysWithValues: rememberedOwners.map {
            ($0.key.pid, (startTime: $0.key.startTime, ownerPID: $0.value))
        })
        return raw.compactMap { process in
            let treeOwner = ownerPID(for: process.pid, parents: parents, roots: roots)
            let pathOwner = pathRules.first { process.command.hasPrefix($0.prefix) }?.ownerPID
            let remembered = rememberedByPID[process.pid]
            guard includeUnattributed || treeOwner != nil || pathOwner != nil || remembered != nil else {
                return nil
            }
            let usage = resourceUsage(for: process.pid)
            let startTime = usage?.startTime ?? 0
            let rememberedOwner = remembered.flatMap {
                $0.startTime == startTime && roots.contains($0.ownerPID) ? $0.ownerPID : nil
            }
            let attributedOwner = treeOwner ?? pathOwner ?? rememberedOwner
            guard includeUnattributed || attributedOwner != nil else { return nil }
            return ProcessReading(
                pid: process.pid, parentPID: process.parent,
                footprintBytes: usage?.footprint ?? process.rss,
                cpuTimeNanoseconds: usage?.cpuTimeNanoseconds ?? 0,
                diskReadBytes: usage?.diskReadBytes ?? 0,
                diskWriteBytes: usage?.diskWriteBytes ?? 0,
                startTime: startTime,
                isStopped: process.stopped, command: process.command,
                attributedOwnerPID: attributedOwner,
                isDetachedHelper: treeOwner == nil
            )
        }
    }

    static func makeProcessActivity(
        readings: [ProcessReading],
        previous: [ProcessIdentity: ProcessCumulative],
        elapsed: TimeInterval,
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> (cpuPercent: Double, readRate: UInt64, writeRate: UInt64) {
        guard elapsed > 0 else { return (0, 0, 0) }
        var cpuNanoseconds: UInt64 = 0
        var readBytes: UInt64 = 0
        var writeBytes: UInt64 = 0
        for reading in readings {
            let key = ProcessIdentity(pid: reading.pid, startTime: reading.startTime)
            guard let old = previous[key] else { continue }
            cpuNanoseconds &+= reading.cpuTimeNanoseconds >= old.cpuTimeNanoseconds
                ? reading.cpuTimeNanoseconds - old.cpuTimeNanoseconds : 0
            readBytes &+= reading.diskReadBytes >= old.diskReadBytes
                ? reading.diskReadBytes - old.diskReadBytes : 0
            writeBytes &+= reading.diskWriteBytes >= old.diskWriteBytes
                ? reading.diskWriteBytes - old.diskWriteBytes : 0
        }
        let maximumCPU = Double(max(1, activeProcessorCount)) * 100
        let cpu = min(maximumCPU, Double(cpuNanoseconds) / 1_000_000_000 / elapsed * 100)
        return (cpu, UInt64(Double(readBytes) / elapsed), UInt64(Double(writeBytes) / elapsed))
    }

    static func processDisplayName(command: String) -> String {
        let components = URL(fileURLWithPath: command).pathComponents
        if let appComponent = components.last(where: { $0.hasSuffix(".app") }) {
            return String(appComponent.dropLast(4))
        }
        let shortName = URL(fileURLWithPath: command).lastPathComponent
        return shortName.isEmpty ? "Background process" : shortName
    }

    static func aggregateMemory(_ readings: [ProcessReading], roots: Set<pid_t>) -> [pid_t: UInt64] {
        let parents = Dictionary(uniqueKeysWithValues: readings.map { ($0.pid, $0.parentPID) })
        var totals = Dictionary(uniqueKeysWithValues: roots.map { ($0, UInt64(0)) })
        for reading in readings {
            if let owner = ownerPID(for: reading.pid, parents: parents, roots: roots) {
                totals[owner, default: 0] += reading.footprintBytes
            }
        }
        return totals
    }

    static func ownerPID(for pid: pid_t, parents: [pid_t: pid_t], roots: Set<pid_t>) -> pid_t? {
        var current = pid
        var visited = Set<pid_t>()
        while current > 1, visited.insert(current).inserted {
            if roots.contains(current) { return current }
            guard let parent = parents[current] else { return nil }
            current = parent
        }
        return nil
    }

    static func processStartTime(for pid: pid_t) -> UInt64? { resourceUsage(for: pid)?.startTime }

    static func readCPUTicks() -> CPUTickSnapshot {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
            &processorCount, &info, &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return CPUTickSnapshot(cores: []) }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let stride = Int(CPU_STATE_MAX)
        let cores = (0..<Int(processorCount)).map { core -> CoreTicks in
            let offset = core * stride
            func tick(_ state: Int32) -> UInt64 {
                UInt64(UInt32(bitPattern: info[offset + Int(state)]))
            }
            return CoreTicks(
                user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE)
            )
        }
        return CPUTickSnapshot(cores: cores)
    }

    static func makeCPUSnapshot(previous: CPUTickSnapshot?, current: CPUTickSnapshot) -> CPUSnapshot {
        let logicalCount = current.cores.count
        let activeCount = min(ProcessInfo.processInfo.activeProcessorCount, logicalCount)
        guard let previous, previous.cores.count == current.cores.count, !current.cores.isEmpty else {
            return CPUSnapshot(
                overallPercent: 0, userPercent: 0, systemPercent: 0, idlePercent: 100,
                perCorePercent: Array(repeating: 0, count: logicalCount),
                logicalCoreCount: logicalCount, activeCoreCount: activeCount
            )
        }

        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0
        var perCore: [Double] = []
        for (old, new) in zip(previous.cores, current.cores) {
            let userDelta = delta(new.user, old.user)
            let systemDelta = delta(new.system, old.system)
            let idleDelta = delta(new.idle, old.idle)
            let niceDelta = delta(new.nice, old.nice)
            user &+= userDelta
            system &+= systemDelta
            idle &+= idleDelta
            nice &+= niceDelta
            let total = userDelta &+ systemDelta &+ idleDelta &+ niceDelta
            perCore.append(total > 0 ? Double(userDelta &+ systemDelta &+ niceDelta) / Double(total) * 100 : 0)
        }
        let total = user &+ system &+ idle &+ nice
        guard total > 0 else {
            return CPUSnapshot(
                overallPercent: 0, userPercent: 0, systemPercent: 0, idlePercent: 100,
                perCorePercent: perCore, logicalCoreCount: logicalCount, activeCoreCount: activeCount
            )
        }
        return CPUSnapshot(
            overallPercent: Double(user &+ system &+ nice) / Double(total) * 100,
            userPercent: Double(user &+ nice) / Double(total) * 100,
            systemPercent: Double(system) / Double(total) * 100,
            idlePercent: Double(idle) / Double(total) * 100,
            perCorePercent: perCore, logicalCoreCount: logicalCount, activeCoreCount: activeCount
        )
    }

    static func readHardwareInfo() -> HardwareInfo {
        var gpuName = "Unknown GPU"
        var gpuCores: Int?
        if let output = run(
            "/usr/sbin/system_profiler",
            arguments: ["SPDisplaysDataType", "-json", "-detailLevel", "mini"]
        ), let data = output.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let displays = root["SPDisplaysDataType"] as? [[String: Any]],
           let gpu = displays.first {
            gpuName = (gpu["sppci_model"] as? String) ?? (gpu["_name"] as? String) ?? gpuName
            if let coreText = gpu["sppci_cores"] as? String { gpuCores = Int(coreText) }
        }
        return HardwareInfo(
            physicalCPUCount: sysctlInt("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount,
            logicalCPUCount: ProcessInfo.processInfo.processorCount,
            gpuName: gpuName,
            gpuCoreCount: gpuCores
        )
    }

    static func readSwapUsage() -> (usedBytes: UInt64, totalBytes: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    static func readPressureLevel() -> MemoryPressure {
        var value: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else {
            return .normal
        }
        if value >= MemoryPressure.critical.rawValue { return .critical }
        if value >= MemoryPressure.elevated.rawValue { return .elevated }
        return .normal
    }

    private static func resourceUsage(for pid: pid_t) -> (
        footprint: UInt64, startTime: UInt64, cpuTimeNanoseconds: UInt64,
        diskReadBytes: UInt64, diskWriteBytes: UInt64
    )? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return (
            usage.ri_phys_footprint, usage.ri_proc_start_abstime,
            absoluteTimeToNanoseconds(usage.ri_user_time &+ usage.ri_system_time),
            usage.ri_diskio_bytesread, usage.ri_diskio_byteswritten
        )
    }

    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func absoluteTimeToNanoseconds(
        _ value: UInt64,
        numerator: UInt64 = UInt64(machTimebase.numer),
        denominator: UInt64 = UInt64(machTimebase.denom)
    ) -> UInt64 {
        guard denominator > 0 else { return 0 }
        let whole = value / denominator
        let remainder = value % denominator
        return whole &* numerator &+ (remainder &* numerator) / denominator
    }

    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : (UInt64(UInt32.max) - previous) &+ current &+ 1
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func run(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Drain stdout while the child is running. Waiting first can deadlock when
            // a busy Mac has enough processes to fill the pipe's buffer.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    if bytes == 0 { return "0 B" }
    return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
}
