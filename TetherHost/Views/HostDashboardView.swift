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
                nextStep
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
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("Health")
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
            Image(systemName: isolationState.symbol)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(isolationState.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(summaryTitle)
                    .font(.title2.bold())
                Text(summaryDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            StateBadge(state: isolationState)
        }
        .padding(20)
        .background(isolationState.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isolationState.color.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var isolationState: HealthState {
        HealthAggregator.aggregate(
            model.observations,
            required: Set(groups[0].2),
            now: now
        ).overall
    }

    private var summaryTitle: String {
        switch isolationState {
        case .healthy: "Isolation is verified"
        case .degraded: "Isolation needs attention"
        case .unhealthy: "Isolation verification failed"
        case .unknown: "Isolation is not verified"
        }
    }

    private var summaryDetail: String {
        switch isolationState {
        case .healthy: "All four boundary checks have fresh host evidence."
        case .degraded: "Review the boundary warning before running guest workloads."
        case .unhealthy: "Keep the VM stopped until the failed boundary check is repaired and repeated."
        case .unknown: "One or more boundary checks lack fresh, accepted host evidence."
        }
    }

    private var nextStep: some View {
        GroupBox("Connection setup") {
            HStack(alignment: .center, spacing: 16) {
                Text(connectionDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(connectionActionTitle, systemImage: connectionActionSymbol) {
                    if model.isInsideGuest {
                        model.selection = .setup
                    } else {
                        let gates = model.setupDependencies
                        model.workspaceSection = !gates.vmReady ? .vm
                            : !gates.tailscaleReady ? .tailscale
                            : !gates.hermesReady ? .hermes : .phone
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 6)
        }
    }

    private var connectionDetail: String {
        if model.isInsideGuest { return "Complete guest setup to make this Mac available to your iPhone." }
        let gates = model.setupDependencies
        if !gates.vmReady { return "Set up and start a virtual machine to continue." }
        if !gates.tailscaleReady { return "VM ready. Confirm Tailscale inside the guest." }
        if !gates.hermesReady { return "Tailscale confirmed. Verify Hermes inside the guest." }
        if model.isPhoneSetupComplete { return "iPhone setup confirmed by you. Guest connection verified." }
        return "Guest connection verified. Connect your iPhone."
    }

    private var connectionActionTitle: String {
        if model.isInsideGuest { return "Open guest setup" }
        if model.setupDependencies.hermesReady {
            return model.isPhoneSetupComplete ? "View connection" : "Connect iPhone"
        }
        return "Continue setup"
    }

    private var connectionActionSymbol: String {
        !model.isInsideGuest && model.setupDependencies.hermesReady ? "iphone" : "arrow.right"
    }

    private func observations(for keys: [HealthComponent]) -> [HealthObservation] {
        keys.compactMap { key in model.observations.first { $0.component == key } }
    }
}
