import Charts
import SwiftUI

struct TimedValue {
    let date: Date
    let value: Double
}

struct ChartSeries: Identifiable {
    let name: String
    let color: Color
    let points: [TimedValue]

    var id: String { name }

    init(_ name: String, color: Color, points: [TimedValue]) {
        self.name = name
        self.color = color
        self.points = points
    }

    /// Builds a series from dashboard history, skipping samples without a value.
    init(_ name: String, color: Color, history: [MemoryHistoryPoint], value: (MemoryHistoryPoint) -> Double?) {
        self.init(name, color: color, points: history.compactMap { point in
            value(point).map { TimedValue(date: point.date, value: $0) }
        })
    }

    /// The sample closest to `date`; points are in time order.
    func nearest(to date: Date) -> TimedValue? {
        guard !points.isEmpty else { return nil }
        var low = 0
        var high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].date < date { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return points[low] }
        let before = points[low - 1]
        let after = points[low]
        return date.timeIntervalSince(before.date) <= after.date.timeIntervalSince(date) ? before : after
    }
}

/// Line chart for history data that shows the exact time and values under the pointer.
struct HistoryChart: View {
    let series: [ChartSeries]
    var yDomain: ClosedRange<Double>?
    var fixedYTicks: [Double]?
    var showsXAxis = false
    var xAxisFormat: Date.FormatStyle = .dateTime.hour().minute()
    var height: CGFloat = 72
    let accessibilityLabel: String
    let format: (Double) -> String

    @State private var hoverDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            chart
            if series.count > 1 {
                HStack(spacing: 12) {
                    ForEach(series) { item in
                        HStack(spacing: 4) {
                            Circle().fill(item.color).frame(width: 7, height: 7)
                            Text(item.name)
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(series) { item in
                ForEach(item.points, id: \.date) { point in
                    if series.count == 1 {
                        AreaMark(x: .value("Time", point.date), y: .value(item.name, point.value))
                            .foregroundStyle(item.color.opacity(0.12))
                    }
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(item.name, point.value),
                        series: .value("Series", item.name)
                    )
                    .foregroundStyle(item.color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            if let hoverDate, let anchor = series.first?.nearest(to: hoverDate) {
                RuleMark(x: .value("Selected", anchor.date))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(
                        position: .top, spacing: 0,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        readout(at: anchor.date)
                    }
                ForEach(series) { item in
                    if let point = item.nearest(to: hoverDate) {
                        PointMark(x: .value("Time", point.date), y: .value(item.name, point.value))
                            .foregroundStyle(item.color)
                            .symbolSize(40)
                    }
                }
            }
        }
        .chartYScale(domain: resolvedYDomain)
        .chartXAxis {
            if showsXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: xAxisFormat)
                }
            }
        }
        .chartYAxis {
            if let fixedYTicks {
                AxisMarks(position: .trailing, values: fixedYTicks) { value in
                    AxisGridLine()
                    AxisValueLabel { label(for: value) }
                }
            } else {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { label(for: value) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let x = location.x - geometry[plotFrame].origin.x
                            hoverDate = proxy.value(atX: x, as: Date.self)
                        case .ended:
                            hoverDate = nil
                        }
                    }
            }
        }
        .frame(height: height)
        .accessibilityLabel(accessibilityLabel)
    }

    private var resolvedYDomain: ClosedRange<Double> {
        if let yDomain { return yDomain }
        let peak = series.flatMap(\.points).map(\.value).max() ?? 0
        return 0...max(1, peak * 1.15)
    }

    @ViewBuilder
    private func label(for value: AxisValue) -> some View {
        if let number = value.as(Double.self) {
            Text(format(number))
        }
    }

    private func readout(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.weekday(.abbreviated).hour().minute().second())
                .foregroundStyle(.secondary)
            ForEach(series) { item in
                if let point = item.nearest(to: date) {
                    HStack(spacing: 4) {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                        if series.count > 1 { Text(item.name).foregroundStyle(.secondary) }
                        Text(format(point.value)).monospacedDigit().fontWeight(.semibold)
                    }
                }
            }
        }
        .font(.caption2)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
    }
}
