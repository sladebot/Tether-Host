import Foundation

public enum HealthAggregator {
    public static func aggregate(
        _ observations: [HealthObservation],
        required: Set<HealthComponent> = Set(HealthComponent.allCases),
        now: Date = Date()
    ) -> HealthReport {
        var newest: [HealthComponent: HealthObservation] = [:]
        for observation in observations where required.contains(observation.component) {
            if newest[observation.component].map({
                ($0.observedAt ?? .distantPast) < (observation.observedAt ?? .distantPast)
            }) ?? true {
                newest[observation.component] = observation
            }
        }

        let states = required.map { component in
            newest[component]?.effectiveState(at: now) ?? .unknown
        }
        let overall: HealthState
        if states.contains(.unhealthy) {
            overall = .unhealthy
        } else if states.contains(.unknown) {
            overall = .unknown
        } else if states.contains(.degraded) {
            overall = .degraded
        } else {
            overall = .healthy
        }
        return HealthReport(
            overall: overall,
            observations: newest.values.sorted { $0.component.rawValue < $1.component.rawValue },
            generatedAt: now
        )
    }
}
