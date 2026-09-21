import Foundation

public enum DiagnosticEvent: String, Codable, Sendable {
    case applicationOpened
    case inventoryRead
    case inventoryFailed
    case vmDesignated
    case setupChecked
    case setupBlocked
    case stateUnavailable
}

public struct DiagnosticEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let event: DiagnosticEvent
    public let date: Date

    public init(event: DiagnosticEvent, date: Date = Date()) {
        self.id = UUID()
        self.event = event
        self.date = date
    }
}
