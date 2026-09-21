import Foundation
import Darwin

public enum SetupJournalStoreError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidJournal
}

public actor FileSetupJournalStore: SetupJournalPersisting {
    private let fileURL: URL
    private let redactor: SecretRedactor

    public init(fileURL: URL, redactor: SecretRedactor = SecretRedactor()) {
        self.fileURL = fileURL
        self.redactor = redactor
    }

    public func load() throws -> SetupJournal? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let journal: SetupJournal
        do {
            journal = try JSONDecoder().decode(SetupJournal.self, from: data)
        } catch {
            throw SetupJournalStoreError.invalidJournal
        }
        guard journal.schemaVersion == SetupJournal.currentSchemaVersion else {
            throw SetupJournalStoreError.unsupportedSchema(journal.schemaVersion)
        }
        return journal.recoveredAfterInterruption()
    }

    public func save(_ journal: SetupJournal) throws {
        var sanitized = journal
        for index in sanitized.stages.indices {
            if let diagnostic = sanitized.stages[index].diagnostic {
                sanitized.stages[index].diagnostic = redactor.redact(diagnostic)
            }
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(sanitized)
        try data.write(to: fileURL, options: [.atomic])
        guard Darwin.chmod(fileURL.path, S_IRUSR | S_IWUSR) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
