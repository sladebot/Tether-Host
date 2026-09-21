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
                LabeledContent("Mode", value: "Built-in macOS VM with UTM backup")
                Text("Tether Host can install and start a fresh Apple VM from an IPSW. Guest setup runs inside that VM. Verified connection credentials are stored in Keychain.")
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
