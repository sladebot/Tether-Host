import Foundation

public enum GuestSetupDiskError: Error, LocalizedError, Sendable {
    case invalidApplication
    case missingGuestHelper
    case invalidDestination
    case missingDiskUtility
    case creationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidApplication:
            "The running Tether Host application bundle could not be packaged."
        case .missingGuestHelper:
            "The guest setup helper is missing from the Tether Host application bundle."
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
            let guestResources = appURL.appendingPathComponent("Contents/Resources/GuestSetup", isDirectory: true)
            let installer = guestResources.appendingPathComponent("Tether Guest Installer.app", isDirectory: true)
            let executable = installer.appendingPathComponent("Contents/MacOS/Tether Guest Installer")
            let resources = installer.appendingPathComponent("Contents/Resources", isDirectory: true)
            let helperFiles = ["Set up Tether Guest.command", "Keep Tether VM Awake.command",
                               "app.tether.keep-awake.plist", "guest_setup.py", "components.json"]
            guard manager.isExecutableFile(atPath: executable.path),
                  helperFiles.allSatisfy({ manager.fileExists(atPath: resources.appendingPathComponent($0).path) }) else {
                throw GuestSetupDiskError.missingGuestHelper
            }
            try manager.copyItem(at: installer, to: staging.appendingPathComponent(installer.lastPathComponent))
            // Keep the guest helper independent of the host app and free of
            // transfer-only metadata on the mounted image.
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-cr", staging.path]
            xattr.standardOutput = FileHandle.nullDevice
            xattr.standardError = FileHandle.nullDevice
            try xattr.run()
            xattr.waitUntilExit()
            guard xattr.terminationStatus == 0 else {
                throw GuestSetupDiskError.creationFailed("Could not remove transfer-only file metadata.")
            }
            let instructions = """
            Tether Guest Setup

            1. Finish macOS account setup and reach the desktop.
            2. Double-click Tether Guest Installer.app on this disk.
            3. Click Start setup and follow the prompts in Terminal.
            4. Approve Tailscale, Hermes, model login, and guest permissions.

            Install Tether Host for Mac only on the physical Mac. This disk
            carries a small guest helper, not a second copy of the host app.

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
