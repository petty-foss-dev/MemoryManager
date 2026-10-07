import SwiftUI

struct InsightsView: View {
    @EnvironmentObject private var monitor: ProcessMonitor
    @EnvironmentObject private var storage: StorageMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                summaryGrid
                memoryGrowthSection
                trendsSection
                if hasBattery { energySection }
                Label(sensorFootnote, systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var hasBattery: Bool { monitor.power.source != .unavailable }

    private var sensorFootnote: String {
        let base = "Sensor availability varies by Mac. Missing readings stay blank instead of being approximated with private APIs."
        return hasBattery ? base : base + " This Mac has no internal battery, so battery and energy readings are hidden."
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Insights").font(.title2.weight(.semibold))
                Text("Patterns and health signals collected over time—not just the current instant.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { monitor.exportDiagnosticReport(storage: storage) } label: {
                Label("Export Diagnostic Snapshot", systemImage: "doc.text")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            insightCard(
                "Memory pressure", monitor.memory.pressure.label,
                "\(Int(monitor.memory.usedPercent.rounded()))% RAM • \(formatBytes(monitor.memory.swapUsedBytes)) swap",
                "memorychip", monitor.memory.pressure.color
            )
            insightCard(
                "Growth detector",
                monitor.memoryGrowthInsights.isEmpty ? "No warning" : "\(monitor.memoryGrowthInsights.count) warning\(monitor.memoryGrowthInsights.count == 1 ? "" : "s")",
                "Learns from the last hour", "chart.line.uptrend.xyaxis",
                monitor.memoryGrowthInsights.isEmpty ? .green : .orange
            )
            if hasBattery {
                insightCard(
                    "Energy this session", String(format: "%.3f Wh", monitor.sessionEnergyWh),
                    monitor.power.watts == nil ? "Battery measurement unavailable" : String(format: "%.1f W average • %.1f W peak", monitor.sessionAverageWatts, monitor.sessionPeakWatts),
                    "bolt.fill", .yellow
                )
            } else {
                insightCard(
                    "Thermal state", monitor.thermalLevel.label,
                    monitor.lowPowerModeEnabled ? "Low Power Mode on" : "Reported by macOS",
                    "thermometer.medium", monitor.thermalLevel.color
                )
            }
            insightCard(
                "Eco Mode", monitor.ecoModeActive ? "Active" : monitor.ecoModeEnabled ? "Ready" : "Off",
                "Effective refresh: \(Int(monitor.effectiveRefreshInterval))s",
                "leaf.fill", monitor.ecoModeActive ? .green : .secondary
            )
        }
    }

    private var memoryGrowthSection: some View {
        insightSection("Sustained memory growth", symbol: "chart.line.uptrend.xyaxis") {
            if monitor.memoryGrowthInsights.isEmpty {
                Label(
                    "No app has shown sustained rapid growth yet. Detection needs at least five minutes of samples.",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            } else {
                ForEach(monitor.memoryGrowthInsights) { insight in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(insight.name).font(.headline)
                            Text("Grew \(formatBytes(insight.growthBytes)) over \(Int(insight.durationMinutes)) minutes")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("+\(formatBytes(UInt64(insight.rateBytesPerMinute)))/min")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
            Text("A warning means consistent growth worth investigating; it does not prove the app has a software leak.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var energySection: some View {
        insightSection("Battery and energy", symbol: "battery.75percent") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 12) {
                valueCell(monitor.power.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "—", "Charge")
                valueCell(monitor.power.capacityHealthPercent.map { "\(Int($0.rounded()))%" } ?? "—", "Capacity health")
                valueCell(monitor.power.cycleCount.map { String($0) } ?? "—", "Cycle count")
                valueCell(monitor.power.healthCondition ?? "—", "Condition")
                valueCell(monitor.power.watts.map { String(format: "%.1f W", $0) } ?? "—", "Current battery flow")
                valueCell(formatSessionDuration(monitor.sessionDuration), "Session duration")
            }
            HStack {
                Text("Energy totals integrate the battery-flow estimate over this monitoring session.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset Energy Session") { monitor.resetEnergySession() }
            }
        }
    }

    private var trendsSection: some View {
        let history = monitor.chartHistory
        return insightSection("Trends", symbol: "clock.arrow.circlepath") {
            HStack {
                Picker("History range", selection: $monitor.historyRange) {
                    ForEach(HistoryRange.allCases) { range in Text(range.label).tag(range) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                Spacer()
                Text("\(monitor.historicalSampleCount) stored and live samples")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if history.count < 2 {
                Text("Collecting samples. Charts appear after the next few refreshes.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
                    trendChart("Memory used", history: history, color: monitor.memory.pressure.color,
                               percentScale: true) { $0.usedPercent }
                    trendChart("Swap used", history: history, color: .purple,
                               percentScale: false) { Double($0.swapBytes) }
                    trendChart("CPU load", history: history, color: cpuLoadColor(monitor.cpu.overallPercent),
                               percentScale: true) { $0.cpuPercent }
                }
            }
            Text("One compact sample per minute is kept for seven days. Current-session detail remains higher resolution.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func trendChart(
        _ title: String, history: [MemoryHistoryPoint], color: Color, percentScale: Bool,
        value: @escaping (MemoryHistoryPoint) -> Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HistoryChart(
                series: [ChartSeries(title, color: color, history: history) { value($0) }],
                yDomain: percentScale ? 0...100 : nil,
                fixedYTicks: percentScale ? [0, 50, 100] : nil,
                showsXAxis: true,
                xAxisFormat: xAxisFormat,
                height: 110,
                accessibilityLabel: "\(title) over the last \(monitor.historyRange.label.lowercased())",
                format: { percentScale ? "\(Int($0.rounded()))%" : formatBytes(UInt64(max(0, $0))) }
            )
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch monitor.historyRange {
        case .hour, .day: return .dateTime.hour().minute()
        case .week: return .dateTime.weekday(.abbreviated)
        }
    }

    private func insightCard(_ title: String, _ value: String, _ subtitle: String, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(value).font(.title3.monospacedDigit().weight(.semibold)).liveValue(value)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
    }

    private func insightSection<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }

    private func valueCell(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private func formatSessionDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
