import Foundation
#if canImport(Virtualization)
import Virtualization
#endif

public struct NativeVirtualMachineManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: VirtualMachineID
    public let name: String
    public let guestImageVersion: String
    public let createdAt: Date

    public init(
        id: VirtualMachineID,
        name: String = "Tether Sandbox",
        guestImageVersion: String,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.guestImageVersion = guestImageVersion
        self.createdAt = createdAt
    }
}

public enum NativeVirtualMachineStoreError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedHost
    case invalidRoot
    case invalidBundleName(String)
    case symbolicLinkNotAllowed(String)
    case malformedManifest(String)
    case unsupportedSchema(Int)
    case identityMismatch
    case duplicateID(VirtualMachineID)

    public var errorDescription: String? {
        switch self {
        case .unsupportedHost:
            "Apple virtualization requires Apple silicon and macOS 14 or later."
        case .invalidRoot:
            "The Tether virtual machine directory is unavailable."
        case .invalidBundleName(let name):
            "A Tether VM bundle has an invalid identifier: \(name)."
        case .symbolicLinkNotAllowed(let name):
            "Symbolic links are not allowed in the Tether VM store: \(name)."
        case .malformedManifest(let name):
            "The Tether VM manifest is invalid: \(name)."
        case .unsupportedSchema(let version):
            "The Tether VM manifest schema \(version) is unsupported."
        case .identityMismatch:
            "The Tether VM manifest identity does not match its bundle directory."
        case .duplicateID(let id):
            "The Tether VM store contains duplicate identity \(id)."
        }
    }
}

public enum AppleVirtualizationSupport {
    public static var isAvailable: Bool {
        #if canImport(Virtualization) && arch(arm64)
        if #available(macOS 14, *) { return true }
        #endif
        return false
    }
}

/// Owns the on-disk inventory for VMs run directly with Apple's
/// Virtualization.framework. A complete VM bundle is rooted at its immutable UUID
/// and contains a Tether-owned manifest plus signed guest artifacts.
public struct NativeVirtualMachineStore: VirtualMachineReading, Sendable {
    public static let manifestFilename = "manifest.json"

    private let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func list() async throws -> [VirtualMachineRecord] {
        guard AppleVirtualizationSupport.isAvailable else {
            throw NativeVirtualMachineStoreError.unsupportedHost
        }
        let fileManager = FileManager.default
        guard rootURL.isFileURL else { throw NativeVirtualMachineStoreError.invalidRoot }
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }

        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var records: [VirtualMachineRecord] = []
        for bundleURL in children {
            let values = try bundleURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw NativeVirtualMachineStoreError.symbolicLinkNotAllowed(bundleURL.lastPathComponent)
            }
            guard values.isDirectory == true,
                  let directoryID = VirtualMachineID(bundleURL.lastPathComponent) else {
                throw NativeVirtualMachineStoreError.invalidBundleName(bundleURL.lastPathComponent)
            }

            let manifestURL = bundleURL.appendingPathComponent(Self.manifestFilename, isDirectory: false)
            let manifestValues = try manifestURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard manifestValues.isSymbolicLink != true else {
                throw NativeVirtualMachineStoreError.symbolicLinkNotAllowed(manifestURL.lastPathComponent)
            }
            let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let manifest = try? decoder.decode(NativeVirtualMachineManifest.self, from: data) else {
                throw NativeVirtualMachineStoreError.malformedManifest(bundleURL.lastPathComponent)
            }
            guard manifest.schemaVersion == NativeVirtualMachineManifest.currentSchemaVersion else {
                throw NativeVirtualMachineStoreError.unsupportedSchema(manifest.schemaVersion)
            }
            guard manifest.id == directoryID else {
                throw NativeVirtualMachineStoreError.identityMismatch
            }
            records.append(VirtualMachineRecord(id: manifest.id, name: manifest.name, state: .stopped))
        }

        if let duplicate = Dictionary(grouping: records, by: \.id).first(where: { $0.value.count > 1 })?.key {
            throw NativeVirtualMachineStoreError.duplicateID(duplicate)
        }
        let nameCounts = Dictionary(grouping: records) {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }.mapValues(\.count)
        return records.map { record in
            let key = record.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard nameCounts[key, default: 0] > 1 else { return record }
            return VirtualMachineRecord(
                id: record.id,
                name: "\(record.name) · \(record.id.description.prefix(8))",
                state: record.state
            )
        }
    }

    public func status(of id: VirtualMachineID) async throws -> VirtualMachineState {
        let records = try await list()
        return records.first(where: { $0.id == id })?.state ?? .unavailable
    }

    public func createBundle(for manifest: NativeVirtualMachineManifest) throws -> URL {
        guard AppleVirtualizationSupport.isAvailable else {
            throw NativeVirtualMachineStoreError.unsupportedHost
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let bundleURL = rootURL.appendingPathComponent(manifest.id.description, isDirectory: true)
        guard !fileManager.fileExists(atPath: bundleURL.path) else {
            throw NativeVirtualMachineStoreError.duplicateID(manifest.id)
        }
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: false)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(manifest)
            try data.write(
                to: bundleURL.appendingPathComponent(Self.manifestFilename),
                options: [.atomic, .completeFileProtection]
            )
            return bundleURL
        } catch {
            try? fileManager.removeItem(at: bundleURL)
            throw error
        }
    }
}
