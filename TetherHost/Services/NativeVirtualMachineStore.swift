import Foundation
#if canImport(Virtualization)
import Virtualization
#endif

public enum NativeGuestOS: String, Codable, Sendable {
    case macOS
    case debian
}

/// Free space needed on the volume that will hold a new VM. Filesystems without
/// sparse files can allocate the entire virtual disk as soon as it is created.
public enum NativeVMStorageCapacity {
    public static let bytesPerGiB: Int64 = 1_073_741_824

    public static func requiredFreeGiB(diskGiB: Int, guestOS: NativeGuestOS,
                                       supportsSparseFiles: Bool) -> Int {
        if !supportsSparseFiles { return diskGiB + 4 }
        return guestOS == .debian ? 12 : min(diskGiB + 4, 45)
    }

    public static func availableBytes(at folder: URL) throws -> Int64 {
        let values = try folder.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
        ])
        // FSKit volumes such as exFAT may report zero for Important Usage even
        // though ordinary available capacity is valid and nonzero.
        if let available = effectiveAvailableBytes(
            important: values.volumeAvailableCapacityForImportantUsage,
            ordinary: values.volumeAvailableCapacity
        ) { return available }
        return (try FileManager.default.attributesOfFileSystem(forPath: folder.path)[.systemFreeSize]
            as? NSNumber)?.int64Value ?? 0
    }

    public static func effectiveAvailableBytes(important: Int64?, ordinary: Int?) -> Int64? {
        if let important, important > 0 { return important }
        if let ordinary { return Int64(ordinary) }
        return nil
    }
}

public struct NativeVirtualMachineManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: VirtualMachineID
    public let name: String
    public let guestImageVersion: String
    /// Missing in older manifests, which always represent macOS guests.
    public let guestOS: NativeGuestOS
    public let createdAt: Date
    /// Absent in VMs created before resource selection was added.
    public let resources: NativeVMResources?

    public init(
        id: VirtualMachineID,
        name: String = "Tether Sandbox",
        guestImageVersion: String,
        createdAt: Date = Date(),
        resources: NativeVMResources? = nil,
        guestOS: NativeGuestOS = .macOS
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.guestImageVersion = guestImageVersion
        self.guestOS = guestOS
        self.createdAt = createdAt
        self.resources = resources
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, guestImageVersion, guestOS, createdAt, resources
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(VirtualMachineID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        guestImageVersion = try container.decode(String.self, forKey: .guestImageVersion)
        guestOS = try container.decodeIfPresent(NativeGuestOS.self, forKey: .guestOS) ?? .macOS
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        resources = try container.decodeIfPresent(NativeVMResources.self, forKey: .resources)
    }
}

public struct NativeVMResources: Codable, Equatable, Sendable {
    public let cpuCount: Int
    public let memoryGiB: Int
    public let diskGiB: Int

    public init(cpuCount: Int, memoryGiB: Int, diskGiB: Int) {
        self.cpuCount = cpuCount
        self.memoryGiB = memoryGiB
        self.diskGiB = diskGiB
    }
}

/// UI bounds and final validation for new Apple silicon VMs. The selected
/// filesystem determines whether a disk image can grow sparsely.
public struct NativeVMResourceLimits: Sendable {
    public let cpu: ClosedRange<Int>
    public let memoryGiB: ClosedRange<Int>
    public let diskGiB: ClosedRange<Int>
    public let hostCapabilityError: String?

    public init(
        hostCPUCount: Int, hostMemoryBytes: UInt64,
        minimumCPUCount: Int = 2, minimumMemoryBytes: UInt64 = 4 * 1_073_741_824,
        maximumCPUCount: Int = 64, maximumMemoryBytes: UInt64 = 512 * 1_073_741_824
    ) {
        let gib: UInt64 = 1_073_741_824
        let cpuMinimum = max(2, minimumCPUCount)
        let memoryMinimum = max(4, Int((minimumMemoryBytes + gib - 1) / gib))
        // Keep at least 4 GiB for the host where possible. The remaining bound
        // is advisory; VZ's own maximum is also applied by the caller.
        let hostMemoryLimit = Int(hostMemoryBytes > 4 * gib ? (hostMemoryBytes - 4 * gib) / gib : 0)
        let cpuMaximum = min(hostCPUCount, maximumCPUCount)
        let memoryMaximum = min(hostMemoryLimit, Int(maximumMemoryBytes / gib))
        cpu = cpuMinimum...max(cpuMinimum, cpuMaximum)
        memoryGiB = memoryMinimum...max(memoryMinimum, memoryMaximum)
        diskGiB = 24...1024
        if cpuMaximum < cpuMinimum {
            hostCapabilityError = "This guest image needs at least \(cpuMinimum) CPU cores; this Mac can provide \(max(0, cpuMaximum))."
        } else if memoryMaximum < memoryMinimum {
            hostCapabilityError = "This guest image needs at least \(memoryMinimum) GB of VM memory; this Mac has only \(max(0, memoryMaximum)) GB available after reserving memory for macOS."
        } else {
            hostCapabilityError = nil
        }
    }

    public var defaults: NativeVMResources {
        NativeVMResources(
            cpuCount: min(cpu.upperBound, max(cpu.lowerBound, 4)),
            memoryGiB: min(memoryGiB.upperBound, max(memoryGiB.lowerBound, 8)),
            diskGiB: 128
        )
    }

