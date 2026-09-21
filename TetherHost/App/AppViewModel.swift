import Foundation
import SwiftUI
import TetherHostCore

struct HostDashboardSnapshot: Sendable {
    var observations: [HealthObservation]
    var inventory: [VirtualMachineRecord]
    var setup: SetupJournal
    var diagnostics: [DiagnosticEntry]

    static var unobserved: HostDashboardSnapshot {
        HostDashboardSnapshot(
            observations: HealthComponent.allCases.map {
                HealthObservation(component: $0, state: .unknown, summary: "Not checked", validFor: 60)
            },
            inventory: [],
            setup: SetupJournal(),
            diagnostics: []
        )
    }
}

protocol HostStatusProviding: Sendable {
    func snapshot() async throws -> HostDashboardSnapshot
}

struct LiveHostStatusProvider: HostStatusProviding {
    private let reader: (any VirtualMachineReading)?
    private let journalStore: FileSetupJournalStore?

    init() {
        if let executor = try? UTMCTLProcessExecutor() {
            reader = UTMCTLAdapter(executor: executor)
        } else {
            reader = nil
        }
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            journalStore = FileSetupJournalStore(
                fileURL: support
                    .appendingPathComponent("Tether Host for Mac", isDirectory: true)
                    .appendingPathComponent("setup-journal.json")
            )
        } else {
            journalStore = nil
        }
    }

    func snapshot() async throws -> HostDashboardSnapshot {
        guard let reader else { throw UTMAdapterError.executableUnavailable }
        let inventory = try await reader.list()
        let now = Date()
        let matches = inventory.filter { $0.name == "Hermes Sandbox" }
        let vmState: HealthState = matches.count == 1 ? .healthy : .degraded
        let detail = matches.count == 1
            ? "Exact VM UUID is available for designation."
            : "Found \(matches.count) registrations named Hermes Sandbox; exact designation is required."
        var observations = HostDashboardSnapshot.unobserved.observations
        if let index = observations.firstIndex(where: { $0.component == .virtualMachine }) {
            observations[index] = HealthObservation(
                component: .virtualMachine,
                state: vmState,
                summary: detail,
                source: .utm,
                observedAt: now,
                validFor: 60
            )
        }
        let setup = try await journalStore?.load() ?? SetupJournal(now: now)
        return HostDashboardSnapshot(
            observations: observations,
            inventory: inventory,
            setup: setup,
            diagnostics: [DiagnosticEntry(event: .inventoryRead, date: now)]
        )
    }
}

enum HostDestination: String, CaseIterable, Identifiable {
    case overview, setup, virtualMachines, diagnostics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .setup: "Setup Assistant"
        case .virtualMachines: "Virtual Machines"
        case .diagnostics: "Diagnostics"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "shield.lefthalf.filled"
        case .setup: "checklist"
        case .virtualMachines: "macpro.gen3"
        case .diagnostics: "stethoscope"
        }
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var selection: HostDestination? = .overview
    @Published private(set) var observations: [HealthObservation]
    @Published private(set) var inventory: [VirtualMachineRecord]
    @Published private(set) var setup: SetupJournal
    @Published private(set) var diagnostics: [DiagnosticEntry]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var statusMessage = "No host evidence has been collected yet."

    private let provider: any HostStatusProviding

    init(provider: any HostStatusProviding = LiveHostStatusProvider()) {
        self.provider = provider
        let initial = HostDashboardSnapshot.unobserved
        observations = initial.observations
        inventory = initial.inventory
        setup = initial.setup
        diagnostics = initial.diagnostics
    }

    var securityState: HealthState { HealthAggregator.aggregate(observations).overall }
    var completedSetupCount: Int { setup.stages.count { $0.state == .completed } }
    var setupProgress: Double {
        setup.stages.isEmpty ? 0 : Double(completedSetupCount) / Double(setup.stages.count)
    }
    var duplicatedVMNames: Set<String> {
        let names = Dictionary(grouping: inventory) {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        return Set(names.filter { $0.value.count > 1 }.keys)
    }

    func isDuplicate(_ vm: VirtualMachineRecord) -> Bool {
        duplicatedVMNames.contains(vm.name.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        ))
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let next = try await provider.snapshot()
            observations = normalized(next.observations)
            inventory = next.inventory.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame
                    ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
                    : order == .orderedAscending
            }
            setup = next.setup
            diagnostics = next.diagnostics
            lastRefresh = Date()
            statusMessage = "Evidence refreshed. Review its source and collection time before acting."
        } catch {
            observations = HostDashboardSnapshot.unobserved.observations
            inventory = []
            lastRefresh = Date()
            statusMessage = (error as? LocalizedError)?.errorDescription
                ?? "Host status is unavailable. No security claim can be made."
        }
    }

    private func normalized(_ input: [HealthObservation]) -> [HealthObservation] {
        let grouped = Dictionary(grouping: input, by: \.component)
        return HealthComponent.allCases.map { component in
            guard let values = grouped[component], values.count == 1, let value = values.first else {
                return HealthObservation(component: component, state: .unknown, summary: "Not checked", validFor: 60)
            }
            return value
        }
    }
}
