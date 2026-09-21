import Foundation

public enum GuestSetupDiskError: Error, LocalizedError, Sendable {
    case invalidApplication
    case invalidDestination
    case missingDiskUtility
    case creationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidApplication:
            "The running Tether Host application bundle could not be packaged."
        case .invalidDestination:
            "Choose a local filename ending in .iso."
        case .missingDiskUtility:
            "The macOS disk-image utility is unavailable."
        case .creationFailed(let message):
            "Guest setup disk creation failed: \(message)"
        }
    }
}

public enum GuestSetupDiskExporter {
    public static func export(appURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            guard appURL.isFileURL,
                  appURL.pathExtension == "app",
                  manager.fileExists(atPath: appURL.path) else {
                throw GuestSetupDiskError.invalidApplication
            }
            guard destinationURL.isFileURL,
                  destinationURL.pathExtension.lowercased() == "iso" else {
                throw GuestSetupDiskError.invalidDestination
            }
            let utility = URL(fileURLWithPath: "/usr/bin/hdiutil")
            guard manager.isExecutableFile(atPath: utility.path) else {
                throw GuestSetupDiskError.missingDiskUtility
            }

            let staging = manager.temporaryDirectory
                .appendingPathComponent("tether-guest-setup-\(UUID().uuidString)", isDirectory: true)
            defer { try? manager.removeItem(at: staging) }
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            let stagedApp = staging.appendingPathComponent("Tether Host for Mac.app", isDirectory: true)
            try manager.copyItem(at: appURL, to: stagedApp)
            // HFS metadata on hybrid images can add FinderInfo to signed Mach-O
            // files and invalidate their resource envelope after guest transfer.
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-cr", stagedApp.path]
            xattr.standardOutput = FileHandle.nullDevice
            xattr.standardError = FileHandle.nullDevice
            try xattr.run()
            xattr.waitUntilExit()
            guard xattr.terminationStatus == 0 else {
                throw GuestSetupDiskError.creationFailed("Could not remove transfer-only file metadata.")
            }
            let instructions = """
            Tether Guest Setup

            1. Copy Tether Host for Mac to this VM's Applications folder.
            2. Open the copied app.
            3. Choose Setup Assistant, then Run Guest Setup.
            4. Configure Tailscale inside this VM when prompted.
            5. Configure Hermes, model login, and guest permissions.

            Run this only inside the macOS virtual machine.
            """
            try Data(instructions.utf8).write(
                to: staging.appendingPathComponent("Read Me.txt"),
                options: [.atomic]
            )
            if manager.fileExists(atPath: destinationURL.path) {
                try manager.removeItem(at: destinationURL)
            }

            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = utility
            process.arguments = [
                "makehybrid", "-iso", "-joliet",
                "-iso-volume-name", "TETHERGUEST",
                "-joliet-volume-name", "Tether Guest Setup",
                "-o", destinationURL.path, staging.path
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  manager.fileExists(atPath: destinationURL.path) else {
                let bytes = errorPipe.fileHandleForReading.readDataToEndOfFile().prefix(2_048)
                let message = String(decoding: bytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw GuestSetupDiskError.creationFailed(
                    message.isEmpty ? "hdiutil exited with status \(process.terminationStatus)." : message
                )
            }
        }.value
    }
}
