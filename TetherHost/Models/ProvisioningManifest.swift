import Foundation

public enum ProvisionedComponentID: String, Codable, CaseIterable, Sendable {
    case hermes, tailscale, cua
}

public struct ProvisionedComponent: Codable, Equatable, Sendable {
    public let id: ProvisionedComponentID
    public let version: String
    public let downloadURL: URL
    public let sha256: String

    public init(id: ProvisionedComponentID, version: String, downloadURL: URL, sha256: String) {
        self.id = id
        self.version = version
        self.downloadURL = downloadURL
        self.sha256 = sha256
    }
}

public struct ProvisioningManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let sequence: Int
    public let expiresAt: Date
    public let components: [ProvisionedComponent]

    public init(schemaVersion: Int = 1, sequence: Int, expiresAt: Date, components: [ProvisionedComponent]) {
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.expiresAt = expiresAt
        self.components = components
    }
}

public struct VerifiedProvisioningManifest: Sendable {
    public let manifest: ProvisioningManifest
    init(manifest: ProvisioningManifest) { self.manifest = manifest }
}

public struct ComponentInstallationReceipt: Equatable, Sendable {
    public let virtualMachineID: VirtualMachineID
    public let component: ProvisionedComponent

    public init(virtualMachineID: VirtualMachineID, component: ProvisionedComponent) {
        self.virtualMachineID = virtualMachineID
        self.component = component
    }
}

public enum ManifestVerificationError: Error, Equatable, Sendable {
    case invalidSignature
    case invalidManifest
    case digestMismatch
    case unsafeReceipt
}
