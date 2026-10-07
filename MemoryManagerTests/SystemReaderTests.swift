import AppKit
import XCTest
@testable import MemoryManager

final class SystemReaderTests: XCTestCase {
    func testBatteryWattsUseAbsoluteVoltageTimesCurrent() {
        let watts = PowerSnapshot.estimatedWatts(
            voltageMillivolts: 12_000, currentMilliamps: -1_500
        )
        XCTAssertEqual(try XCTUnwrap(watts), 18, accuracy: 0.001)
        XCTAssertNil(PowerSnapshot.estimatedWatts(voltageMillivolts: 0, currentMilliamps: 1_000))
    }

    func testSortSwitchesToTheDashboardMetric() {
        XCTAssertEqual(AppSortMode.memoryDescending.adjusted(for: .cpu), .cpuDescending)
        XCTAssertEqual(AppSortMode.cpuAscending.adjusted(for: .activity), .diskDescending)
        XCTAssertEqual(AppSortMode.diskAscending.adjusted(for: .memory), .memoryDescending)
        XCTAssertEqual(AppSortMode.cpuAscending.adjusted(for: .cpu), .cpuAscending)
        XCTAssertEqual(AppSortMode.nameDescending.adjusted(for: .cpu), .nameDescending)
        XCTAssertEqual(AppSortMode.cpuDescending.adjusted(for: .storage), .cpuDescending)
    }

    func testLivePowerSnapshotIsInternallyConsistent() {
        let power = SystemReader.readPowerSnapshot()
        if let watts = power.watts { XCTAssertGreaterThanOrEqual(watts, 0) }
        if let percent = power.batteryPercent { XCTAssertTrue((0...100).contains(percent)) }
    }

    func testAggregatesChildProcessesToNearestVisibleApp() {
        let readings = [
            reading(pid: 10, parent: 1, bytes: 100),
            reading(pid: 11, parent: 10, bytes: 40),
            reading(pid: 12, parent: 11, bytes: 25),
            reading(pid: 20, parent: 10, bytes: 80),
            reading(pid: 21, parent: 20, bytes: 30)
        ]

        let totals = SystemReader.aggregateMemory(readings, roots: [10, 20])

        XCTAssertEqual(totals[10], 165)
        XCTAssertEqual(totals[20], 110)
    }

    func testOwnerUsesNearestVisibleApp() {
        let parents: [pid_t: pid_t] = [12: 11, 11: 10, 10: 1]

        XCTAssertEqual(SystemReader.ownerPID(for: 12, parents: parents, roots: [10]), 10)
        XCTAssertEqual(SystemReader.ownerPID(for: 12, parents: parents, roots: [10, 11]), 11)
    }

    func testMemoryBreakdownAndPercentages() {
        let snapshot = MemorySnapshot(
            totalBytes: 1_000,
            appBytes: 400,
            wiredBytes: 200,
            compressedBytes: 100,
            cachedBytes: 200,
            swapUsedBytes: 50,
            swapTotalBytes: 100,
            swapIns: 0,
            swapOuts: 0,
            pressure: .elevated
        )

        XCTAssertEqual(snapshot.usedBytes, 700)
        XCTAssertEqual(snapshot.availableBytes, 300)
        XCTAssertEqual(snapshot.usedPercent, 70)
        XCTAssertEqual(snapshot.availablePercent, 30)
        XCTAssertEqual(snapshot.pressure, .elevated)
    }

    func testLiveSystemMetricsAreInternallyConsistent() {
        let snapshot = SystemReader.readSystemMemory()

        XCTAssertGreaterThan(snapshot.totalBytes, 0)
        XCTAssertLessThanOrEqual(snapshot.usedBytes, snapshot.totalBytes)
        XCTAssertGreaterThanOrEqual(snapshot.swapTotalBytes, snapshot.swapUsedBytes)
    }

    func testLiveProcessScanCompletesAndFindsTheCurrentProcess() {
        let currentPID = getpid()
        let readings = SystemReader.readProcessMemory(roots: [currentPID])

        XCTAssertTrue(readings.contains { $0.pid == currentPID })
        XCTAssertGreaterThan(readings.first(where: { $0.pid == currentPID })?.footprintBytes ?? 0, 0)
    }

