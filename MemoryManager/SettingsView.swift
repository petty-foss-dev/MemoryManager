import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var monitor: ProcessMonitor
    @EnvironmentObject private var storage: StorageMonitor
    @AppStorage("showMenuBar") private var showMenuBar = true
    @State private var launchStatus = SMAppService.mainApp.status
    @State private var launchError: String?

    var body: some View {
        TabView {
            Form {
                Section("Monitoring") {
                    Picker("Refresh every", selection: $monitor.refreshInterval) {
                        Text("1 second").tag(1.0)
                        Text("3 seconds").tag(3.0)
                        Text("5 seconds").tag(5.0)
                        Text("10 seconds").tag(10.0)
                        Text("30 seconds").tag(30.0)
                    }
                    Toggle("Reduce refresh rate while in the background", isOn: $monitor.reduceBackgroundPolling)
                    Toggle("Automatic Eco Mode", isOn: $monitor.ecoModeEnabled)
                    Text("Eco Mode slows monitoring to 10 seconds in Low Power Mode or warm conditions, and 30 seconds under serious thermal pressure.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Combine helper processes with their app", isOn: $monitor.combineProcesses)
                    Toggle("Show history charts on dashboards", isOn: $monitor.showHistory)
                }

                Section("Convenience") {
                    Toggle("Show system usage in the menu bar", isOn: $showMenuBar)
                    Picker("Menu-bar readout", selection: $monitor.menuBarMetric) {
                        ForEach(MenuBarMetric.allCases) { metric in Text(metric.label).tag(metric) }
                    }
                    .disabled(!showMenuBar)
                    Toggle("Launch Memory Manager at login", isOn: launchAtLoginBinding)
                    if launchStatus == .requiresApproval {
                        HStack {
                            Text("Approval is required in System Settings.")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Login Items") { openLoginItemsSettings() }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Notifications") {
                    Toggle("Enable memory notifications", isOn: $monitor.alertsEnabled)
                    Toggle("Alert for sustained elevated pressure", isOn: $monitor.pressureAlertsEnabled)
                        .disabled(!monitor.alertsEnabled)
                    Toggle("Alert when swap usage is high", isOn: $monitor.swapAlertsEnabled)
                        .disabled(!monitor.alertsEnabled)
                    Toggle("Alert when CPU usage is sustained", isOn: $monitor.cpuAlertsEnabled)
                        .disabled(!monitor.alertsEnabled)
                    Toggle("Alert for serious thermal pressure", isOn: $monitor.thermalAlertsEnabled)
                        .disabled(!monitor.alertsEnabled)
                    Toggle("Alert for sustained app memory growth", isOn: $monitor.growthAlertsEnabled)
                        .disabled(!monitor.alertsEnabled)
                    Picker("Swap alert threshold", selection: $monitor.swapAlertThresholdBytes) {
                        Text("2 GB").tag(UInt64(2_147_483_648))
                        Text("4 GB").tag(UInt64(4_294_967_296))
                        Text("8 GB").tag(UInt64(8_589_934_592))
                        Text("16 GB").tag(UInt64(17_179_869_184))
                        Text("32 GB").tag(UInt64(34_359_738_368))
                    }
                    .disabled(!monitor.alertsEnabled || !monitor.swapAlertsEnabled)
                    Picker("CPU alert threshold", selection: $monitor.cpuAlertThreshold) {
                        Text("70%").tag(70.0)
                        Text("80%").tag(80.0)
                        Text("90%").tag(90.0)
                        Text("95%").tag(95.0)
                    }
                    .disabled(!monitor.alertsEnabled || !monitor.cpuAlertsEnabled)
                    Text("CPU and memory alerts require two consecutive samples and have a 15-minute cooldown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Alerts", systemImage: "bell") }

            Form {
                Section("Pause Safety") {
                    Text("Memory Manager pauses an app’s full process tree and records exactly which processes it paused. Those processes are resumed when Memory Manager quits or after it recovers from an unexpected exit.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Processes currently paused by Memory Manager")
                        Spacer()
                        Text("\(monitor.managedPauseCount)").monospacedDigit()
                    }
                    Button("Resume Everything Paused by Memory Manager") {
                        monitor.resumeAllManaged()
                    }
                    .disabled(monitor.managedPauseCount == 0)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Safety", systemImage: "checkmark.shield") }

            Form {
                Section("History") {
                    Picker("Default chart range", selection: $monitor.historyRange) {
                        ForEach(HistoryRange.allCases) { range in Text(range.label).tag(range) }
                    }
                    HStack {
                        Text("Stored and live samples")
                        Spacer()
                        Text("\(monitor.historicalSampleCount)").monospacedDigit()
                    }
                    Button("Export History as CSV…") { monitor.exportHistory() }
                        .disabled(monitor.historicalSampleCount == 0)
                    Button("Export Diagnostic Snapshot…") { monitor.exportDiagnosticReport(storage: storage) }
                    Button("Clear Activity History") { monitor.clearHistory() }
                        .disabled(monitor.historicalSampleCount == 0)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 600, height: 520)
        .alert("Couldn’t change Login Item settings", isPresented: launchErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(launchError ?? "Unknown error")
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchStatus == .enabled },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    launchStatus = SMAppService.mainApp.status
                } catch {
                    launchStatus = SMAppService.mainApp.status
                    launchError = error.localizedDescription
                }
            }
        )
    }

    private var launchErrorPresented: Binding<Bool> {
        Binding(get: { launchError != nil }, set: { if !$0 { launchError = nil } })
    }

    private func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
