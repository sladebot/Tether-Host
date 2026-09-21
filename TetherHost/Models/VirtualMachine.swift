import Foundation

public struct VirtualMachineID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init?(_ value: String) {
        guard let uuid = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        self.rawValue = uuid
    }

    public var description: String { rawValue.uuidString }
}

public enum VirtualMachineState: String, Codable, CaseIterable, Sendable {
    case stopped
    case starting
    case started
    case stopping
    case paused
    case unavailable
    case unknown
}

public struct VirtualMachineRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: VirtualMachineID
    public let name: String
    public let state: VirtualMachineState

    public init(id: VirtualMachineID, name: String, state: VirtualMachineState) {
        self.id = id
        self.name = name
        self.state = state
    }
}

public struct DesignatedVirtualMachine: Codable, Hashable, Sendable {
    public let id: VirtualMachineID
    public let expectedName: String

    public init(id: VirtualMachineID, expectedName: String) {
        self.id = id
        self.expectedName = expectedName
    }
}

public enum VirtualMachineSelection: Equatable, Sendable {
    case absent
    case selected(VirtualMachineRecord)
    case duplicateIDs(VirtualMachineID)
    case ambiguousName([VirtualMachineRecord])
}

public enum VirtualMachineSelector {
    public static func select(
        designated: DesignatedVirtualMachine?,
        expectedName: String,
        from records: [VirtualMachineRecord]
    ) -> VirtualMachineSelection {
        if let designated {
            let exact = records.filter { $0.id == designated.id }
            if exact.count > 1 { return .duplicateIDs(designated.id) }
            if let record = exact.first { return .selected(record) }
            return .absent
        }

        let named = records.filter { $0.name == expectedName }
        switch named.count {
        case 0: return .absent
        case 1: return .selected(named[0])
        default: return .ambiguousName(named)
        }
    }
}
