import CryptoKit
import Foundation

public struct ManifestVerifier: Sendable {
    private let publicKey: Curve25519.Signing.PublicKey
    private let allowedDownloadHosts: Set<String>

    public init(publicKey: Data, allowedDownloadHosts: Set<String>) throws {
        self.publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        self.allowedDownloadHosts = allowedDownloadHosts
    }

    public func verify(
        payload: Data,
        signature: Data,
        minimumSequence: Int,
        now: Date = Date()
    ) throws -> VerifiedProvisioningManifest {
        guard payload.count <= 128 * 1024,
              publicKey.isValidSignature(signature, for: payload) else {
            throw ManifestVerificationError.invalidSignature
        }
        guard let manifest = try? JSONDecoder().decode(ProvisioningManifest.self, from: payload),
              manifest.schemaVersion == 1,
              manifest.sequence >= max(1, minimumSequence),
              manifest.expiresAt > now,
              manifest.components.count == ProvisionedComponentID.allCases.count,
              Set(manifest.components.map(\.id)) == Set(ProvisionedComponentID.allCases) else {
            throw ManifestVerificationError.invalidManifest
        }
        for component in manifest.components {
            guard let parts = URLComponents(url: component.downloadURL, resolvingAgainstBaseURL: false),
                  parts.scheme == "https",
                  let host = parts.host,
                  allowedDownloadHosts.contains(host),
                  parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil,
                  parts.port == nil || parts.port == 443,
                  component.version.range(
                    of: #"^\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?$"#,
                    options: .regularExpression
                  ) != nil,
                  component.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
                throw ManifestVerificationError.invalidManifest
            }
        }
        return VerifiedProvisioningManifest(manifest: manifest)
    }

    public static func verifyDownload(_ data: Data, component: ProvisionedComponent) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == component.sha256 else { throw ManifestVerificationError.digestMismatch }
    }
}

public struct IdempotentProvisioningPlan: Equatable, Sendable {
    public let virtualMachineID: VirtualMachineID
    public let sequence: Int
    public let pending: [ProvisionedComponent]

    public init(
        virtualMachineID: VirtualMachineID,
        manifest: VerifiedProvisioningManifest,
        receipts: [ComponentInstallationReceipt]
    ) throws {
        guard receipts.allSatisfy({ $0.virtualMachineID == virtualMachineID }),
              Set(receipts.map { $0.component.id }).count == receipts.count else {
            throw ManifestVerificationError.unsafeReceipt
        }
        self.virtualMachineID = virtualMachineID
        self.sequence = manifest.manifest.sequence
        self.pending = manifest.manifest.components.filter { component in
            !receipts.contains { $0.component == component }
        }
    }
}
