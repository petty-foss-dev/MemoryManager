import SwiftUI

extension MemoryPressure {
    var color: Color {
        switch self {
        case .normal: return .green
        case .elevated: return .orange
        case .critical: return .red
        }
    }
}

extension ThermalLevel {
    var color: Color {
        switch self {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        }
    }
}

extension StorageRisk {
    var color: Color {
        switch self {
        case .usuallyRemovable: return .green
        case .reviewCarefully: return .orange
        case .protected: return .red
        }
    }
}

func cpuLoadColor(_ percent: Double) -> Color {
    if percent >= 85 { return .red }
    if percent >= 60 { return .orange }
    return .green
}

/// Circular percentage gauge used at the top of each dashboard.
struct RingGauge: View {
    let percent: Double
    let color: Color
    let accessibilityLabel: String
    var caption: String?
    var lineWidth: CGFloat = 9
    var size: CGFloat = 74
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, percent / 100)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(percent.rounded()))%")
                    .font(.system(.headline, design: .rounded).weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText(value: percent))
                if let caption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: percent)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(Int(percent.rounded())) percent")
    }
}

func formatRate(_ bytesPerSecond: UInt64) -> String {
    "\(formatBytes(bytesPerSecond))/s"
}

/// Formats a whole-machine CPU percentage, keeping a decimal for small values.
func formatCPU(_ percent: Double) -> String {
    percent < 10 ? String(format: "%.1f%%", percent) : String(format: "%.0f%%", percent)
}

func formatDuration(minutes: Int) -> String {
    let hours = minutes / 60
    let remainder = minutes % 60
    return hours > 0 ? "\(hours)h \(remainder)m" : "\(remainder)m"
}

/// Lets the app's Find command focus whichever dashboard search field is on screen.
struct SearchFocusActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var focusSearch: (() -> Void)? {
        get { self[SearchFocusActionKey.self] }
        set { self[SearchFocusActionKey.self] = newValue }
    }
}

extension View {
    /// Animates a changing readout like a counter, unless Reduce Motion is on.
    func liveValue<Value: Equatable>(_ value: Value) -> some View {
        modifier(LiveValueModifier(value: value))
    }

    /// Ties a toolbar search field to a focus binding where the OS supports it (macOS 15+).
    @ViewBuilder
    func searchFocusedIfAvailable(_ binding: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15.0, *) {
            searchFocused(binding)
        } else {
            self
        }
    }
}

private struct LiveValueModifier<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : .snappy, value: value)
    }
}
