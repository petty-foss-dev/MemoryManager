import AppKit
import CryptoKit
import Foundation

enum StorageRisk: Int, CaseIterable, Comparable, Sendable {
    case usuallyRemovable
    case reviewCarefully
    case protected

    static func < (lhs: StorageRisk, rhs: StorageRisk) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .usuallyRemovable: return "Usually removable"
        case .reviewCarefully: return "Review carefully"
        case .protected: return "Protected"
        }
    }
}

struct VolumeStorageSnapshot: Equatable, Sendable {
    let totalBytes: UInt64
    let freeBytes: UInt64
    let availableForImportantUsageBytes: UInt64

    static let empty = VolumeStorageSnapshot(totalBytes: 0, freeBytes: 0, availableForImportantUsageBytes: 0)

    var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }
    var reclaimableBytes: UInt64 {
        availableForImportantUsageBytes > freeBytes ? availableForImportantUsageBytes - freeBytes : 0
    }
    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return min(100, Double(usedBytes) / Double(totalBytes) * 100)
    }
}

enum StorageSortOrder: Sendable {
    case sizeDescending
    case sizeAscending
    case nameAscending
    case nameDescending
}

struct StorageItem: Identifiable, Equatable, Sendable {
    var id: String { url.path }
    let name: String
    let url: URL
    let allocatedBytes: UInt64
    let fileCount: Int
    let category: String
    let risk: StorageRisk
    let isDirectory: Bool
    let isMeasured: Bool
    let modificationDate: Date?
}

enum StorageInsightKind: String, Sendable {
    case installer
    case cache
    case olderApplication
    case possibleLeftover
}

struct StorageInsight: Identifiable, Equatable, Sendable {
    var id: String { "\(kind.rawValue):\(item.id)" }
    let kind: StorageInsightKind
    let title: String
    let detail: String
    let item: StorageItem
}

struct DuplicateFileGroup: Identifiable, Equatable, Sendable {
    let id: String
    let fileSize: UInt64
    let files: [URL]
    var reclaimableBytes: UInt64 { fileSize * UInt64(max(0, files.count - 1)) }
}

struct StorageCategorySummary: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let bytes: UInt64
    let itemCount: Int
    let risk: StorageRisk
}

struct StorageScanLocation: Equatable, Sendable {
    let name: String
    let url: URL
    let risk: StorageRisk
    let excludedTopLevelNames: Set<String>

    init(name: String, url: URL, risk: StorageRisk, excludedTopLevelNames: Set<String> = []) {
        self.name = name
        self.url = url
        self.risk = risk
        self.excludedTopLevelNames = excludedTopLevelNames
    }
}

struct StorageLocationResult: Equatable, Sendable {
    let location: StorageScanLocation
    let items: [StorageItem]
    let inaccessibleCount: Int
    let measuredItemCount: Int
    let wasCancelled: Bool

    var totalBytes: UInt64 { items.reduce(0) { $0 &+ $1.allocatedBytes } }
}

enum StorageScanner {
    static func volumeSnapshot(for url: URL = URL(fileURLWithPath: "/")) -> VolumeStorageSnapshot {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) else { return .empty }

