import Foundation

public enum SetupStage: String, Codable, CaseIterable, Sendable {
    case systemCompatibility
    case utmDetection
    case vmPreparation
    case privilegedHelperAuthorization
    case hostIsolationInstallation
    case guestBoot
    case guestProvisioning
    case tailscaleAuthentication
    case hermesInstallation
    case cuaInstallation
    case cuaAccessibilityPermission
    case cuaScreenRecordingPermission
    case hermesTokenGeneration
    case tailscaleServeConfiguration
    case tetherConnectionHandoff
    case finalVerification

    public var title: String {
        switch self {
        case .systemCompatibility: "System compatibility"
        case .utmDetection: "UTM detection"
        case .vmPreparation: "VM preparation"
        case .privilegedHelperAuthorization: "Authorize network helper"
        case .hostIsolationInstallation: "Install host isolation"
        case .guestBoot: "Boot guest"
        case .guestProvisioning: "Prepare guest"
        case .tailscaleAuthentication: "Sign in to Tailscale"
        case .hermesInstallation: "Install Hermes"
        case .cuaInstallation: "Install CUA"
        case .cuaAccessibilityPermission: "Guest Accessibility permission"
        case .cuaScreenRecordingPermission: "Guest Screen Recording permission"
        case .hermesTokenGeneration: "Generate Hermes token"
        case .tailscaleServeConfiguration: "Configure tailnet HTTPS"
        case .tetherConnectionHandoff: "Connect Tether"
        case .finalVerification: "Verify security and recovery"
        }
    }

    public var requirement: String {
        switch self {
        case .systemCompatibility: "Requires Apple silicon and macOS 14 or later."
        case .utmDetection: "Checks the supported UTM automation interface."
        case .vmPreparation: "Bind the exact UUID and resolve duplicate registrations."
        case .privilegedHelperAuthorization: "Requires the signed helper and administrator approval."
        case .hostIsolationInstallation: "Requires a reviewed policy and external negative tests."
        case .guestBoot: "Networked boot stays blocked until isolation is verified."
        case .guestProvisioning: "Requires a signed manifest and authenticated guest channel."
        case .tailscaleAuthentication: "Sign in and approve Tailscale inside the guest."
        case .hermesInstallation: "Install the pinned Hermes release inside the guest."
        case .cuaInstallation: "Install CUA in the non-admin guest desktop session."
        case .cuaAccessibilityPermission: "Allow CUA to control only the guest desktop."
        case .cuaScreenRecordingPermission: "Allow CUA to capture only the guest display."
        case .hermesTokenGeneration: "Generate in the guest and keep the host copy in Keychain."
        case .tailscaleServeConfiguration: "Expose HTTPS 443 only to guest loopback port 8642."
        case .tetherConnectionHandoff: "Requires an authenticated, expiring one-use pairing exchange."
        case .finalVerification: "Positive, negative, restart, and real-client checks must pass."
        }
    }
}

public enum SetupStageState: String, Codable, Sendable {
    case pending
    case running
    case waitingForUser
    case completed
    case failed
    case rollingBack
    case rolledBack
    case interrupted
}

public struct SetupStageRecord: Codable, Equatable, Sendable {
    public var stage: SetupStage
    public var state: SetupStageState
    public var attempts: Int
    public var updatedAt: Date
    public var diagnostic: String?
    public var rollbackAvailable: Bool

    public init(
        stage: SetupStage,
        state: SetupStageState = .pending,
        attempts: Int = 0,
        updatedAt: Date,
        diagnostic: String? = nil,
        rollbackAvailable: Bool = false
    ) {
        self.stage = stage
        self.state = state
        self.attempts = attempts
        self.updatedAt = updatedAt
        self.diagnostic = diagnostic
        self.rollbackAvailable = rollbackAvailable
    }
}

public struct SetupJournal: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var installationID: UUID
    public var designatedVM: DesignatedVirtualMachine?
    public var stages: [SetupStageRecord]
    public var updatedAt: Date

    public init(
        installationID: UUID = UUID(),
        designatedVM: DesignatedVirtualMachine? = nil,
        now: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.installationID = installationID
        self.designatedVM = designatedVM
        self.stages = SetupStage.allCases.map { SetupStageRecord(stage: $0, updatedAt: now) }
        self.updatedAt = now
    }

    public mutating func record(
        _ state: SetupStageState,
        for stage: SetupStage,
        diagnostic: String? = nil,
        rollbackAvailable: Bool? = nil,
        now: Date = Date()
    ) {
        guard let index = stages.firstIndex(where: { $0.stage == stage }) else { return }
        if state == .running && stages[index].state != .running {
            stages[index].attempts += 1
        }
        stages[index].state = state
        stages[index].diagnostic = diagnostic
        if let rollbackAvailable { stages[index].rollbackAvailable = rollbackAvailable }
        stages[index].updatedAt = now
        updatedAt = now
    }

    public var nextStage: SetupStage? {
        stages.first { $0.state != .completed }?.stage
    }

    public func recoveredAfterInterruption(now: Date = Date()) -> SetupJournal {
        var copy = self
        for index in copy.stages.indices where [.running, .rollingBack].contains(copy.stages[index].state) {
            copy.stages[index].state = .interrupted
            copy.stages[index].diagnostic = "Interrupted operation requires reconciliation before retry."
            copy.stages[index].updatedAt = now
        }
        copy.updatedAt = now
        return copy
    }
}
