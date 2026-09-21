import Foundation

public enum VMProvider: String, CaseIterable, Codable, Sendable {
    case builtIn, utm

    public var title: String { self == .builtIn ? "Built-in VM" : "UTM" }
}

public enum VMProviderAvailability: Equatable, Sendable {
    case unchecked
    case ready
    case blocked(String)

    public var canContinue: Bool { self == .ready }
}

/// Owns the welcome gate independently of the UI. Advancing always checks again.
public struct VMProviderSetup: Equatable, Sendable {
    public private(set) var provider: VMProvider
    public private(set) var availability: VMProviderAvailability = .unchecked
    public private(set) var hasContinued = false

    public init(provider: VMProvider = .builtIn) { self.provider = provider }

    public mutating func select(_ provider: VMProvider) {
        self.provider = provider
        availability = .unchecked
        hasContinued = false
    }

    public mutating func refresh(using check: (VMProvider) -> VMProviderAvailability) {
        availability = check(provider)
        if !availability.canContinue { hasContinued = false }
    }

    @discardableResult
    public mutating func advance(using check: (VMProvider) -> VMProviderAvailability) -> Bool {
        refresh(using: check)
        hasContinued = availability.canContinue
        return hasContinued
    }

    public mutating func back() { hasContinued = false }
}