        let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
        let free = min(total, UInt64(max(0, values.volumeAvailableCapacity ?? 0)))
        let important = min(total, UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0)))
        return VolumeStorageSnapshot(
            totalBytes: total,
            freeBytes: free,
            availableForImportantUsageBytes: max(free, important)
        )
    }

    static func scan(
        location: StorageScanLocation,
        isCancelled: () -> Bool = { false }
    ) -> StorageLocationResult {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: location.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return StorageLocationResult(
                location: location, items: [], inaccessibleCount: 0,
                measuredItemCount: 0, wasCancelled: false
            )
        }

        let names: [String]
        do {
            names = try manager.contentsOfDirectory(atPath: location.url.path)
        } catch {
            return StorageLocationResult(
                location: location, items: [], inaccessibleCount: 1,
                measuredItemCount: 0, wasCancelled: false
            )
        }

        struct Candidate {
            let name: String
            let url: URL
            let isDirectory: Bool
            let modificationDate: Date?
        }
        let candidates: [Candidate] = names.compactMap { name in
            guard !location.excludedTopLevelNames.contains(name) else { return nil }
            let url = location.url.appendingPathComponent(name)
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            guard attributes?[.type] as? FileAttributeType != .typeSymbolicLink else { return nil }
            return Candidate(
                name: name,
                url: url,
                isDirectory: attributes?[.type] as? FileAttributeType == .typeDirectory,
                modificationDate: attributes?[.modificationDate] as? Date
            )
        }

        guard !candidates.isEmpty else {
            return StorageLocationResult(
                location: location, items: [], inaccessibleCount: 0,
                measuredItemCount: 0, wasCancelled: false
            )
        }

        let process = Process()
        let outputPipe = Pipe()
        let outputLock = NSLock()
        var output = Data()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-k", "-x", "-s"] + candidates.map(\.url.path)
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputLock.lock()
            output.append(data)
            outputLock.unlock()
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            let items = candidates.map {
                StorageItem(
                    name: $0.name, url: $0.url, allocatedBytes: 0,
                    fileCount: $0.isDirectory ? 0 : 1, category: location.name,
                    risk: location.risk, isDirectory: $0.isDirectory, isMeasured: false,
                    modificationDate: $0.modificationDate
                )
            }
            return StorageLocationResult(
                location: location, items: items, inaccessibleCount: items.count,
                measuredItemCount: 0, wasCancelled: false
            )
        }

        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && !isCancelled() && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let cancelled = isCancelled()
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? outputPipe.fileHandleForWriting.close()
        Thread.sleep(forTimeInterval: 0.05)
        outputPipe.fileHandleForReading.readabilityHandler = nil
        outputLock.lock()
        let completedOutput = output
        outputLock.unlock()

        if cancelled {
            return StorageLocationResult(
                location: location, items: [], inaccessibleCount: 0,
                measuredItemCount: 0, wasCancelled: true
            )
        }

        var sizesByPath: [String: UInt64] = [:]
        if let text = String(data: completedOutput, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let pieces = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2, let kibibytes = UInt64(pieces[0].trimmingCharacters(in: .whitespaces)) else { continue }
                sizesByPath[String(pieces[1])] = kibibytes &* 1_024
            }
        }

        let items = candidates.map { candidate in
            let allocated = sizesByPath[candidate.url.path]
            return StorageItem(
                name: candidate.name,
                url: candidate.url,
                allocatedBytes: allocated ?? 0,
                fileCount: candidate.isDirectory ? 0 : 1,
                category: location.name,
                risk: location.risk,
                isDirectory: candidate.isDirectory,
                isMeasured: allocated != nil,
                modificationDate: candidate.modificationDate
            )
        }
        .sorted { lhs, rhs in
            if lhs.allocatedBytes == rhs.allocatedBytes {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.allocatedBytes > rhs.allocatedBytes
        }

        return StorageLocationResult(
            location: location,
            items: items,
            inaccessibleCount: candidates.count - sizesByPath.count,
            measuredItemCount: sizesByPath.count,
            wasCancelled: false
        )
    }

    static func isSafeTrashTarget(
        _ url: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        let home = homeDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard target != home, target.hasPrefix(home + "/") else { return false }
        let relative = String(target.dropFirst(home.count + 1))
        // Never offer whole standard folders (for example after choosing the home folder).
        if protectedHomeFolders.contains(relative) { return false }
        // Nothing inside these is safe to remove wholesale: the Trash itself, credentials,
        // preferences, accounts, and synced or messaging data.
        for folder in protectedHomeSubtrees where relative == folder || relative.hasPrefix(folder + "/") {
            return false
        }
        return true
    }

    static let protectedHomeFolders: Set<String> = [
        "Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music",
        "Pictures", "Public", "Library/Application Support", "Library/Caches",
        "Library/Containers", "Library/Group Containers", "Library/Developer", "Library/Logs"
    ]

    static let protectedHomeSubtrees: [String] = [
        ".Trash", ".ssh", ".gnupg", "Library/Keychains", "Library/Preferences", "Library/Accounts",
        "Library/Mobile Documents", "Library/CloudStorage", "Library/Mail", "Library/Messages",
        "Library/Calendars", "Library/Cookies", "Library/Passes", "Library/Sharing",
        "Library/Application Support/AddressBook", "Library/Application Support/MobileSync",
        "Library/Photos"
    ]

    static func findDuplicates(
        in root: URL,
        minimumSize: UInt64 = 1_048_576,
        isCancelled: () -> Bool = { false }
    ) -> [DuplicateFileGroup] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ]
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var bySize: [UInt64: [URL]] = [:]
        for case let url as URL in enumerator {
            if isCancelled() { return [] }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size >= Int(minimumSize)
            else { continue }
            if values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current { continue }
            bySize[UInt64(size), default: []].append(url)
        }

        var groups: [DuplicateFileGroup] = []
        for (size, urls) in bySize where urls.count > 1 {
            if isCancelled() { return [] }
            var byHash: [String: [URL]] = [:]
            for url in urls {
                if isCancelled() { return [] }
                guard let hash = fileHash(url) else { continue }
                byHash[hash, default: []].append(url)
            }
            for (hash, matches) in byHash where matches.count > 1 {
                groups.append(DuplicateFileGroup(id: hash, fileSize: size, files: matches))
            }
        }
        return groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    private static func fileHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while true {
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }
}

