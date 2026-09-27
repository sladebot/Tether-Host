import Foundation

public enum VirtualizationAvailability: Equatable, Sendable {
    case unchecked
    case ready
    case blocked(String)

    public var canContinue: Bool { self == .ready }
}

/// Owns the Apple Virtualization welcome gate independently of the UI.
public struct VirtualizationSetup: Equatable, Sendable {
    public private(set) var availability: VirtualizationAvailability = .unchecked
    public private(set) var hasContinued = false

    public init() {}

    public mutating func refresh(using check: () -> VirtualizationAvailability) {
        availability = check()
        if !availability.canContinue { hasContinued = false }
    }

    @discardableResult
    public mutating func advance(using check: () -> VirtualizationAvailability) -> Bool {
        refresh(using: check)
        hasContinued = availability.canContinue
        return hasContinued
    }

    public mutating func back() { hasContinued = false }
}
