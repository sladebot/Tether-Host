import Foundation

/// A user's report that pairing succeeded in Tether iOS. This is not a live
/// reachability check, and contains no connection credential.
public struct PhoneSetupConfirmation: Codable, Equatable, Sendable {
    public let vmID: VirtualMachineID
    public let endpoint: URL

    public init?(vmID: VirtualMachineID, endpoint: String) {
        guard let normalized = Self.normalizedEndpoint(endpoint) else { return nil }
        self.vmID = vmID
        self.endpoint = normalized
    }

    public func matches(vmID: VirtualMachineID?, endpoint: String) -> Bool {
        guard let vmID, let normalized = Self.normalizedEndpoint(endpoint) else { return false }
        return self.vmID == vmID && self.endpoint == normalized
    }

    public static func normalizedEndpoint(_ endpoint: String) -> URL? {
        (try? EndpointValidator.tailnetHTTPS(endpoint))?.url
    }
}
