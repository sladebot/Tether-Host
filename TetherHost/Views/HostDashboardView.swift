import SwiftUI
#if canImport(TetherHostCore)
import TetherHostCore
#endif

struct HostDashboardView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var now = Date()

    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private let groups: [(String, String, [HealthComponent])] = [
        ("Isolation boundary", "lock.shield", [.hostSharing, .clipboard, .networkIsolation, .negativeIsolationTests]),
        ("Guest services", "server.rack", [.virtualMachine, .hermesVersion, .hermes, .apiAuthentication, .cua, .cuaAccessibility, .cuaScreenRecording]),
        ("Tailnet connection", "network", [.tailscale, .tailscaleServe, .tetherClient]),
        ("Workload", "waveform.path.ecg", [.providers, .activeRuns])
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                header
                isolationSummary

                ForEach(groups, id: \.0) { group in
                    GroupBox {
                        VStack(spacing: 0) {
                            ForEach(observations(for: group.2)) { observation in
                                EvidenceRow(observation: observation, now: now)
                                if observation.component != observations(for: group.2).last?.component { Divider() }
                            }
                        }
                        .padding(.horizontal, 4)
                    } label: {
                        Label(group.0, systemImage: group.1)
                            .font(.headline)
                    }
                }

                actions
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("Security overview")
        .onReceive(timer) { now = $0 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tether Host for Mac")
                .font(.largeTitle.bold())
            Text(model.statusMessage)
                .foregroundStyle(.secondary)
            if let refreshed = model.lastRefresh {
                Text("Last refresh \(refreshed.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var isolationSummary: some View {
        HStack(alignment: .center, spacing: 20) {
            Image(systemName: model.securityState.symbol)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(model.securityState.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(summaryTitle)
                    .font(.title2.bold())
                Text(summaryDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            StateBadge(state: model.securityState)
        }
        .padding(20)
        .background(model.securityState.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(model.securityState.color.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var summaryTitle: String {
        switch model.securityState {
        case .healthy: "Isolation is verified"
        case .degraded: "Isolation needs attention"
        case .unhealthy: "Isolation verification failed"
        case .unknown: "Isolation is not verified"
        }
    }

    private var summaryDetail: String {
        switch model.securityState {
        case .healthy: "All required checks have fresh evidence from an accepted source."
        case .degraded: "Review the warning evidence before allowing guest workloads."
        case .unhealthy: "Keep the VM stopped until the failed boundary check is repaired and repeated."
        case .unknown: "Unknown, stale, duplicated, or incomplete evidence never counts as a pass."
        }
    }

    private var actions: some View {
        GroupBox("Management controls") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Controls remain unavailable while this observation build is connected to a read-only provider.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                    ReadOnlyAction(title: "Start VM", symbol: "play.fill", reason: readOnlyReason)
                    ReadOnlyAction(title: "Stop VM", symbol: "stop.fill", reason: readOnlyReason)
                    ReadOnlyAction(title: "Restart Hermes", symbol: "arrow.clockwise", reason: readOnlyReason)
                    ReadOnlyAction(title: "Run diagnostics", symbol: "stethoscope", reason: readOnlyReason)
                    ReadOnlyAction(title: "Repair installation", symbol: "wrench.and.screwdriver", reason: readOnlyReason)
                    ReadOnlyAction(title: "Rotate token", symbol: "key", reason: "Token rotation requires a Keychain-backed implementation and explicit confirmation.")
                    Button("Connect Tether", systemImage: "iphone") { model.selection = .setup }
                    ReadOnlyAction(title: "Uninstall", symbol: "trash", reason: "Uninstall requires an ownership inventory and a separate confirmation before VM data deletion.")
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var readOnlyReason: String {
        "Unavailable in the read-only observation build."
    }

    private func observations(for keys: [HealthComponent]) -> [HealthObservation] {
        keys.compactMap { key in model.observations.first { $0.component == key } }
    }
}
