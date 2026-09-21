import Foundation

public enum HealthComponent: String, Codable, CaseIterable, Sendable {
    case virtualMachine
    case hermesVersion
    case hermes
    case apiAuthentication
    case tailscale
    case tailscaleServe
    case cua
    case cuaAccessibility
    case cuaScreenRecording
    case hostSharing
    case clipboard
    case networkIsolation
    case negativeIsolationTests
    case tetherClient
    case providers
    case activeRuns

    public var requiresIndependentHostEvidence: Bool {
        [.hostSharing, .clipboard, .networkIsolation, .negativeIsolationTests].contains(self)
    }
}

public enum HealthState: String, Codable, Sendable {
    case healthy
    case degraded
    case unhealthy
    case unknown
}

public enum EvidenceSource: String, Codable, Sendable {
    case notChecked
    case appleVirtualization
    case utm
    case guest
    case hostHelper
    case independentProbe
}

public struct HealthObservation: Codable, Equatable, Identifiable, Sendable {
    public let component: HealthComponent
    public let state: HealthState
    public let summary: String
    public let source: EvidenceSource
    public let observedAt: Date?
    public let validFor: TimeInterval
    public var id: HealthComponent { component }

    public init(
        component: HealthComponent,
        state: HealthState,
        summary: String,
        source: EvidenceSource = .notChecked,
        observedAt: Date? = nil,
        validFor: TimeInterval
    ) {
        self.component = component
        self.state = state
        self.summary = summary
        self.source = source
        self.observedAt = observedAt
        self.validFor = validFor
    }

    public func effectiveState(at now: Date) -> HealthState {
        guard source != .notChecked, let observedAt,
              (0...validFor).contains(now.timeIntervalSince(observedAt)) else { return .unknown }
        if component.requiresIndependentHostEvidence,
           source != .hostHelper && source != .independentProbe { return .unknown }
        return state
    }
}

public struct HealthReport: Codable, Equatable, Sendable {
    public let overall: HealthState
    public let observations: [HealthObservation]
    public let generatedAt: Date

    public init(overall: HealthState, observations: [HealthObservation], generatedAt: Date) {
        self.overall = overall
        self.observations = observations
        self.generatedAt = generatedAt
    }
}
