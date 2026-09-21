import Foundation

public protocol VirtualMachineReading: Sendable {
    func list() async throws -> [VirtualMachineRecord]
    func status(of id: VirtualMachineID) async throws -> VirtualMachineState
}

public protocol VirtualMachineManaging: VirtualMachineReading {
    func start(id: VirtualMachineID) async throws
    func stop(id: VirtualMachineID) async throws
}

public enum ProvisioningStep: Codable, Equatable, Sendable {
    case verifyManifest(revision: Int)
    case installComponent(identifier: String, digest: String)
    case configureHermesLoopback(port: UInt16)
    case configureTailscaleServe
    case verifyReceipt(identifier: String, digest: String)
}

public struct ProvisioningReceipt: Codable, Equatable, Sendable {
    public let step: ProvisioningStep
    public let completedAt: Date

    public init(step: ProvisioningStep, completedAt: Date) {
        self.step = step
        self.completedAt = completedAt
    }
}

public protocol VirtualMachineProvisioning: Sendable {
    func execute(_ step: ProvisioningStep, on id: VirtualMachineID) async throws -> ProvisioningReceipt
}

public protocol PrivilegedNetworking: Sendable {
    func inspectPolicy(for installationID: UUID) async throws -> HostFirewallPlan?
    func installPolicy(_ plan: HostFirewallPlan) async throws
    func removePolicy(for installationID: UUID) async throws
}

public protocol SecretStoring: Sendable {
    func store(_ secret: SecretValue, for handle: SecretHandle) async throws
    func load(_ handle: SecretHandle) async throws -> SecretValue?
    func remove(_ handle: SecretHandle) async throws
}

public protocol HealthChecking: Sendable {
    func observations() async -> [HealthObservation]
}

public protocol SetupJournalPersisting: Sendable {
    func load() async throws -> SetupJournal?
    func save(_ journal: SetupJournal) async throws
    func remove() async throws
}
