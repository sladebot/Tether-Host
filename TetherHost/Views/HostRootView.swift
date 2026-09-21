import SwiftUI

struct HostRootView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        NavigationSplitView {
            List(HostDestination.allCases, selection: $model.selection) { destination in
                Label(destination.title, systemImage: destination.symbol)
                    .tag(destination)
            }
            .navigationTitle("Tether Host for Mac")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            Group {
                switch model.selection ?? .overview {
                case .overview:
                    HostDashboardView()
                case .setup:
                    SetupAssistantView()
                case .virtualMachines:
                    VMInventoryView()
                case .diagnostics:
                    DiagnosticsView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshing)
                    .help(model.isRefreshing ? "A status read is already in progress." : "Collect fresh host evidence.")
                }
            }
        }
        .task { await model.refresh() }
        .tint(.accentColor)
    }
}

struct HostSettingsView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Form {
            Section("Status collection") {
                LabeledContent("Mode", value: "Guided setup; read-only VM inventory")
                Text("Guest installation runs only inside a macOS VM after you start it. Verified connection credentials are stored in Keychain. VM lifecycle and host isolation controls remain unavailable.")
                    .foregroundStyle(.secondary)
            }
            Section("Last refresh") {
                Text(model.lastRefresh?.formatted(date: .abbreviated, time: .standard) ?? "Never")
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
