import Foundation

public enum OwnedArtifactKind: String, Codable, Sendable {
    case helperRegistration
    case networkPolicy
    case setupJournal
    case keychainCredential
    case guestReceipt
    case virtualMachineRegistration
    case virtualMachineDisk
}

public struct OwnedArtifact: Codable, Hashable, Sendable {
    public let kind: OwnedArtifactKind
    public let identifier: String
    public let installationID: UUID
    public let adopted: Bool

    public init(kind: OwnedArtifactKind, identifier: String, installationID: UUID, adopted: Bool = false) {
        self.kind = kind
        self.identifier = identifier
        self.installationID = installationID
        self.adopted = adopted
    }
}

public struct RepairRequest: Codable, Equatable, Sendable {
    public let installationID: UUID
    public let artifactKinds: Set<OwnedArtifactKind>

    public init(installationID: UUID, artifactKinds: Set<OwnedArtifactKind>) {
        self.installationID = installationID
        self.artifactKinds = artifactKinds
    }
}

public struct UninstallRequest: Codable, Equatable, Sendable {
    public let installationID: UUID
    public let removeManagementData: Bool
    public let deleteVirtualMachineDisk: Bool
    public let confirmedDiskDeletionVMID: VirtualMachineID?

    public init(
        installationID: UUID,
        removeManagementData: Bool = true,
        deleteVirtualMachineDisk: Bool = false,
        confirmedDiskDeletionVMID: VirtualMachineID? = nil
    ) {
        self.installationID = installationID
        self.removeManagementData = removeManagementData
        self.deleteVirtualMachineDisk = deleteVirtualMachineDisk
        self.confirmedDiskDeletionVMID = confirmedDiskDeletionVMID
    }
}

public enum ScopedOperationError: Error, Equatable, Sendable {
    case foreignArtifact(String)
    case adoptedArtifactCannotBeRemoved(String)
    case diskDeletionRequiresExactConfirmation
}

public enum ScopedOperationPlanner {
    public static func repairTargets(
        request: RepairRequest,
        inventory: [OwnedArtifact]
    ) throws -> [OwnedArtifact] {
        let candidates = inventory.filter { request.artifactKinds.contains($0.kind) }
        guard candidates.allSatisfy({ $0.installationID == request.installationID }) else {
            throw ScopedOperationError.foreignArtifact("Repair inventory contains a foreign installation.")
        }
        return candidates
    }

    public static func uninstallTargets(
        request: UninstallRequest,
        inventory: [OwnedArtifact],
        designatedVMID: VirtualMachineID?
    ) throws -> [OwnedArtifact] {
        let owned = inventory.filter { $0.installationID == request.installationID }
        var result = owned.filter { artifact in
            artifact.kind != .virtualMachineDisk && artifact.kind != .virtualMachineRegistration
        }

        if request.deleteVirtualMachineDisk {
            guard let designatedVMID,
                  request.confirmedDiskDeletionVMID == designatedVMID else {
                throw ScopedOperationError.diskDeletionRequiresExactConfirmation
            }
            let vmArtifacts = owned.filter {
                $0.kind == .virtualMachineDisk || $0.kind == .virtualMachineRegistration
            }
            if let adopted = vmArtifacts.first(where: { $0.adopted }) {
                throw ScopedOperationError.adoptedArtifactCannotBeRemoved(adopted.identifier)
            }
            result.append(contentsOf: vmArtifacts)
        }
        return result
    }
}