private final class StorageScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

@MainActor
final class StorageMonitor: ObservableObject {
    @Published private(set) var volume = VolumeStorageSnapshot.empty
    @Published private(set) var items: [StorageItem] = []
    @Published private(set) var categories: [StorageCategorySummary] = []
    @Published private(set) var inaccessibleCount = 0
    @Published private(set) var measuredItemCount = 0
    @Published private(set) var isScanning = false
    @Published private(set) var progress = 0.0
    @Published private(set) var currentLocation = ""
    @Published private(set) var lastScanned: Date?
    @Published private(set) var smartInsights: [StorageInsight] = []
    @Published private(set) var duplicateGroups: [DuplicateFileGroup] = []
    @Published private(set) var isFindingDuplicates = false
    @Published private(set) var duplicateStatus: String?
    @Published private(set) var spaceGainedThisSession: UInt64 = 0
    @Published var searchText = ""
    @Published var includeProtectedLocations = true
    @Published var selectedRisk: StorageRisk?
    @Published var sortOrder = StorageSortOrder.sizeDescending
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private var scanCancellation: StorageScanCancellation?
    private var duplicateCancellation: StorageScanCancellation?
    private var customLocations: [StorageScanLocation] = []
    private var initialFreeBytes: UInt64?

    init() {
        refreshVolume()
    }

    var filteredItems: [StorageItem] {
        let matching = items.filter { item in
            let matchesRisk = selectedRisk == nil || item.risk == selectedRisk
            let matchesSearch = searchText.isEmpty
                || item.name.localizedCaseInsensitiveContains(searchText)
                || item.category.localizedCaseInsensitiveContains(searchText)
                || item.url.path.localizedCaseInsensitiveContains(searchText)
            return matchesRisk && matchesSearch
        }
        switch sortOrder {
        case .sizeDescending:
            return matching
        case .sizeAscending:
            return matching.reversed()
        case .nameAscending:
            return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending:
            return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        }
    }

    var scannedBytes: UInt64 { categories.reduce(0) { $0 &+ $1.bytes } }

    func refreshVolume() {
        let snapshot = StorageScanner.volumeSnapshot()
        if let initialFreeBytes, snapshot.freeBytes > initialFreeBytes {
            spaceGainedThisSession = snapshot.freeBytes - initialFreeBytes
        } else if initialFreeBytes == nil {
            initialFreeBytes = snapshot.freeBytes
        }
        volume = snapshot
    }

    func startScan() {
        cancelScan()
        refreshVolume()
        items = []
        categories = []
        inaccessibleCount = 0
        measuredItemCount = 0
        smartInsights = []
        progress = 0
        currentLocation = "Preparing scan…"
        statusMessage = nil
        errorMessage = nil
        isScanning = true

        let locations = Self.standardLocations(includeProtected: includeProtectedLocations) + customLocations
        let cancellation = StorageScanCancellation()
        scanCancellation = cancellation

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var allItems: [StorageItem] = []
            var inaccessible = 0
            var measuredCount = 0

            for (index, location) in locations.enumerated() {
                if cancellation.isCancelled() { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.scanCancellation === cancellation else { return }
                    self.currentLocation = "Scanning \(location.name)…"
                    self.progress = Double(index) / Double(max(1, locations.count))
                }

                let result = StorageScanner.scan(location: location, isCancelled: cancellation.isCancelled)
                if result.wasCancelled || cancellation.isCancelled() { return }
                allItems.append(contentsOf: result.items)
                inaccessible += result.inaccessibleCount
                measuredCount += result.measuredItemCount

                DispatchQueue.main.async { [weak self] in
                    guard let self, self.scanCancellation === cancellation else { return }
                    self.items = allItems.sorted(by: Self.itemSort)
                    self.categories = Self.makeCategories(from: allItems)
                    self.inaccessibleCount = inaccessible
                    self.measuredItemCount = measuredCount
                    self.progress = Double(index + 1) / Double(max(1, locations.count))
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanCancellation === cancellation else { return }
                self.items = allItems.sorted(by: Self.itemSort)
                self.categories = Self.makeCategories(from: allItems)
                self.smartInsights = Self.makeSmartInsights(from: allItems)
                self.inaccessibleCount = inaccessible
                self.measuredItemCount = measuredCount
                self.progress = 1
                self.currentLocation = "Scan complete"
                self.lastScanned = Date()
                self.isScanning = false
                self.scanCancellation = nil
                self.refreshVolume()
            }
        }
    }

