import Foundation

public enum HostSetupDependency: String, CaseIterable, Sendable {
    case vm, tailscale, hermes, phone
}

/// Host-side gates. Desktop and Tailscale confirmations are user attestations;
/// the host does not treat software on the physical Mac as guest evidence.
public struct HostSetupDependencies: Equatable, Sendable {
    public let vmSelected: Bool
    public let vmRunning: Bool
    public let desktopConfirmed: Bool
    public let tailscaleConfirmed: Bool
    public let backendVerified: Bool

    public init(
        vmSelected: Bool, vmRunning: Bool, desktopConfirmed: Bool,
        tailscaleConfirmed: Bool, backendVerified: Bool
    ) {
        self.vmSelected = vmSelected
        self.vmRunning = vmRunning
        self.desktopConfirmed = desktopConfirmed
        self.tailscaleConfirmed = tailscaleConfirmed
        self.backendVerified = backendVerified
    }

    public var vmReady: Bool { vmSelected && vmRunning && desktopConfirmed }
    public var tailscaleReady: Bool { vmReady && tailscaleConfirmed }
    public var hermesReady: Bool { tailscaleReady && backendVerified }

    public func isUnlocked(_ dependency: HostSetupDependency) -> Bool {
        switch dependency {
        case .vm: true
        case .tailscale: vmReady
        case .hermes: vmReady
        case .phone: hermesReady
        }
    }
}
