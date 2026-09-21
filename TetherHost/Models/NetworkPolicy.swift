import Foundation

public enum HostNetworkAttachment: String, Codable, Sendable {
    /// Legacy UTM attachment retained for migration and recovery only.
    case utmSharedNetwork
    /// Tether-owned NAT attachment created with Apple's Virtualization.framework.
    case tetherNativeNAT
}

public enum NetworkAddressFamily: String, Codable, Sendable {
    case ipv4
    case ipv6
}

public struct NetworkAddress: Codable, Hashable, Sendable {
    public let value: String
    public let family: NetworkAddressFamily

    public init(value: String, family: NetworkAddressFamily) {
        self.value = value
        self.family = family
    }
}

public enum EgressPurpose: String, Codable, Sendable {
    case dns
    case networkTime
    case tailscaleControl
    case modelProvider
    case appleService
    case signedUpdate
}

public struct EgressAllowance: Codable, Hashable, Sendable {
    public let purpose: EgressPurpose
    public let destination: NetworkAddress
    public let port: UInt16
    public let transport: Transport

    public enum Transport: String, Codable, Sendable {
        case tcp
        case udp
    }

    public init(purpose: EgressPurpose, destination: NetworkAddress, port: UInt16, transport: Transport) {
        self.purpose = purpose
        self.destination = destination
        self.port = port
        self.transport = transport
    }
}

public struct HostFirewallRequest: Codable, Equatable, Sendable {
    public static let supportedPolicyRevision = 1

    public let installationID: UUID
    public let virtualMachineID: VirtualMachineID
    public let policyRevision: Int
    public let attachment: HostNetworkAttachment
    public let guestAddresses: [NetworkAddress]
    public let egressAllowances: [EgressAllowance]

    public init(
        installationID: UUID,
        virtualMachineID: VirtualMachineID,
        policyRevision: Int = Self.supportedPolicyRevision,
        attachment: HostNetworkAttachment = .tetherNativeNAT,
        guestAddresses: [NetworkAddress],
        egressAllowances: [EgressAllowance]
    ) {
        self.installationID = installationID
        self.virtualMachineID = virtualMachineID
        self.policyRevision = policyRevision
        self.attachment = attachment
        self.guestAddresses = guestAddresses
        self.egressAllowances = egressAllowances
    }
}

public struct FirewallRule: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case pass, block }

    public let action: Action
    public let family: NetworkAddressFamily
    public let source: NetworkAddress
    public let destination: NetworkAddress?
    public let transport: EgressAllowance.Transport?
    public let port: UInt16?

    public init(
        action: Action,
        family: NetworkAddressFamily,
        source: NetworkAddress,
        destination: NetworkAddress?,
        transport: EgressAllowance.Transport?,
        port: UInt16?
    ) {
        self.action = action
        self.family = family
        self.source = source
        self.destination = destination
        self.transport = transport
        self.port = port
    }
}

public struct HostFirewallPlan: Codable, Equatable, Sendable {
    public let installationID: UUID
    public let virtualMachineID: VirtualMachineID
    public let policyRevision: Int
    public let rules: [FirewallRule]

    public init(installationID: UUID, virtualMachineID: VirtualMachineID, policyRevision: Int, rules: [FirewallRule]) {
        self.installationID = installationID
        self.virtualMachineID = virtualMachineID
        self.policyRevision = policyRevision
        self.rules = rules
    }
}

public enum FirewallRequestError: Error, Equatable, Sendable {
    case unsupportedRevision
    case missingAddressFamily(NetworkAddressFamily)
    case invalidAddress(String)
    case mismatchedAddressFamily(String)
    case forbiddenDestination(String)
    case invalidPort
    case duplicateAllowance
}
