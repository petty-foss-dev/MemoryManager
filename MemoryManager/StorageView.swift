import SwiftUI

struct StorageView: View {
    @EnvironmentObject private var storage: StorageMonitor
    @State private var pendingTrashItem: StorageItem?
    @State private var showAllInsights = false
    @State private var showAllDuplicates = false
    @AppStorage("storageExplanationExpanded") private var explanationExpanded = true
    var searchFocused: FocusState<Bool>.Binding

    private let insightLimit = 12
    private let duplicateGroupLimit = 8
    private let duplicateFileLimit = 4

    var body: some View {
        let items = storage.filteredItems
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                VStack(spacing: 16) {
                    volumeOverview
                    scanControls
                    if storage.isScanning { scanProgress }
                    if let message = storage.statusMessage { statusBanner(message) }
                    if !storage.categories.isEmpty { categoryStrip }
                    if !storage.smartInsights.isEmpty { smartInsightsSection }
                    if storage.duplicateStatus != nil || !storage.duplicateGroups.isEmpty { duplicateSection }
                    transparencyNote
                }
                .padding(20)

                Section {
                    itemRows(items)
                } header: {
                    VStack(spacing: 0) {
                        Divider()
                        itemControls(count: items.count)
                        Divider()
                        columnHeader
                        Divider()
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .searchable(text: $storage.searchText, placement: .toolbar, prompt: "Search files, categories, or paths")
        .searchFocusedIfAvailable(searchFocused)
        .confirmationDialog(
            "Move \(pendingTrashItem?.name ?? "this item") to the Trash?",
            isPresented: trashConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let item = pendingTrashItem { storage.moveToTrash(item) }
                pendingTrashItem = nil
            }
            Button("Cancel", role: .cancel) { pendingTrashItem = nil }
        } message: {
            if let item = pendingTrashItem {
                Text("This moves \(formatBytes(item.allocatedBytes)) at \(item.url.path) to the Trash. Space is reclaimed only after you empty the Trash.")
            }
        }
        .alert("Storage action couldn’t be completed", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(storage.errorMessage ?? "An unknown error occurred.")
        }
    }

    private var volumeOverview: some View {
        HStack(spacing: 20) {
            RingGauge(
                percent: storage.volume.usedPercent,
                color: storage.volume.usedPercent > 90 ? .red : .blue,
                accessibilityLabel: "Startup disk used",
                caption: "used",
                lineWidth: 10,
                size: 86
            )

            VStack(alignment: .leading, spacing: 5) {
                Text("Storage").font(.title2.weight(.semibold))
                Text("\(formatBytes(storage.volume.usedBytes)) of \(formatBytes(storage.volume.totalBytes)) used")
                    .font(.headline)
                Text("The scan explains where space is going, including normally opaque System Data locations.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
            volumeMetric(formatBytes(storage.volume.freeBytes), "Free now")
            Divider().frame(height: 48)
            volumeMetric(formatBytes(storage.volume.reclaimableBytes), "Purgeable estimate")
            if storage.lastScanned != nil {
                Divider().frame(height: 48)
                volumeMetric(formatBytes(storage.scannedBytes), "Files classified")
            }
            if storage.spaceGainedThisSession > 0 {
                Divider().frame(height: 48)
                volumeMetric(formatBytes(storage.spaceGainedThisSession), "Free space gained")
            }
        }
    }

    private func volumeMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(value).font(.headline.monospacedDigit()).liveValue(value)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var scanControls: some View {
        HStack(spacing: 10) {
            if storage.isScanning {
                Button("Cancel Scan", role: .cancel) { storage.cancelScan() }
            } else {
                Button { storage.startScan() } label: {
                    Label(storage.lastScanned == nil ? "Scan Storage" : "Scan Again", systemImage: "internaldrive")
                }
                .buttonStyle(.borderedProminent)
            }
            Button { storage.chooseFolder() } label: {
                Label("Choose Folder…", systemImage: "folder.badge.plus")
            }
            .disabled(storage.isScanning)
            if storage.isFindingDuplicates {
                Button("Cancel Duplicates", role: .cancel) { storage.cancelDuplicateSearch() }
            } else {
                Button { storage.chooseFolderForDuplicates() } label: {
                    Label("Find Duplicates…", systemImage: "doc.on.doc")
                }
            }
            Toggle("Include protected system locations", isOn: $storage.includeProtectedLocations)
                .toggleStyle(.checkbox)
                .disabled(storage.isScanning)
            Spacer()
            Menu {
                Button("Open macOS Storage Settings") { storage.openStorageSettings() }
                Button("Open Full Disk Access Settings") { storage.openFullDiskAccessSettings() }
                Divider()
                Button("Open Trash") { storage.openTrash() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .fixedSize()
        }
    }

    private var scanProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(storage.currentLocation).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int((storage.progress * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: storage.progress)
                .accessibilityLabel("Scan progress")
            Text("Scanning runs only when requested so it does not continuously use the disk or battery.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).font(.subheadline)
            Spacer()
            Button {
                storage.statusMessage = nil
            } label: {
                Label("Dismiss", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(10)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(storage.categories) { category in
                    Button {
                        storage.searchText = category.name
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: categorySymbol(category))
                                    .foregroundStyle(category.risk.color)
                                Text(category.name).font(.caption.weight(.semibold)).lineLimit(1)
                            }
                            Text(formatBytes(category.bytes)).font(.headline.monospacedDigit()).liveValue(category.bytes)
                            Text("\(category.itemCount) top-level items")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(width: 180, alignment: .leading)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Show \(category.name) items in the list")
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Filters the list to this category")
                }
            }
        }
    }

    private var smartInsightsSection: some View {
        let insights = storage.smartInsights
        let shown = showAllInsights ? insights : Array(insights.prefix(insightLimit))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Smart cleanup review", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if insights.count > insightLimit {
                    Button(showAllInsights ? "Show Fewer" : "Show All \(insights.count)") {
                        showAllInsights.toggle()
                    }
                    .controlSize(.small)
                }
            }
            Text("Suggestions are review-only. Possible leftovers and older apps are never removed automatically.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(shown) { insight in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(insight.title, systemImage: insightSymbol(insight.kind))
                                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                            Text(insight.item.name).font(.headline).lineLimit(1)
                            Text(formatBytes(insight.item.allocatedBytes)).font(.caption.monospacedDigit())
                            Text(insight.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            HStack {
                                Button("Show in List") { storage.searchText = insight.item.name }
                                Button("Reveal") { storage.reveal(insight.item) }
                            }
                            .controlSize(.small)
                        }
                        .padding(10)
                        .frame(width: 225, alignment: .leading)
                        .frame(minHeight: 125, alignment: .topLeading)
                        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private var duplicateSection: some View {
        let groups = storage.duplicateGroups
        let shownGroups = showAllDuplicates ? groups : Array(groups.prefix(duplicateGroupLimit))
        let hasHiddenFiles = groups.contains { $0.files.count > duplicateFileLimit }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Duplicate files", systemImage: "doc.on.doc")
                    .font(.headline)
                if storage.isFindingDuplicates { ProgressView().controlSize(.small) }
                Spacer()
                if groups.count > duplicateGroupLimit || hasHiddenFiles {
                    Button(showAllDuplicates ? "Show Fewer"
                        : groups.count > duplicateGroupLimit ? "Show All \(groups.count) Groups" : "Show All Copies") {
                        showAllDuplicates.toggle()
                    }
                    .controlSize(.small)
                }
                if !storage.isFindingDuplicates {
                    Button("Check Another Folder…") { storage.chooseFolderForDuplicates() }
                        .controlSize(.small)
                }
            }
            if let status = storage.duplicateStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(shownGroups) { group in
                let files = showAllDuplicates ? group.files : Array(group.files.prefix(duplicateFileLimit))
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(group.files.count) identical files • \(formatBytes(group.fileSize)) each • up to \(formatBytes(group.reclaimableBytes)) recoverable")
                        .font(.caption.weight(.semibold))
                    ForEach(files, id: \.path) { url in
                        HStack {
                            Text(url.path).font(.caption2).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Reveal") { storage.reveal(url) }.controlSize(.mini)
                        }
                    }
                    if files.count < group.files.count {
                        Text("+ \(group.files.count - files.count) more copies")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            }
            if !groups.isEmpty {
                Text("Memory Manager compares file contents, not just names. Review each copy in Finder before removing anything.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private func insightSymbol(_ kind: StorageInsightKind) -> String {
        switch kind {
        case .installer: return "shippingbox"
        case .cache: return "bolt.horizontal.circle"
        case .olderApplication: return "app.badge.clock"
        case .possibleLeftover: return "questionmark.folder"
        }
    }

    private var transparencyNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $explanationExpanded) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("App support, containers, caches, logs, developer files, backups, web data, temporary data, shared Library files, and /private/var are shown separately. Protected items can be inspected and revealed in Finder, but Memory Manager will not delete them.")
                    Text("Sizes are estimates. APFS snapshots, purgeable space, shared files, hard links, and inaccessible files can make the classified total differ from the volume’s used total.")
                    Text("Personal folders—including Desktop, Documents, Downloads, Music, Movies, Photos, Mail, Messages, and cloud drives—are not opened automatically. This avoids surprise privacy prompts and cloud downloads; use Choose Folder when you want to inspect one.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                Label("What “System Data” means here", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
            }
            if storage.inaccessibleCount > 0 {
                HStack {
                    Label(
                        "\(storage.inaccessibleCount) folders or files could not be read.",
                        systemImage: "lock.trianglebadge.exclamationmark"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    Button("Review Full Disk Access") { storage.openFullDiskAccessSettings() }
                        .font(.caption)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func itemControls(count: Int) -> some View {
        HStack(spacing: 10) {
            Text(storage.searchText.isEmpty ? "Largest items" : "Results for “\(storage.searchText)”")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if !storage.searchText.isEmpty {
                Button("Clear") { storage.searchText = "" }
                    .controlSize(.small)
            }
            Spacer()
            Picker("Safety", selection: $storage.selectedRisk) {
                Text("All safety levels").tag(Optional<StorageRisk>.none)
                ForEach(StorageRisk.allCases, id: \.rawValue) { risk in
                    Text(risk.label).tag(Optional(risk))
                }
            }
            .frame(width: 190)
            if storage.lastScanned != nil {
                Text("\(count) items • \(storage.measuredItemCount.formatted()) measured")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private var columnHeader: some View {
        HStack {
            Button {
                storage.sortOrder = storage.sortOrder == .nameAscending ? .nameDescending : .nameAscending
            } label: {
                sortHeader(
                    "ITEM / LOCATION",
                    isActive: storage.sortOrder == .nameAscending || storage.sortOrder == .nameDescending,
                    ascending: storage.sortOrder == .nameAscending
                )
            }
            .buttonStyle(.plain)
            .help("Sort by name")
            Spacer()
            Text("SAFETY").frame(width: 145, alignment: .leading)
            Button {
                storage.sortOrder = storage.sortOrder == .sizeDescending ? .sizeAscending : .sizeDescending
            } label: {
                sortHeader(
                    "SIZE",
                    isActive: storage.sortOrder == .sizeDescending || storage.sortOrder == .sizeAscending,
                    ascending: storage.sortOrder == .sizeAscending
                )
            }
            .buttonStyle(.plain)
            .help("Sort by size")
            .frame(width: 110, alignment: .trailing)
            Text("ACTIONS").frame(width: 160, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    private func sortHeader(_ title: String, isActive: Bool, ascending: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: ascending ? "chevron.up" : "chevron.down")
                .opacity(isActive ? 1 : 0)
        }
        .foregroundStyle(isActive ? Color.primary : Color.secondary)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.capitalized)
        .accessibilityValue(isActive ? (ascending ? "Sorted ascending" : "Sorted descending") : "")
    }

    @ViewBuilder
    private func itemRows(_ items: [StorageItem]) -> some View {
        if storage.items.isEmpty && !storage.isScanning {
            ContentUnavailableView(
                storage.lastScanned == nil ? "Ready to Inspect Storage" : "No Storage Items Found",
                systemImage: "internaldrive",
                description: Text(storage.lastScanned == nil
                    ? "Run a scan to see large files and break down System Data."
                    : "The scan didn’t find any items to list.")
            )
            .frame(minHeight: 220)
        } else if items.isEmpty {
            ContentUnavailableView(
                "No Matching Items", systemImage: "magnifyingglass",
                description: Text("Try a different search or safety filter.")
            )
            .frame(minHeight: 220)
        } else {
            ForEach(items) { item in
                itemRow(item)
                Divider().padding(.leading, 53)
            }
        }
    }

    private func itemRow(_ item: StorageItem) -> some View {
        HStack(spacing: 11) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(item.risk.color)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                Text("\(item.category) • \(item.url.path)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 10)
            Text(item.risk.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.risk.color)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(item.risk.color.opacity(0.10), in: Capsule())
                .frame(width: 145, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.isMeasured ? formatBytes(item.allocatedBytes) : "Couldn’t measure")
                    .font(.body.monospacedDigit().weight(.medium))
                    .foregroundStyle(item.isMeasured ? Color.primary : Color.orange)
                Text(item.isDirectory ? "Folder" : "File").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 110, alignment: .trailing)
            .accessibilityElement(children: .combine)
            HStack(spacing: 7) {
                Button("Reveal") { storage.reveal(item) }
                    .accessibilityLabel("Reveal \(item.name) in Finder")
                if storage.canMoveToTrash(item) {
                    Button("Trash", role: .destructive) { pendingTrashItem = item }
                        .accessibilityLabel("Move \(item.name) to the Trash")
                }
            }
            .frame(width: 160, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") { storage.reveal(item) }
            if storage.canMoveToTrash(item) {
                Divider()
                Button("Move to Trash", role: .destructive) { pendingTrashItem = item }
            }
        }
    }

    private func categorySymbol(_ category: StorageCategorySummary) -> String {
        let name = category.name.lowercased()
        if name.contains("cache") { return "bolt.horizontal.circle" }
        if name.contains("developer") { return "hammer" }
        if name.contains("system") || name.contains("library") { return "gearshape.2" }
        if name.contains("trash") { return "trash" }
        if name.contains("application") { return "app.dashed" }
        return "folder"
    }

    private var trashConfirmationPresented: Binding<Bool> {
        Binding(get: { pendingTrashItem != nil }, set: { if !$0 { pendingTrashItem = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { storage.errorMessage != nil }, set: { if !$0 { storage.errorMessage = nil } })
    }
}

private struct StorageViewPreview: View {
    @FocusState private var searchFocused: Bool

    var body: some View {
        StorageView(searchFocused: $searchFocused)
            .environmentObject(StorageMonitor())
            .frame(width: 1100, height: 800)
    }
}

#Preview {
    StorageViewPreview()
}
