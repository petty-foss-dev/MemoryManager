import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var monitor: ProcessMonitor
    @EnvironmentObject private var storage: StorageMonitor
    @State private var pendingForceQuit: AppMemory?
    @State private var pendingPause: AppMemory?
    @State private var showingActivityInfo = false
    @State private var selectedAppID: pid_t?
    @State private var showingInspector = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            switch monitor.dashboardMode {
            case .storage: StorageView(searchFocused: $searchFocused)
            case .insights: InsightsView()
            case .memory, .cpu, .activity: processDashboard
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .principal) { dashboardPicker }
        }
        .onAppear { monitor.searchText = "" }
        .focusedSceneValue(\.focusSearch, focusSearchAction)
        .alert("Couldn’t complete that action", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(monitor.errorMessage ?? "An unknown error occurred.")
        }
        .confirmationDialog(
            "Force quit \(pendingForceQuit?.name ?? "this app")?",
            isPresented: forceQuitIsPresented,
            titleVisibility: .visible
        ) {
            Button("Force Quit", role: .destructive) {
                if let app = pendingForceQuit { monitor.forceQuit(app) }
                pendingForceQuit = nil
            }
            Button("Cancel", role: .cancel) { pendingForceQuit = nil }
        } message: {
            Text("Unsaved changes in this app will be lost.")
        }
        .confirmationDialog(
            "Pause \(pendingPause?.name ?? "this app")?",
            isPresented: pauseIsPresented,
            titleVisibility: .visible
        ) {
            Button("Pause App") {
                if let app = pendingPause { monitor.togglePause(app) }
                pendingPause = nil
            }
            Button("Cancel", role: .cancel) { pendingPause = nil }
        } message: {
            Text("The app and its helper processes will stop responding until resumed.")
        }
    }

    /// Insights has no search field, and focusing the toolbar search needs macOS 15.
    private var focusSearchAction: (() -> Void)? {
        guard monitor.dashboardMode != .insights else { return nil }
        guard #available(macOS 15.0, *) else { return nil }
        return { searchFocused = true }
    }

    private var dashboardPicker: some View {
        Picker("Dashboard", selection: $monitor.dashboardMode) {
            ForEach(DashboardMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Switch dashboards (⌘1–⌘5)")
    }

    /// Memory, CPU, and Activity share the overview-plus-app-list layout.
    private var processDashboard: some View {
        VStack(spacing: 0) {
            switch monitor.dashboardMode {
            case .cpu: cpuOverview
            case .activity: activityOverview
            default: systemOverview
            }
            Divider()
            appList
        }
        .searchable(text: $monitor.searchText, placement: .toolbar, prompt: "Search apps or PID")
        .searchFocusedIfAvailable($searchFocused)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                viewMenu
                Button {
                    monitor.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh now (⌘R)")
                inspectorToggle
            }
        }
        .inspector(isPresented: $showingInspector) {
            AppInspectorView(
                appID: selectedAppID,
                onPause: { pendingPause = $0 },
                onForceQuit: { pendingForceQuit = $0 }
            )
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
    }

    private var inspectorToggle: some View {
        Button {
            showingInspector.toggle()
        } label: {
            Label(showingInspector ? "Hide Info" : "Show Info", systemImage: "sidebar.right")
        }
        .keyboardShortcut("i", modifiers: .command)
        .help(showingInspector ? "Hide app details (⌘I)" : "Show details for the selected app (⌘I)")
    }

    private var viewMenu: some View {
        Menu {
            Picker("Sort", selection: $monitor.sortMode) {
                ForEach(sortOptions) { mode in Text(mode.label).tag(mode) }
            }
            Divider()
            Toggle("Combine helper processes", isOn: $monitor.combineProcesses)
            Toggle("Show history charts", isOn: $monitor.showHistory)
            Toggle("Live updates", isOn: $monitor.autoRefresh)
        } label: {
            Label("View Options", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Sort and display options")
    }

    private var systemOverview: some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                RingGauge(
                    percent: monitor.memory.usedPercent,
                    color: monitor.memory.pressure.color,
                    accessibilityLabel: "Memory used"
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory")
                        .font(.title2.weight(.semibold))
                    Text("\(formatBytes(monitor.memory.usedBytes)) of \(formatBytes(monitor.memory.totalBytes)) used")
                        .font(.headline)
                        .liveValue(monitor.memory.usedBytes)
                    Text("\(formatBytes(monitor.memory.availableBytes)) readily available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .liveValue(monitor.memory.availableBytes)
                }

                Spacer()

                metric(value: formatBytes(monitor.memory.swapUsedBytes), label: "Swap used")
                Divider().frame(height: 44)
                VStack(alignment: .trailing, spacing: 5) {
                    Label(monitor.memory.pressure.label, systemImage: "circle.fill")
                        .font(.headline)
                        .foregroundStyle(monitor.memory.pressure.color)
                    Text("System pressure")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("System memory pressure")
                .accessibilityValue(monitor.memory.pressure.label)
            }

            MemoryBreakdownBar(snapshot: monitor.memory)

            if monitor.showHistory {
                historyChart(monitor.chartHistory)
            }
        }
        .padding(20)
        .padding(.top, -4)
    }

    private var cpuOverview: some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                RingGauge(
                    percent: monitor.cpu.overallPercent,
                    color: cpuLoadColor(monitor.cpu.overallPercent),
                    accessibilityLabel: "CPU load"
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("CPU").font(.title2.weight(.semibold))
                    Text("\(monitor.cpu.equivalentCores, specifier: "%.1f") equivalent cores in use")
                        .font(.headline)
                        .liveValue(monitor.cpu.equivalentCores)
                    Text("Rows below use the same whole-machine percentage scale")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                metric(value: "\(Int(monitor.cpu.userPercent.rounded()))%", label: "User")
                metric(value: "\(Int(monitor.cpu.systemPercent.rounded()))%", label: "System")
                Divider().frame(height: 44)
                VStack(alignment: .trailing, spacing: 5) {
                    Label(monitor.thermalLevel.label, systemImage: "thermometer.medium")
                        .font(.headline)
                        .foregroundStyle(monitor.thermalLevel.color)
                    Text(monitor.lowPowerModeEnabled ? "Low Power Mode" : "Thermal state")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(monitor.lowPowerModeEnabled ? "Thermal state, Low Power Mode on" : "Thermal state")
                .accessibilityValue(monitor.thermalLevel.label)
            }

            if monitor.showHistory {
                cpuHistoryChart(monitor.chartHistory)
            }
            perCoreGrid
        }
        .padding(20)
        .padding(.top, -4)
    }

    private var activityOverview: some View {
        let history = monitor.showHistory ? monitor.chartHistory : []
        let hasPowerHistory = history.contains { $0.powerWatts != nil }
        return VStack(spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                if monitor.power.source != .unavailable {
                    activityCard(
                        title: powerTitle, value: powerValue,
                        subtitle: powerSubtitle, symbol: "bolt.fill", color: .yellow
                    )
                    .help(powerExplanation)
                }
                activityCard(
                    title: "Disk read", value: formatRate(monitor.diskReadBytesPerSecond),
                    subtitle: "All readable processes", symbol: "arrow.down.to.line", color: .blue
                )
                activityCard(
                    title: "Disk write", value: formatRate(monitor.diskWriteBytesPerSecond),
                    subtitle: "All readable processes", symbol: "arrow.up.to.line", color: .orange
                )
                activityCard(
                    title: monitor.hardware.gpuName,
                    value: monitor.hardware.gpuCoreCount.map { "\($0) GPU cores" } ?? "GPU",
                    subtitle: "Live load not public", symbol: "display", color: .purple,
                    showsInfo: true
                )
                activityCard(
                    title: "CPU hardware",
                    value: "\(monitor.hardware.logicalCPUCount) logical cores",
                    subtitle: "\(monitor.hardware.physicalCPUCount) physical cores", symbol: "cpu", color: .green
                )
            }
            if monitor.showHistory {
                HStack {
                    Text("History").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    historyRangePicker
                }
                if hasPowerHistory {
                    HStack(alignment: .top, spacing: 18) {
                        diskHistoryChart(history).frame(maxWidth: .infinity)
                        powerHistoryChart(history).frame(maxWidth: .infinity)
                    }
                } else {
                    diskHistoryChart(history)
                }
            }
        }
        .padding(20)
        .padding(.top, -4)
    }

    private func activityCard(
        title: String, value: String, subtitle: String, symbol: String, color: Color,
        showsInfo: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                if showsInfo {
                    Spacer(minLength: 0)
                    activityInfoButton
                }
            }
            Text(value).font(.headline.monospacedDigit()).lineLimit(1).liveValue(value)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: showsInfo ? .contain : .combine)
    }

    private var activityInfoButton: some View {
        Button {
            showingActivityInfo.toggle()
        } label: {
            Label("About power and GPU readings", systemImage: "info.circle")
                .labelStyle(.iconOnly)
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .help("About power and GPU readings")
        .popover(isPresented: $showingActivityInfo, arrowEdge: .bottom) {
            Text(powerExplanation)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320)
                .padding(14)
        }
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(value).font(.headline.monospacedDigit()).liveValue(value)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private func historyChart(_ history: [MemoryHistoryPoint]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Memory history", systemImage: "chart.xyaxis.line")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                historyRangePicker
            }
            HistoryChart(
                series: [ChartSeries("Memory used", color: monitor.memory.pressure.color, history: history) { $0.usedPercent }],
                yDomain: 0...100, fixedYTicks: [0, 50, 100],
                accessibilityLabel: "Memory used over the last \(monitor.historyRange.label.lowercased())",
                format: { "\(Int($0.rounded()))%" }
            )
        }
    }

    private func cpuHistoryChart(_ history: [MemoryHistoryPoint]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("CPU history", systemImage: "chart.xyaxis.line")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                historyRangePicker
            }
            HistoryChart(
                series: [ChartSeries("CPU", color: cpuLoadColor(monitor.cpu.overallPercent), history: history) { $0.cpuPercent }],
                yDomain: 0...100, fixedYTicks: [0, 50, 100], height: 66,
                accessibilityLabel: "CPU load over the last \(monitor.historyRange.label.lowercased())",
                format: { "\(Int($0.rounded()))%" }
            )
        }
    }

    private var perCoreGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Logical cores").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("One bar per schedulable CPU core")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 6) {
                ForEach(Array(monitor.cpu.perCorePercent.enumerated()), id: \.offset) { index, percent in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("C\(index + 1)").font(.caption2.weight(.semibold))
                            Spacer()
                            Text("\(Int(percent.rounded()))%").font(.caption2.monospacedDigit())
                        }
                        ProgressView(value: min(percent, 100), total: 100)
                            .tint(cpuLoadColor(percent))
                            .animation(.easeOut(duration: 0.3), value: percent)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Core \(index + 1)")
                    .accessibilityValue("\(Int(percent.rounded())) percent")
                }
            }
        }
    }

    private func diskHistoryChart(_ history: [MemoryHistoryPoint]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Disk activity", systemImage: "chart.xyaxis.line")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HistoryChart(
                series: [
                    ChartSeries("Read", color: .blue, history: history) { Double($0.diskReadBytesPerSecond) },
                    ChartSeries("Write", color: .orange, history: history) { Double($0.diskWriteBytesPerSecond) }
                ],
                accessibilityLabel: "Disk read and write rates over the last \(monitor.historyRange.label.lowercased())",
                format: { formatRate(UInt64(max(0, $0))) }
            )
        }
    }

    private func powerHistoryChart(_ history: [MemoryHistoryPoint]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Battery power", systemImage: "bolt.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HistoryChart(
                series: [ChartSeries("Battery", color: .yellow, history: history) { $0.powerWatts }],
                accessibilityLabel: "Battery power over the last \(monitor.historyRange.label.lowercased())",
                format: { String(format: "%.1f W", $0) }
            )
        }
    }

    private var powerTitle: String {
        if monitor.power.isCharging { return "Battery charging" }
        if monitor.power.source == .battery { return "Battery draw" }
        return "Battery power"
    }

    private var powerValue: String {
        monitor.power.watts.map { String(format: "%.1f W", $0) } ?? "Unavailable"
    }

    private var powerSubtitle: String {
        var parts: [String] = []
        if let percent = monitor.power.batteryPercent {
            parts.append("\(Int(percent.rounded()))%")
        }
        if let minutes = monitor.power.minutesRemaining, minutes > 0 {
            parts.append(formatDuration(minutes: minutes))
        }
        if monitor.power.source == .acPower, !monitor.power.isCharging {
            parts.append("On power adapter")
        }
        return parts.isEmpty ? "Live battery flow estimate" : parts.joined(separator: " • ")
    }

    private var powerExplanation: String {
        let gpu = "GPU core count is hardware information; macOS does not publicly expose reliable live GPU utilization."
        switch monitor.power.source {
        case .battery:
            return "Battery power is estimated from macOS-reported voltage × current.\n\n\(gpu)"
        case .acPower:
            let adapter = monitor.power.adapterRatedWatts.map { " The \($0) W adapter figure is its rated capacity, not current wall draw." } ?? ""
            return "While plugged in, watts show battery charge flow—not the Mac’s total wall power.\(adapter)\n\n\(gpu)"
        case .unavailable:
            return "This Mac has no internal battery, so power readings are hidden. Public macOS data can’t measure whole-system watts without privileged or private access.\n\n\(gpu)"
        }
    }

    /// Name sorts plus the sorts for the metric this dashboard shows.
    private var sortOptions: [AppSortMode] {
        let metric: [AppSortMode]
        switch monitor.dashboardMode {
        case .memory: metric = [.memoryDescending, .memoryAscending]
        case .cpu: metric = [.cpuDescending, .cpuAscending]
        case .activity: metric = [.diskDescending, .diskAscending]
        case .storage, .insights: metric = []
        }
        return metric + [.nameAscending, .nameDescending]
    }

    private var appList: some View {
        let apps = monitor.filteredApps
        return VStack(spacing: 0) {
            HStack {
                Button {
                    monitor.sortMode = monitor.sortMode == .nameAscending ? .nameDescending : .nameAscending
                } label: {
                    sortHeader(
                        monitor.dashboardMode == .cpu ? "PROCESS" : "APP",
                        isActive: monitor.sortMode.isNameSort,
                        ascending: monitor.sortMode == .nameAscending
                    )
                }
                .buttonStyle(.plain)
                .help("Sort by name")
                Spacer()
                Button {
                    togglePrimarySort()
                } label: {
                    sortHeader(
                        metricHeaderTitle,
                        isActive: !monitor.sortMode.isNameSort,
                        ascending: [.memoryAscending, .cpuAscending, .diskAscending].contains(monitor.sortMode)
                    )
                }
                .buttonStyle(.plain)
                .help("Sort by \(metricHeaderTitle.lowercased())")
                .frame(width: 190, alignment: .trailing)
                Text("ACTIONS").frame(width: 205, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)

            Divider()

            if apps.isEmpty {
                ContentUnavailableView(
                    monitor.searchText.isEmpty ? "No Apps to Show" : "No Matching Apps",
                    systemImage: "app.dashed",
                    description: Text(monitor.searchText.isEmpty
                        ? "Apps appear here after the next refresh."
                        : "Try a different name or PID.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(apps) { app in
                            appRow(app)
                            Divider().padding(.leading, 90)
                        }
                    }
                }
            }
        }
    }

    /// Column title with a sort chevron that only appears on the active column.
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

    private func appRow(_ app: AppMemory) -> some View {
        HStack(spacing: 11) {
            Group {
                if app.preferenceKey != nil {
                    Button {
                        monitor.toggleFavorite(app)
                    } label: {
                        Label(
                            app.isFavorite ? "Unpin \(app.name)" : "Pin \(app.name)",
                            systemImage: app.isFavorite ? "star.fill" : "star"
                        )
                        .labelStyle(.iconOnly)
                        .foregroundStyle(app.isFavorite ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(app.isFavorite ? "Unpin app" : "Pin app to the top")
                } else {
                    Color.clear
                }
            }
            .frame(width: 18, height: 18)

            Image(nsImage: app.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                    if app.isPaused {
                        Text("PAUSED")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.12), in: Capsule())
                            .help(app.isPausedByManager
                                ? "Paused by Memory Manager. It resumes automatically when Memory Manager quits."
                                : "Paused by another app or process.")
                    }
                    if app.isIgnored {
                        Text("HIDDEN FROM MENU")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    if app.isSystemProcess {
                        Text(app.relatedPIDs.isEmpty ? "kernel and unreadable processes" : "system/background • PID \(app.pid)")
                    } else {
                        Text("PID \(app.pid)")
                    }
                    if !app.isSystemProcess && app.relatedPIDs.count > 1 {
                        Text("• \(app.relatedPIDs.count) processes")
                    } else if !app.isSystemProcess && app.isHelper {
                        Text("• helper")
                    }
                    if app.detachedProcessCount > 0 {
                        Text("• \(app.detachedProcessCount) sandbox/detached")
                            .foregroundStyle(.blue)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 12)

            appMetric(app)
                .frame(width: 190, alignment: .trailing)

            Group {
                if app.canControl {
                    HStack(spacing: 8) {
                        Button(app.isPaused ? "Resume" : "Pause") {
                            if app.isPaused { monitor.togglePause(app) } else { pendingPause = app }
                        }
                        .accessibilityLabel(app.isPaused ? "Resume \(app.name)" : "Pause \(app.name)")

                        Menu("Quit") {
                            Button("Quit Normally") { monitor.quit(app) }
                            Divider()
                            Button("Force Quit", role: .destructive) { pendingForceQuit = app }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Quit \(app.name)")
                    }
                } else {
                    Text("Managed by macOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 205, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(selectedAppID == app.id ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedAppID = app.id }
        .accessibilityAddTraits(selectedAppID == app.id ? .isSelected : [])
        .contextMenu {
            Button("Show Info") {
                selectedAppID = app.id
                showingInspector = true
            }
            Divider()
            if app.canControl {
                if app.preferenceKey != nil {
                    Button(app.isFavorite ? "Unpin App" : "Pin App") { monitor.toggleFavorite(app) }
                    Button(app.isIgnored ? "Show in Menu Bar" : "Hide from Menu Bar") { monitor.toggleIgnored(app) }
                    Divider()
                }
                Button(app.isPaused ? "Resume" : "Pause") {
                    if app.isPaused { monitor.togglePause(app) } else { pendingPause = app }
                }
                Button("Quit Normally") { monitor.quit(app) }
                Button("Force Quit", role: .destructive) { pendingForceQuit = app }
            } else {
                Text("This process is managed by macOS.")
            }
        }
    }

    @ViewBuilder
    private func appMetric(_ app: AppMemory) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            switch monitor.dashboardMode {
            case .memory:
                Text(formatBytes(app.memoryBytes))
                    .font(.system(.body, design: .monospaced).weight(.medium))
                if let growth = monitor.growthInsight(for: app) {
                    Label(
                        "+\(formatBytes(UInt64(growth.rateBytesPerMinute)))/min",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
                } else if abs(app.memoryChangeBytes) >= 25 * 1_024 * 1_024 {
                    Text(formatMemoryChange(app.memoryChangeBytes))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(app.memoryChangeBytes > 0 ? .orange : .green)
                }
            case .cpu:
                let share = app.wholeMachineCPUPercent(activeProcessorCount: monitor.cpu.activeCoreCount)
                let isIdle = share < 0.05
                Text(formatCPU(share))
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .foregroundStyle(isIdle ? .tertiary : .primary)
                Text(formatCoreUsage(app.cpuPercent))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isIdle ? .tertiary : .secondary)
            case .activity:
                if app.diskReadBytesPerSecond == 0 && app.diskWriteBytesPerSecond == 0 {
                    Text("Idle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("R \(formatRate(app.diskReadBytesPerSecond))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(app.diskReadBytesPerSecond == 0 ? .tertiary : .primary)
                    Text("W \(formatRate(app.diskWriteBytesPerSecond))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(app.diskWriteBytesPerSecond == 0 ? .tertiary : .secondary)
                }
            case .storage:
                EmptyView()
            case .insights:
                EmptyView()
            }
        }
        .help(metricHelp)
        .accessibilityElement(children: .combine)
    }

    private var metricHeaderTitle: String {
        switch monitor.dashboardMode {
        case .memory: return "FOOTPRINT"
        case .cpu: return "CPU SHARE / CORES"
        case .activity: return "DISK I/O"
        case .storage: return "SIZE"
        case .insights: return "INSIGHT"
        }
    }

    private var metricHelp: String {
        switch monitor.dashboardMode {
        case .memory: return "Physical footprint; change is since the previous sample"
        case .cpu: return "Percent of the whole Mac first; equivalent logical cores second"
        case .activity: return "Read and write rates since the previous sample"
        case .storage: return "Allocated storage size"
        case .insights: return "Longer-term resource insight"
        }
    }

    private func togglePrimarySort() {
        switch monitor.dashboardMode {
        case .memory:
            monitor.sortMode = monitor.sortMode == .memoryDescending ? .memoryAscending : .memoryDescending
        case .cpu:
            monitor.sortMode = monitor.sortMode == .cpuDescending ? .cpuAscending : .cpuDescending
        case .activity:
            monitor.sortMode = monitor.sortMode == .diskDescending ? .diskAscending : .diskDescending
        case .storage:
            break
        case .insights:
            break
        }
    }

    private var historyRangePicker: some View {
        Picker("History range", selection: $monitor.historyRange) {
            ForEach(HistoryRange.allCases) { range in Text(range.label).tag(range) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 225)
        .controlSize(.small)
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { monitor.errorMessage != nil }, set: { if !$0 { monitor.errorMessage = nil } })
    }
    private var forceQuitIsPresented: Binding<Bool> {
        Binding(get: { pendingForceQuit != nil }, set: { if !$0 { pendingForceQuit = nil } })
    }
    private var pauseIsPresented: Binding<Bool> {
        Binding(get: { pendingPause != nil }, set: { if !$0 { pendingPause = nil } })
    }
}

private struct MemoryBreakdownBar: View {
    let snapshot: MemorySnapshot

    var body: some View {
        VStack(spacing: 7) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    segment(snapshot.appBytes, color: .blue, width: geometry.size.width)
                    segment(snapshot.wiredBytes, color: .cyan, width: geometry.size.width)
                    segment(snapshot.compressedBytes, color: .orange, width: geometry.size.width)
                    segment(snapshot.cachedBytes, color: .green.opacity(0.7), width: geometry.size.width)
                    Spacer(minLength: 0)
                }
                .background(Color.secondary.opacity(0.1))
                .clipShape(Capsule())
                .animation(.easeOut(duration: 0.45), value: snapshot)
            }
            .frame(height: 9)
            .accessibilityHidden(true)

            HStack(spacing: 16) {
                legend("App", snapshot.appBytes, .blue)
                legend("Wired", snapshot.wiredBytes, .cyan)
                legend("Compressed", snapshot.compressedBytes, .orange)
                legend("Cached", snapshot.cachedBytes, .green)
                Spacer()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memory breakdown")
    }

    private func segment(_ bytes: UInt64, color: Color, width: Double) -> some View {
        color.frame(width: snapshot.totalBytes > 0 ? width * Double(bytes) / Double(snapshot.totalBytes) : 0)
    }

    private func legend(_ name: String, _ bytes: UInt64, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(name) \(formatBytes(bytes))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private func formatMemoryChange(_ bytes: Int64) -> String {
    let prefix = bytes > 0 ? "+" : "−"
    let magnitude = UInt64(bytes.magnitude)
    return prefix + formatBytes(magnitude)
}

private func formatCoreUsage(_ cpuPercent: Double) -> String {
    let cores = cpuPercent / 100
    if cores == 0 { return "0 cores" }
    if cores < 0.01 { return String(format: "%.3f cores", cores) }
    if cores < 1 { return String(format: "%.2f cores", cores) }
    return String(format: "%.1f cores", cores)
}

#Preview {
    ContentView()
        .environmentObject(ProcessMonitor())
        .environmentObject(StorageMonitor())
        .frame(width: 920, height: 820)
}