    func testProcessActivityUsesCumulativeCPUAndStableProcessIdentity() {
        let old = reading(
            pid: 42, parent: 1, bytes: 1,
            cpuTimeNanoseconds: 1_000_000_000,
            diskReadBytes: 100,
            diskWriteBytes: 200,
            startTime: 9
        )
        let current = reading(
            pid: 42, parent: 1, bytes: 1,
            cpuTimeNanoseconds: 2_000_000_000,
            diskReadBytes: 500,
            diskWriteBytes: 800,
            startTime: 9
        )
        let previous = [
            ProcessIdentity(pid: old.pid, startTime: old.startTime): ProcessCumulative(reading: old)
        ]

        let activity = SystemReader.makeProcessActivity(
            readings: [current], previous: previous, elapsed: 2, activeProcessorCount: 10
        )

        XCTAssertEqual(activity.cpuPercent, 50, accuracy: 0.001)
        XCTAssertEqual(activity.readRate, 200)
        XCTAssertEqual(activity.writeRate, 300)
    }

    func testMachAbsoluteCPUTimeIsConvertedToNanoseconds() {
        XCTAssertEqual(
            SystemReader.absoluteTimeToNanoseconds(24, numerator: 125, denominator: 3),
            1_000
        )
        XCTAssertEqual(SystemReader.absoluteTimeToNanoseconds(10, numerator: 1, denominator: 0), 0)
    }

    func testWholeMachineCPUShareMatchesOverallCPUScale() {
        let app = appMemory(cpuPercent: 250)

        XCTAssertEqual(app.wholeMachineCPUPercent(activeProcessorCount: 10), 25, accuracy: 0.001)
        XCTAssertEqual(app.wholeMachineCPUPercent(activeProcessorCount: 0), 0)
    }

    func testProcessScanCanIncludeUnattributedBackgroundProcesses() {
        let currentPID = getpid()
        let readings = SystemReader.readProcessMemory(
            roots: [pid_t.max], includeUnattributed: true
        )

        let current = readings.first { $0.pid == currentPID }
        XCTAssertNotNil(current)
        XCTAssertNil(current?.attributedOwnerPID)
    }

    func testProcessDisplayNameUsesInnermostAppOrExecutable() {
        XCTAssertEqual(
            SystemReader.processDisplayName(
                command: "/Applications/ChatGPT.app/Contents/Helpers/Codex (Service).app/Contents/MacOS/Codex"
            ),
            "Codex (Service)"
        )
        XCTAssertEqual(SystemReader.processDisplayName(command: "/usr/sbin/WindowServer"), "WindowServer")
    }

    func testCPUPercentagesAreCalculatedFromTickDeltas() {
        let previous = CPUTickSnapshot(cores: [
            CoreTicks(user: 100, system: 50, idle: 850, nice: 0),
            CoreTicks(user: 100, system: 50, idle: 850, nice: 0)
        ])
        let current = CPUTickSnapshot(cores: [
            CoreTicks(user: 140, system: 60, idle: 900, nice: 0),
            CoreTicks(user: 110, system: 60, idle: 930, nice: 0)
        ])

        let cpu = SystemReader.makeCPUSnapshot(previous: previous, current: current)

        XCTAssertEqual(cpu.perCorePercent[0], 50, accuracy: 0.001)
        XCTAssertEqual(cpu.perCorePercent[1], 20, accuracy: 0.001)
        XCTAssertEqual(cpu.overallPercent, 35, accuracy: 0.001)
        XCTAssertEqual(cpu.userPercent, 25, accuracy: 0.001)
        XCTAssertEqual(cpu.systemPercent, 10, accuracy: 0.001)
        XCTAssertEqual(cpu.idlePercent, 65, accuracy: 0.001)
    }

    func testLiveCPUSampleMatchesTheMachineCoreCount() {
        let first = SystemReader.readCPUTicks()
        usleep(50_000)
        let second = SystemReader.readCPUTicks()
        let cpu = SystemReader.makeCPUSnapshot(previous: first, current: second)

        XCTAssertEqual(cpu.logicalCoreCount, ProcessInfo.processInfo.processorCount)
        XCTAssertEqual(cpu.perCorePercent.count, cpu.logicalCoreCount)
        XCTAssertTrue(cpu.perCorePercent.allSatisfy { (0...100).contains($0) })
    }

