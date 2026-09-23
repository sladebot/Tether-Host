import Foundation
import Darwin

public enum UTMApplePackageError: LocalizedError {
    case invalidNativeVM
    case packageAlreadyExists
    case cloneUnavailable
    case missingGuestSetupDisk

    public var errorDescription: String? {
        switch self {
        case .invalidNativeVM: "The installed Apple VM is incomplete; its UTM package was not created."
        case .packageAlreadyExists: "A UTM package with this exact VM identity already exists."
        case .cloneUnavailable: "The VM disk could not be copied into the UTM package. Check free space in Application Support; the original Apple VM is safe."
        case .missingGuestSetupDisk: "The Tether guest setup disk is missing; the UTM package was not created."
        }
    }
}

/// Converts a stopped Tether-created macOS VM into UTM 4.7's Apple backend
/// package. APFS cloning keeps the original intact until UTM confirms it has
/// registered the package; the two writable disks are never used concurrently.
public enum UTMApplePackageWriter {
    public static func createPackage(nativeBundle: URL, guestSetupISO: URL, in root: URL) throws -> URL {
        let manifestURL = nativeBundle.appendingPathComponent(NativeVirtualMachineStore.manifestFilename)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? decoder.decode(NativeVirtualMachineManifest.self, from: manifestData),
              nativeBundle.lastPathComponent == manifest.id.description,
              manifest.schemaVersion == NativeVirtualMachineManifest.currentSchemaVersion,
              let hardware = try? Data(contentsOf: nativeBundle.appendingPathComponent("hardware.bin")),
              let machine = try? Data(contentsOf: nativeBundle.appendingPathComponent("machine.bin")),
              !hardware.isEmpty, !machine.isEmpty else { throw UTMApplePackageError.invalidNativeVM }
        if let resources = manifest.resources {
            guard (2...64).contains(resources.cpuCount),
                  (4...512).contains(resources.memoryGiB),
                  (24...1024).contains(resources.diskGiB) else {
                throw UTMApplePackageError.invalidNativeVM
            }
        }

        let files = ["disk.img", "auxiliary.img"]
        for file in files {
            let values = try? nativeBundle.appendingPathComponent(file)
                .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                throw UTMApplePackageError.invalidNativeVM
            }
        }
        let guestDiskValues = try? guestSetupISO.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard guestSetupISO.isFileURL, guestSetupISO.pathExtension.lowercased() == "iso",
              guestDiskValues?.isRegularFile == true,
              guestDiskValues?.isSymbolicLink != true else {
            throw UTMApplePackageError.missingGuestSetupDisk
        }

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("\(manifest.id.description).utm", isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw UTMApplePackageError.packageAlreadyExists }
        let stage = root.appendingPathComponent(".creating-\(manifest.id.description).utm", isDirectory: true)
        guard !fm.fileExists(atPath: stage.path) else { throw UTMApplePackageError.packageAlreadyExists }
        let dataDirectory = stage.appendingPathComponent("Data", isDirectory: true)
        let driveID = UUID().uuidString
        do {
            try fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            try clone(nativeBundle.appendingPathComponent("disk.img"),
                      to: dataDirectory.appendingPathComponent("\(driveID).img"))
            try clone(nativeBundle.appendingPathComponent("auxiliary.img"),
                      to: dataDirectory.appendingPathComponent("AuxiliaryStorage"))
            let guestDiskName = "Tether Guest Setup.iso"
            try fm.copyItem(at: guestSetupISO, to: dataDirectory.appendingPathComponent(guestDiskName))
            let guestDriveID = UUID().uuidString
            let config: [String: Any] = [
                "Backend": "Apple",
                "ConfigurationVersion": 4,
                "Information": ["Name": manifest.name, "UUID": manifest.id.description,
                                "Icon": "mac", "IconCustom": false],
                "System": [
                    "Architecture": "aarch64", "Boot": ["OperatingSystem": "macOS", "UEFIBoot": false],
                    "CPUCount": manifest.resources?.cpuCount ?? 4,
                    "MemorySize": (manifest.resources?.memoryGiB ?? 8) * 1024,
                    "MacPlatform": ["AuxiliaryStoragePath": "AuxiliaryStorage",
                                    "HardwareModel": hardware, "MachineIdentifier": machine]
                ],
                "Virtualization": ["Audio": true, "Balloon": true,
                                   "ClipboardSharing": false, "Entropy": true,
                                   "Keyboard": "Mac", "Pointer": "Trackpad"],
                "Display": [["DynamicResolution": true, "HeightPixels": 1000,
                             "PixelsPerInch": 144, "WidthPixels": 1600]],
                "Drive": [
                    ["Identifier": driveID, "ImageName": "\(driveID).img",
                     "Nvme": false, "ReadOnly": false],
                    ["Identifier": guestDriveID, "ImageName": guestDiskName,
                     "Nvme": false, "ReadOnly": true]
                ],
                "Network": [["MacAddress": randomMACAddress(), "Mode": "Shared"]],
                "Serial": []
            ]
            let plist = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
            try plist.write(to: stage.appendingPathComponent("config.plist"), options: .atomic)
            try fm.moveItem(at: stage, to: destination)
            return destination
        } catch {
            try? fm.removeItem(at: stage)
            throw error
        }
    }

    private static func clone(_ source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        // clonefile requires one filesystem. An external VM may need an actual
        // copy into the local UTM package; the source remains untouched until
        // UTM confirms registration.
        guard errno == EXDEV else { throw UTMApplePackageError.cloneUnavailable }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw UTMApplePackageError.cloneUnavailable
        }
    }

    private static func randomMACAddress() -> String {
        let bytes = (0..<5).map { _ in UInt8.random(in: 0...255) }
        return ([UInt8(0x02)] + bytes).map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
