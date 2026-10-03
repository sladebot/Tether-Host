/// Synchronous transaction gate. Owners must access this state on one actor.
/// An installation retains the gate while transitioning to its first boot.
public struct NativeVMOperationState: Equatable, Sendable {
    public enum Operation: Equatable, Sendable {
        case checkingImage, downloadingImage, installing, starting, stopping, preparingMedia
    }
    public private(set) var operation: Operation?
    public var isBusy: Bool { operation != nil }
    public init() {}

    @discardableResult
    public mutating func begin(_ operation: Operation) -> Bool {
        guard self.operation == nil else { return false }
        self.operation = operation
        return true
    }

    @discardableResult
    public mutating func transition(from expected: Operation, to next: Operation) -> Bool {
        guard operation == expected else { return false }
        operation = next
        return true
    }

    public mutating func finish() { operation = nil }
}