    func testDetachedProcessCanBeAttributedByExecutablePathAndRememberedOwner() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["2"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        usleep(30_000)

        let fakeOwner = pid_t(424_242)
        let pathReadings = SystemReader.readProcessMemory(
            roots: [fakeOwner], ownershipPrefixes: [fakeOwner: [""]]
        )
        let pathReading = try XCTUnwrap(pathReadings.first { $0.pid == process.processIdentifier })
        XCTAssertEqual(pathReading.attributedOwnerPID, fakeOwner)
        XCTAssertTrue(pathReading.isDetachedHelper)

        let remembered = [
            ProcessIdentity(pid: pathReading.pid, startTime: pathReading.startTime): fakeOwner
        ]
        let rememberedReadings = SystemReader.readProcessMemory(
            roots: [fakeOwner], rememberedOwners: remembered
        )
        let rememberedReading = try XCTUnwrap(rememberedReadings.first { $0.pid == process.processIdentifier })
        XCTAssertEqual(rememberedReading.attributedOwnerPID, fakeOwner)
        XCTAssertTrue(rememberedReading.isDetachedHelper)
    }

    func testStorageScannerAggregatesTopLevelItemsWithoutFollowingExcludedFolders() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = root.appendingPathComponent("First", isDirectory: true)
        let excluded = root.appendingPathComponent("Excluded", isDirectory: true)
        try manager.createDirectory(at: first, withIntermediateDirectories: true)
        try manager.createDirectory(at: excluded, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32_768).write(to: first.appendingPathComponent("one.bin"))
        try Data(repeating: 2, count: 16_384).write(to: excluded.appendingPathComponent("two.bin"))
        defer { try? manager.removeItem(at: root) }

        let location = StorageScanLocation(
            name: "Test", url: root, risk: .reviewCarefully,
            excludedTopLevelNames: ["Excluded"]
        )
        let result = StorageScanner.scan(location: location)