    public func validationMessage(for resources: NativeVMResources) -> String? {
        if let hostCapabilityError { return hostCapabilityError }
        if !cpu.contains(resources.cpuCount) {
            return "CPU must be between \(cpu.lowerBound) and \(cpu.upperBound) cores."
        }
        if !memoryGiB.contains(resources.memoryGiB) {
            return "Memory must be between \(memoryGiB.lowerBound) and \(memoryGiB.upperBound) GB."
        }
        if !diskGiB.contains(resources.diskGiB) {
            return "Disk capacity must be between \(diskGiB.lowerBound) and \(diskGiB.upperBound) GB."
        }
        return nil
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

/// Remembers complete VM bundles created outside the default VM directory. The
/// bookmark follows a renamed or remounted volume; the saved path is used only
/// to explain where an unavailable VM was last seen.
public struct NativeVMStorageRegistry: Sendable {
    private struct Entry: Codable {
        let id: VirtualMachineID
        let name: String
        let bookmark: Data
        let lastPath: String
        let volumeIdentity: String
        let provider: VMProvider?
        var resolvedProvider: VMProvider { provider ?? .builtIn }
    }

    public let defaultRootURL: URL
    private var fileURL: URL {
        defaultRootURL.deletingLastPathComponent().appendingPathComponent("external-vms.json")
    }

    public init(defaultRootURL: URL) {
        self.defaultRootURL = defaultRootURL.standardizedFileURL
    }

    private func entries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: fileURL))
    }

    private func save(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
    }

    public func register(_ manifest: NativeVirtualMachineManifest, at bundleURL: URL) throws {
        let bundle = bundleURL.standardizedFileURL
        guard bundle.lastPathComponent == manifest.id.description else {
            throw NativeVirtualMachineStoreError.identityMismatch
        }
        guard bundle.deletingLastPathComponent() != defaultRootURL else { return }
        let folder = bundle.deletingLastPathComponent()
        let bookmark = try folder.bookmarkData()
        let volumeIdentity = try Self.volumeIdentity(at: folder)
        var saved = try entries().filter { $0.id != manifest.id || $0.resolvedProvider != .builtIn }
        saved.append(Entry(id: manifest.id, name: manifest.name, bookmark: bookmark,
                           lastPath: folder.path, volumeIdentity: volumeIdentity, provider: .builtIn))
        try save(saved)
    }

    public func registerUTM(id: VirtualMachineID, name: String, at packageURL: URL) throws {
        let package = packageURL.standardizedFileURL
        guard package.lastPathComponent == "\(id.description).utm" else {
            throw NativeVirtualMachineStoreError.identityMismatch
        }
        let folder = package.deletingLastPathComponent()
        let bookmark = try folder.bookmarkData()
        let volumeIdentity = try Self.volumeIdentity(at: folder)
        var saved = try entries().filter { $0.id != id || $0.resolvedProvider != .utm }
        saved.append(Entry(id: id, name: name, bookmark: bookmark, lastPath: folder.path,
                           volumeIdentity: volumeIdentity, provider: .utm))
        try save(saved)
    }

    public func unregister(_ id: VirtualMachineID, provider: VMProvider = .builtIn) throws {
        let saved = try entries()
        guard saved.contains(where: { $0.id == id && $0.resolvedProvider == provider }) else { return }
        try save(saved.filter { $0.id != id || $0.resolvedProvider != provider })
    }

    public func knownExternalVMs() throws -> [(id: VirtualMachineID, name: String, bundle: URL?)] {
        try entries().filter { $0.resolvedProvider == .builtIn }.map { entry in
            (entry.id, entry.name, resolvedBundle(for: entry))
        }
    }

    public func location(of id: VirtualMachineID, provider: VMProvider = .builtIn) -> URL? {
        guard let entry = try? entries().first(where: { $0.id == id && $0.resolvedProvider == provider }) else { return nil }
        return resolvedBundle(for: entry)
    }

    private func resolvedBundle(for entry: Entry) -> URL? {
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: entry.bookmark,
                                    options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
              (try? Self.volumeIdentity(at: folder)) == entry.volumeIdentity else { return nil }
        let name = entry.resolvedProvider == .utm ? "\(entry.id.description).utm" : entry.id.description
        return folder.appendingPathComponent(name, isDirectory: true)
    }

    public static func volumeIdentity(at folder: URL) throws -> String {
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                          .volumeUUIDStringKey, .volumeIdentifierKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw NativeVirtualMachineStoreError.invalidRoot
        }
        if let uuid = values.volumeUUIDString { return uuid }
        guard let identifier = values.volumeIdentifier else {
            throw NativeVirtualMachineStoreError.invalidRoot
        }
        return String(describing: identifier)
    }

    public func lastKnownLocation(of id: VirtualMachineID, provider: VMProvider = .builtIn) -> String? {
        try? entries().first(where: { $0.id == id && $0.resolvedProvider == provider })?.lastPath
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
        let registry = NativeVMStorageRegistry(defaultRootURL: rootURL)
        let children = fileManager.fileExists(atPath: rootURL.path) ? try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent } : []

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

        let locator = VirtualMachineBundleLocator(nativeRoot: rootURL, utmRoots: [])
        for external in try registry.knownExternalVMs() {
            guard !records.contains(where: { $0.id == external.id }) else {
                throw NativeVirtualMachineStoreError.duplicateID(external.id)
            }
            let available = locator.locate(external.id, provider: .builtIn) != nil
            records.append(VirtualMachineRecord(id: external.id, name: external.name,
                                                state: available ? .stopped : .unavailable))
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
