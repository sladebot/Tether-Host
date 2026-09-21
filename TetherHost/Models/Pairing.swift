import Foundation

public struct PairingPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let pairingID: UUID
    public let endpoint: ValidatedEndpoint
    public let expiresAt: Date
    public let hostPublicKeyFingerprint: String

    public init(
        version: Int = 1,
        pairingID: UUID,
        endpoint: ValidatedEndpoint,
        expiresAt: Date,
        hostPublicKeyFingerprint: String
    ) {
        self.version = version
        self.pairingID = pairingID
        self.endpoint = endpoint
        self.expiresAt = expiresAt
        self.hostPublicKeyFingerprint = hostPublicKeyFingerprint
    }
}

public enum PairingPayloadError: Error, Equatable, Sendable {
    case expired
    case invalidFingerprint
    case cannotEncode
}
