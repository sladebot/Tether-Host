import SwiftUI
#if canImport(TetherHostCore)
import TetherHostCore
#endif

extension HealthState {
    var label: String {
        switch self {
        case .healthy: "Pass"
        case .degraded: "Warning"
        case .unhealthy: "Fail"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .unhealthy: "xmark.octagon.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .healthy: .green
        case .degraded: .orange
        case .unhealthy: .red
        case .unknown: .secondary
        }
    }
}

extension EvidenceSource {
    var label: String {
        switch self {
        case .notChecked: "Not checked"
        case .utm: "UTM"
        case .guest: "Guest report"
        case .hostHelper: "Host helper"
        case .independentProbe: "Independent probe"
        }
    }
}

struct StateBadge: View {
    let state: HealthState

    var body: some View {
        Label(state.label, systemImage: state.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(state.color.opacity(0.12), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Status: \(state.label)")
    }
}

struct EvidenceRow: View {
    let observation: HealthObservation
    let now: Date

    private var effectiveState: HealthState { observation.effectiveState(at: now) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: effectiveState.symbol)
                .foregroundStyle(effectiveState.color)
                .font(.title3)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(observation.component.title)
                    .font(.body.weight(.medium))
                HStack(spacing: 5) {
                    Text("Source: \(observation.source.label)")
                    Text("•")
                        .accessibilityHidden(true)
                    Text(observation.observedAt?.formatted(date: .abbreviated, time: .standard) ?? "Never checked")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)
            StateBadge(state: effectiveState)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(observation.component.title), \(effectiveState.label), source \(observation.source.label)")
    }
}

struct ReadOnlyAction: View {
    let title: String
    let symbol: String
    let reason: String

    var body: some View {
        Button {} label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(true)
        .help(reason)
        .accessibilityHint(reason)
    }
}

struct EmptyEvidenceView: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .frame(maxWidth: .infinity, minHeight: 220)
    }
}

extension SetupStageState {
    var label: String {
        switch self {
        case .pending: "Pending"
        case .running: "In progress"
        case .waitingForUser: "Action needed"
        case .completed: "Complete"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        case .rollingBack: "Rolling back"
        case .rolledBack: "Rolled back"
        }
    }

    var symbol: String {
        switch self {
        case .pending: "circle"
        case .running: "progress.indicator"
        case .waitingForUser: "person.crop.circle.badge.exclamationmark"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .interrupted: "pause.circle.fill"
        case .rollingBack: "arrow.uturn.backward.circle.fill"
        case .rolledBack: "arrow.uturn.backward.circle"
        }
    }

    var color: Color {
        switch self {
        case .pending: .secondary
        case .running: .blue
        case .waitingForUser: .orange
        case .completed: .green
        case .failed: .red
        case .interrupted: .orange
        case .rollingBack: .orange
        case .rolledBack: .secondary
        }
    }
}

extension HealthComponent {
    var title: String {
        switch self {
        case .virtualMachine: "Virtual machine"
        case .hermesVersion: "Hermes version"
        case .hermes: "Hermes health"
        case .apiAuthentication: "API authentication"
        case .tailscale: "Guest Tailscale identity"
        case .tailscaleServe: "Tailnet HTTPS / Funnel"
        case .cua: "CUA driver"
        case .cuaAccessibility: "Guest Accessibility"
        case .cuaScreenRecording: "Guest Screen Recording"
        case .hostSharing: "Host folder sharing"
        case .clipboard: "Host clipboard sharing"
        case .networkIsolation: "Host network isolation"
        case .negativeIsolationTests: "Negative isolation tests"
        case .tetherClient: "Tether client"
        case .providers: "Models and providers"
        case .activeRuns: "Active runs"
        }
    }
}
