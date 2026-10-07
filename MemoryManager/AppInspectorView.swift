import AppKit
import SwiftUI

/// Side panel with details, recent history, and actions for the selected app.
struct AppInspectorView: View {
    @EnvironmentObject private var monitor: ProcessMonitor
    let appID: pid_t?
    let onPause: (AppMemory) -> Void
    let onForceQuit: (AppMemory) -> Void

    var body: some View {
        Group {
            if let app = monitor.apps.first(where: { $0.id == appID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(app)
                        stats(app)
                        history(app)
                        processes(app)
                        location(app)
                        if app.canControl { actions(app) }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView(
                    appID == nil ? "No App Selected" : "App Not Running",
                    systemImage: "sidebar.right",
                    description: Text(appID == nil
                        ? "Select an app in the list to see its details."
                        : "This app quit or is hidden by the current view settings.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ app: AppMemory) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if let bundleID = app.bundleIdentifier {
                    Text(bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    if app.isPaused { badge("Paused", .orange) }
                    if app.isHelper { badge("Helper", .secondary) }
                    if app.isSystemProcess { badge("System", .secondary) }
                    if app.isFavorite { badge("Pinned", .yellow) }
                }
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func stats(_ app: AppMemory) -> some View {
        let share = app.wholeMachineCPUPercent(activeProcessorCount: monitor.cpu.activeCoreCount)
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                stat("Memory", formatBytes(app.memoryBytes))
                stat("CPU", formatCPU(share))
            }
            GridRow {
                stat("Disk read", formatRate(app.diskReadBytesPerSecond))
                stat("Disk write", formatRate(app.diskWriteBytesPerSecond))
            }
            if let growth = monitor.growthInsight(for: app) {
                GridRow {
                    Label(
                        "Grew \(formatBytes(growth.growthBytes)) in \(Int(growth.durationMinutes)) min",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .gridCellColumns(2)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).liveValue(value)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    @ViewBuilder
    private func history(_ app: AppMemory) -> some View {
        let samples = monitor.timeline(for: app)
        section("Last hour") {
            if app.isHelper || app.isSystemProcess {
                Text("History is kept for apps, not individual helper or system processes.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if samples.count < 2 {
                Text("Collecting samples…")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Memory").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HistoryChart(
                    series: [ChartSeries("Memory", color: .blue, points: samples.map {
                        TimedValue(date: $0.date, value: Double($0.bytes))
                    })],
                    height: 70,
                    accessibilityLabel: "\(app.name) memory over the last hour",
                    format: { formatBytes(UInt64(max(0, $0))) }
                )
                Text("CPU").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HistoryChart(
                    series: [ChartSeries("CPU", color: .green, points: samples.map {
                        TimedValue(
                            date: $0.date,
                            value: $0.cpuPercent / Double(max(1, monitor.cpu.activeCoreCount))
                        )
                    })],
                    height: 70,
                    accessibilityLabel: "\(app.name) CPU over the last hour",
                    format: { formatCPU($0) }
                )
            }
        }
    }

    private func processes(_ app: AppMemory) -> some View {
        let pids = app.relatedPIDs.isEmpty ? [app.pid] : app.relatedPIDs
        return section(pids.count == 1 ? "Process" : "\(pids.count) processes") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(pids.prefix(20), id: \.self) { pid in
                    HStack {
                        Text(processName(pid) ?? "Process")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("PID \(pid)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .textSelection(.enabled)
                }
                if pids.count > 20 {
                    Text("+ \(pids.count - 20) more").font(.caption).foregroundStyle(.secondary)
                }
                if app.detachedProcessCount > 0 {
                    Text("Includes \(app.detachedProcessCount) sandboxed or detached helpers.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func location(_ app: AppMemory) -> some View {
        if let url = executableURL(for: app) {
            section("Location") {
                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
            }
        }
    }

    private func actions(_ app: AppMemory) -> some View {
        section("Actions") {
            VStack(alignment: .leading, spacing: 8) {
                if app.preferenceKey != nil {
                    HStack {
                        Button(app.isFavorite ? "Unpin" : "Pin to Top") { monitor.toggleFavorite(app) }
                        Button(app.isIgnored ? "Show in Menu Bar" : "Hide from Menu Bar") { monitor.toggleIgnored(app) }
                    }
                }
                HStack {
                    Button(app.isPaused ? "Resume" : "Pause") {
                        if app.isPaused { monitor.togglePause(app) } else { onPause(app) }
                    }
                    Button("Quit") { monitor.quit(app) }
                    Button("Force Quit…", role: .destructive) { onForceQuit(app) }
                }
            }
            .controlSize(.small)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func executableURL(for app: AppMemory) -> URL? {
        if let bundleURL = NSRunningApplication(processIdentifier: app.pid)?.bundleURL {
            return bundleURL
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(app.pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    private func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}