        XCTAssertEqual(result.items.map(\.name), ["First"])
        XCTAssertGreaterThan(result.items[0].allocatedBytes, 0)
        XCTAssertTrue(result.items[0].isMeasured)
        XCTAssertTrue(result.items[0].isDirectory)
        XCTAssertFalse(result.wasCancelled)
    }

    func testStorageTrashSafetyOnlyAllowsItemsBelowHomeAndNeverExistingTrash() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let child = home.appendingPathComponent("Downloads/file.zip")
        let trashItem = home.appendingPathComponent(".Trash/old.zip")
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        XCTAssertTrue(StorageScanner.isSafeTrashTarget(child, homeDirectory: home))
        XCTAssertFalse(StorageScanner.isSafeTrashTarget(home, homeDirectory: home))
        XCTAssertFalse(StorageScanner.isSafeTrashTarget(root, homeDirectory: home))
        XCTAssertFalse(StorageScanner.isSafeTrashTarget(trashItem, homeDirectory: home))
    }

    func testStorageTrashSafetyRejectsStandardFoldersAndSensitiveLibraryData() {
        let home = URL(fileURLWithPath: "/tmp/mm-home-\(UUID().uuidString)", isDirectory: true)
        func safe(_ path: String) -> Bool {
            StorageScanner.isSafeTrashTarget(home.appendingPathComponent(path), homeDirectory: home)
        }
        XCTAssertFalse(safe("Documents"))
        XCTAssertFalse(safe("Library"))
        XCTAssertFalse(safe("Library/Keychains"))
        XCTAssertFalse(safe("Library/Keychains/login.keychain-db"))
        XCTAssertFalse(safe("Library/Preferences"))
        XCTAssertFalse(safe("Library/Mobile Documents"))
        XCTAssertFalse(safe(".ssh"))
        XCTAssertTrue(safe("Library/Caches/com.example.app"))
        XCTAssertTrue(safe("Documents/old-project"))
        XCTAssertTrue(safe("Library/PreferencesBackup"))
    }

    func testVolumeStorageSnapshotIsInternallyConsistent() {
        let snapshot = StorageScanner.volumeSnapshot()

        XCTAssertGreaterThan(snapshot.totalBytes, 0)
        XCTAssertLessThanOrEqual(snapshot.freeBytes, snapshot.totalBytes)
        XCTAssertLessThanOrEqual(snapshot.availableForImportantUsageBytes, snapshot.totalBytes)
        XCTAssertLessThanOrEqual(snapshot.usedBytes, snapshot.totalBytes)
    }

    func testSustainedMemoryGrowthDetectorRequiresTimeSizeAndConsistency() throws {
        let start = Date()
        let samples = (0...5).map { minute in
            MemoryTrendSample(
                date: start.addingTimeInterval(Double(minute) * 60),
                bytes: UInt64(200 + minute * 100) * 1_024 * 1_024
            )
        }
        let insight = try XCTUnwrap(MemoryTrendAnalyzer.insight(key: "test", name: "Test App", samples: samples))
        XCTAssertEqual(insight.growthBytes, 500 * 1_024 * 1_024)
        XCTAssertGreaterThan(insight.rateBytesPerMinute, 90 * 1_024 * 1_024)

        XCTAssertNil(MemoryTrendAnalyzer.insight(key: "short", name: "Short", samples: Array(samples.prefix(3))))
    }

    func testDuplicateFinderComparesFileContents() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let duplicate = Data(repeating: 7, count: 1_100_000)
        try duplicate.write(to: root.appendingPathComponent("copy-one.bin"))
        try duplicate.write(to: root.appendingPathComponent("copy-two.bin"))
        try Data(repeating: 8, count: 1_100_000).write(to: root.appendingPathComponent("different.bin"))

        let groups = StorageScanner.findDuplicates(in: root)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].files.count, 2)
        XCTAssertEqual(groups[0].reclaimableBytes, 1_100_000)
    }

    func testSmartStorageInsightsFindOldInstaller() {
        let item = StorageItem(
            name: "Old Installer.dmg", url: URL(fileURLWithPath: "/tmp/Old Installer.dmg"),
            allocatedBytes: 100 * 1_024 * 1_024, fileCount: 1,
            category: "Chosen Folder", risk: .reviewCarefully,
            isDirectory: false, isMeasured: true,
            modificationDate: Date().addingTimeInterval(-45 * 24 * 60 * 60)
        )
        let insights = StorageMonitor.makeSmartInsights(from: [item])
        XCTAssertEqual(insights.first?.kind, .installer)
    }

    func testHistoryPointRoundTripsThroughJSON() throws {
        let point = MemoryHistoryPoint(
            date: Date(), usedPercent: 72, swapBytes: 123,
            pressure: .elevated, cpuPercent: 41,
            diskReadBytesPerSecond: 10, diskWriteBytesPerSecond: 20,
            thermalLevel: .fair, powerWatts: 12.5
        )
        let decoded = try JSONDecoder().decode(
            MemoryHistoryPoint.self, from: JSONEncoder().encode(point)
        )
        XCTAssertEqual(decoded, point)
    }

    private func reading(
        pid: pid_t, parent: pid_t, bytes: UInt64,
        cpuTimeNanoseconds: UInt64 = 0,
        diskReadBytes: UInt64 = 0,
        diskWriteBytes: UInt64 = 0,
        startTime: UInt64? = nil
    ) -> ProcessReading {
        ProcessReading(
            pid: pid,
            parentPID: parent,
            footprintBytes: bytes,
            cpuTimeNanoseconds: cpuTimeNanoseconds,
            diskReadBytes: diskReadBytes,
            diskWriteBytes: diskWriteBytes,
            startTime: startTime ?? UInt64(pid),
            isStopped: false,
            command: "Process \(pid)",
            attributedOwnerPID: nil,
            isDetachedHelper: false
        )
    }

    private func appMemory(cpuPercent: Double) -> AppMemory {
        AppMemory(
            id: 42, name: "Test", bundleIdentifier: "test.app",
            memoryBytes: 0, memoryChangeBytes: 0, cpuPercent: cpuPercent,
            diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0,
            detachedProcessCount: 0, icon: NSImage(), relatedPIDs: [42],
            processStartTimes: [42: 9], isPaused: false, isPausedByManager: false,
            isHelper: false, isFavorite: false, isIgnored: false,
            canControl: true, isSystemProcess: false
        )
    }
}