    func cancelScan() {
        scanCancellation?.cancel()
        scanCancellation = nil
        if isScanning {
            isScanning = false
            currentLocation = "Scan cancelled"
            statusMessage = "The scan was cancelled. Partial results remain visible."
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder to Measure"
        panel.prompt = "Scan Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let standardized = url.standardizedFileURL
        guard !customLocations.contains(where: { $0.url.standardizedFileURL == standardized }) else {
            statusMessage = "That folder is already included in the scan."
            return
        }
        customLocations.append(StorageScanLocation(
            name: "Chosen Folder: \(standardized.lastPathComponent)",
            url: standardized,
            risk: .reviewCarefully
        ))
        startScan()
    }

    func chooseFolderForDuplicates() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder to Check for Duplicates"
        panel.prompt = "Find Duplicates"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let root = panel.url else { return }

        duplicateCancellation?.cancel()
        let cancellation = StorageScanCancellation()
        duplicateCancellation = cancellation
        duplicateGroups = []
        duplicateStatus = "Checking file sizes and contents in \(root.lastPathComponent)…"
        isFindingDuplicates = true
        let hasAccess = root.startAccessingSecurityScopedResource()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let groups = StorageScanner.findDuplicates(in: root, isCancelled: cancellation.isCancelled)
            if hasAccess { root.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.duplicateCancellation === cancellation else { return }
                self.duplicateGroups = groups
                self.isFindingDuplicates = false
                self.duplicateCancellation = nil
                self.duplicateStatus = groups.isEmpty
                    ? "No duplicate files larger than 1 MB were found."
                    : "Found \(groups.count) duplicate group\(groups.count == 1 ? "" : "s") with \(formatBytes(groups.reduce(0) { $0 &+ $1.reclaimableBytes })) potentially recoverable."
            }
        }
    }

    func cancelDuplicateSearch() {
        duplicateCancellation?.cancel()
        duplicateCancellation = nil
        isFindingDuplicates = false
        duplicateStatus = "Duplicate search cancelled."
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func reveal(_ item: StorageItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func canMoveToTrash(_ item: StorageItem) -> Bool {
        item.risk != .protected
            && StorageScanner.isSafeTrashTarget(item.url)
            && FileManager.default.isDeletableFile(atPath: item.url.path)
    }

    func moveToTrash(_ item: StorageItem) {
        guard canMoveToTrash(item) else {
            errorMessage = "Memory Manager only moves user-owned items inside your home folder to the Trash."
            return
        }
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: item.url, resultingItemURL: &resultingURL)
            items.removeAll { $0.id == item.id }
            categories = Self.makeCategories(from: items)
            statusMessage = "Moved \(item.name) to the Trash. Empty the Trash when you’re ready to reclaim the space."
            refreshVolume()
        } catch {
            errorMessage = "Couldn’t move \(item.name) to the Trash: \(error.localizedDescription)"
        }
    }

    func openTrash() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
    }

    func openStorageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
            NSWorkspace.shared.open(url)
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated static func standardLocations(includeProtected: Bool) -> [StorageScanLocation] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let separatedLibraryFolders: Set<String> = [
            "Application Support", "Caches", "Containers", "Group Containers", "Developer",
            "Logs", "Mail", "Messages", "CloudStorage", "HTTPStorages", "WebKit",
            "Saved Application State"
        ]
        var locations: [StorageScanLocation] = [
            .init(name: "User Applications", url: home.appendingPathComponent("Applications"), risk: .reviewCarefully),
            .init(name: "Application Support & Backups", url: library.appendingPathComponent("Application Support"), risk: .reviewCarefully),
            .init(name: "App Containers", url: library.appendingPathComponent("Containers"), risk: .reviewCarefully),
            .init(name: "Shared App Containers", url: library.appendingPathComponent("Group Containers"), risk: .reviewCarefully),
            .init(name: "Developer Data", url: library.appendingPathComponent("Developer"), risk: .reviewCarefully),
            .init(name: "User Caches", url: library.appendingPathComponent("Caches"), risk: .usuallyRemovable),
            .init(name: "Web Caches", url: library.appendingPathComponent("HTTPStorages"), risk: .usuallyRemovable),
            .init(name: "WebKit Data", url: library.appendingPathComponent("WebKit"), risk: .usuallyRemovable),
            .init(name: "Logs", url: library.appendingPathComponent("Logs"), risk: .usuallyRemovable),
            .init(name: "Saved App State", url: library.appendingPathComponent("Saved Application State"), risk: .usuallyRemovable),
            .init(name: "Trash", url: home.appendingPathComponent(".Trash"), risk: .usuallyRemovable),
            .init(name: "Other User Library Data", url: library, risk: .reviewCarefully, excludedTopLevelNames: separatedLibraryFolders)
        ]

        if includeProtected {
            locations += [
                .init(name: "Installed Applications", url: URL(fileURLWithPath: "/Applications"), risk: .protected),
                .init(name: "Shared Library Data", url: URL(fileURLWithPath: "/Library"), risk: .protected),
                .init(name: "Shared User Data", url: URL(fileURLWithPath: "/Users/Shared"), risk: .protected),
                .init(name: "System Data (/private/var)", url: URL(fileURLWithPath: "/private/var"), risk: .protected)
            ]
        }
        return locations
    }

    nonisolated static func makeCategories(from items: [StorageItem]) -> [StorageCategorySummary] {
        Dictionary(grouping: items, by: \StorageItem.category)
            .map { name, categoryItems in
                StorageCategorySummary(
                    name: name,
                    bytes: categoryItems.reduce(0) { $0 &+ $1.allocatedBytes },
                    itemCount: categoryItems.count,
                    risk: categoryItems.map(\.risk).max() ?? .reviewCarefully
                )
            }
            .sorted { lhs, rhs in
                if lhs.bytes == rhs.bytes { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
                return lhs.bytes > rhs.bytes
            }
    }

    nonisolated static func makeSmartInsights(from items: [StorageItem], now: Date = Date()) -> [StorageInsight] {
        let archiveExtensions: Set<String> = ["dmg", "pkg", "zip", "tar", "gz", "xz", "7z"]
        let appNames = installedApplicationNames()
        return items.compactMap { item in
            let age = item.modificationDate.map { now.timeIntervalSince($0) } ?? 0
            let extensionName = item.url.pathExtension.lowercased()
            if !item.isDirectory, archiveExtensions.contains(extensionName),
               item.allocatedBytes >= 50 * 1_024 * 1_024, age >= 30 * 24 * 60 * 60 {
                return StorageInsight(
                    kind: .installer, title: "Old installer or archive",
                    detail: "Over 30 days old • review before removing", item: item
                )
            }
            if item.category.localizedCaseInsensitiveContains("Cache"),
               item.allocatedBytes >= 500 * 1_024 * 1_024 {
                return StorageInsight(
                    kind: .cache, title: "Large cache",
                    detail: "Usually recreated by its app", item: item
                )
            }
            if item.category == "Installed Applications", age >= 365 * 24 * 60 * 60 {
                return StorageInsight(
                    kind: .olderApplication, title: "Older application",
                    detail: "Has not been modified in over a year; this is not a last-used date", item: item
                )
            }
            if item.category == "Application Support & Backups",
               item.allocatedBytes >= 500 * 1_024 * 1_024,
               !appNames.contains(normalizedAppName(item.name)) {
                return StorageInsight(
                    kind: .possibleLeftover, title: "Possible app leftover",
                    detail: "No similarly named installed app was found; review carefully", item: item
                )
            }
            return nil
        }
        .sorted { $0.item.allocatedBytes > $1.item.allocatedBytes }
    }

    nonisolated private static func installedApplicationNames() -> Set<String> {
        let manager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        return Set(roots.flatMap { root in
            (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        }.filter { $0.pathExtension == "app" }.map { normalizedAppName($0.deletingPathExtension().lastPathComponent) })
    }

    nonisolated private static func normalizedAppName(_ name: String) -> String {
        name.lowercased().filter(\.isLetter)
    }

    nonisolated static func itemSort(_ lhs: StorageItem, _ rhs: StorageItem) -> Bool {
        if lhs.allocatedBytes == rhs.allocatedBytes {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return lhs.allocatedBytes > rhs.allocatedBytes
    }
}
