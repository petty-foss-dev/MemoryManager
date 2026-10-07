import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var monitor: ProcessMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory Manager").font(.headline)
                    Text("\(formatBytes(monitor.memory.usedBytes)) of \(formatBytes(monitor.memory.totalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(monitor.memory.pressure.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(monitor.memory.pressure.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(monitor.memory.pressure.color.opacity(0.12), in: Capsule())
                    .accessibilityLabel("Memory pressure \(monitor.memory.pressure.label)")
            }

            ProgressView(value: min(monitor.memory.usedPercent, 100), total: 100)
                .tint(monitor.memory.pressure.color)
                .accessibilityLabel("Memory used")
                .accessibilityValue("\(Int(monitor.memory.usedPercent.rounded())) percent")

            HStack(spacing: 8) {
                Text("CPU").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ProgressView(value: min(monitor.cpu.overallPercent, 100), total: 100)
                    .tint(cpuLoadColor(monitor.cpu.overallPercent))
                    .accessibilityLabel("CPU load")
                    .accessibilityValue("\(Int(monitor.cpu.overallPercent.rounded())) percent")
                Text("\(Int(monitor.cpu.overallPercent.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .accessibilityHidden(true)
            }

            HStack {
                miniMetric("RAM", "\(Int(monitor.memory.usedPercent.rounded()))%")
                Spacer()
                miniMetric("Compressed", formatBytes(monitor.memory.compressedBytes))
                Spacer()
                miniMetric("Swap", formatBytes(monitor.memory.swapUsedBytes))
            }

            HStack {
                Label("\(monitor.cpu.equivalentCores, specifier: "%.1f") CPU cores", systemImage: "cpu")
                Spacer()
                if let watts = monitor.power.watts {
                    Label("\(watts, specifier: "%.1f") W", systemImage: "bolt.fill")
                        .foregroundStyle(.yellow)
                    Spacer()
                }
                Label(monitor.thermalLevel.label, systemImage: "thermometer.medium")
                    .foregroundStyle(monitor.thermalLevel.color)
                    .accessibilityLabel("Thermal state \(monitor.thermalLevel.label)")
            }
            .font(.caption)

            Divider()

            Text("Largest apps")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if monitor.menuBarApps.isEmpty {
                Text("No apps available").foregroundStyle(.secondary)
            } else {
                ForEach(monitor.menuBarApps) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: app.icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                            .accessibilityHidden(true)
                        Text(app.name).lineLimit(1)
                        Spacer()
                        if app.isPaused {
                            Button("Resume") { monitor.togglePause(app) }
                                .controlSize(.small)
                                .accessibilityLabel("Resume \(app.name)")
                        }
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(formatBytes(app.memoryBytes))
                            Text("CPU \(formatCPU(app.wholeMachineCPUPercent(activeProcessorCount: monitor.cpu.activeCoreCount)))")
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Divider()

            HStack {
                Button("Open Memory Manager") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("o")
                Spacer()
                Button {
                    monitor.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .help("Refresh")
                SettingsLink {
                    Label("Settings", systemImage: "gearshape").labelStyle(.iconOnly)
                }
                .help("Settings")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit Memory Manager", systemImage: "power").labelStyle(.iconOnly)
                }
                .help("Quit Memory Manager")
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func miniMetric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
