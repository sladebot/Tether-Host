import Foundation
import CryptoKit
import Darwin

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
                               "01 Check Internet.command", "02 Set up Tailscale.command",
                               "03 Install Hermes.command", "04 Configure Hermes.command",
                               "05 Enable Computer Use.command", "06 Verify Connection.command",
                               "app.tether.keep-awake.plist", "guest_setup.py", "components.json",
                               "terminal.html", "xterm.js", "xterm.css", "LICENSE",
                               "Tether Guest Clipboard Helper", "install-clipboard-helper.sh",
                               "app.tether.guest-clipboard.plist"]
            guard manager.isExecutableFile(atPath: executable.path),
                  helperFiles.allSatisfy({ manager.fileExists(atPath: resources.appendingPathComponent($0).path) }) else {
                throw GuestSetupDiskError.missingGuestHelper
            }
            let fingerprint = try contentFingerprint(installer)
            let receipt = destinationURL.appendingPathExtension("sha256")
            if isUsableImage(at: destinationURL),
               (try? String(contentsOf: receipt, encoding: .utf8)) == fingerprint {
                return
            }
            try manager.copyItem(at: installer, to: staging.appendingPathComponent(installer.lastPathComponent))
            // Keep the guest helper independent of the host app and free of
            // transfer-only metadata on the mounted image.
            try runUtility(URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-cr", staging.path], timeout: 30)
            let instructions = """
            Tether Guest Setup

            1. Finish macOS account setup and reach the desktop.
            2. Double-click Tether Guest Installer.app on this disk.
            3. Follow the six steps shown in the guest installer.
            4. Complete sign-in and permission prompts in the VM when asked.
               Existing Tailscale and Hermes installations are reused.

            Install Tether Host for Mac only on the physical Mac. This disk
            carries a small guest helper, not a second copy of the host app.

            Run this only inside the macOS virtual machine.
            """
            try Data(instructions.utf8).write(
                to: staging.appendingPathComponent("Read Me.txt"),
                options: [.atomic]
            )
            try replaceImage(at: destinationURL) { temporary in
                try runUtility(utility, arguments: [
                    "makehybrid", "-iso", "-joliet",
                    "-iso-volume-name", "TETHERGUEST",
                    "-joliet-volume-name", "Tether Guest Setup",
                    "-o", temporary.path, staging.path
                ], timeout: 180)
            }
            // A failed receipt write simply forces regeneration next time.
            try? Data(fingerprint.utf8).write(to: receipt, options: .atomic)
        }.value
    }

    /// Validate the ISO-9660 PVD (ECMA-119 §8.4) and its declared volume bounds.
    /// This detects incomplete media; it is not a filesystem integrity or authenticity check.
    public static func isUsableImage(at url: URL) -> Bool {
        guard let metadata = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              metadata.isRegularFile == true, metadata.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            let physicalSize = try handle.seekToEnd()
            try handle.seek(toOffset: 32_768)
            guard let pvd = try handle.read(upToCount: 2048), pvd.count == 2048,
                  pvd.prefix(7) == Data([1, 67, 68, 48, 48, 49, 1]),
                  pvd[7] == 0, pvd[881] == 1 else { return false }
            func bothEndian(_ offset: Int, width: Int) -> UInt64? {
                var little: UInt64 = 0
                var big: UInt64 = 0
                for index in 0..<width {
                    little |= UInt64(pvd[offset + index]) << (index * 8)
                    big = (big << 8) | UInt64(pvd[offset + width + index])
                }
                return little == big ? little : nil
            }
            guard let blocks = bothEndian(80, width: 4), blocks >= 18,
                  let blockSize = bothEndian(128, width: 2), blockSize == 2048,
                  blocks * blockSize <= physicalSize,
                  let volumeSet = bothEndian(120, width: 2), volumeSet > 0,
                  let sequence = bothEndian(124, width: 2), sequence > 0, sequence <= volumeSet,
                  pvd[156] == 34,
                  let rootExtent = bothEndian(158, width: 4), rootExtent >= 18,
                  let rootLength = bothEndian(166, width: 4), rootLength > 0,
                  rootExtent * blockSize + rootLength <= blocks * blockSize else { return false }
            return true
        } catch { return false }
    }

    /// Build beside the destination so POSIX rename atomically replaces it on the same volume.
    /// The old image remains intact for every failure before the final rename.
    static func replaceImage(at destination: URL, build: (URL) throws -> Void) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".guest-setup-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try build(temporary)
        guard isUsableImage(at: temporary) else {
            throw GuestSetupDiskError.creationFailed("The generated ISO is incomplete.")
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func contentFingerprint(_ root: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey], options: []) else {
            throw GuestSetupDiskError.missingGuestHelper
        }
        var files: [URL] = []
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files.append(file) }
        }
        var hash = SHA256()
        // Bump when packaging instructions or format change independently of installer content.
        hash.update(data: Data("tether-guest-iso-v2".utf8))
        for file in files.sorted(by: { $0.path < $1.path }) {
            hash.update(data: Data(file.path.dropFirst(root.path.count).utf8))
            hash.update(data: Data([0]))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Drain stderr while the utility runs, retaining only a bounded diagnostic prefix.
    static func runUtility(_ executable: URL, arguments: [String], timeout: TimeInterval) throws {
        let process = Process()
        let pipe = Pipe()
        let output = BoundedUtilityOutput()
        let drained = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? pipe.fileHandleForReading.close()
                drained.signal()
            }
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            let deadline = Date().addingTimeInterval(timeout + 4)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while Date() < deadline {
                var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&event, 1, 100)
                if ready == 0 { continue }
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count <= 0 { break }
                output.append(Data(buffer.prefix(count)))
            }
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            throw GuestSetupDiskError.creationFailed("The disk utility timed out.")
        }
        _ = drained.wait(timeout: .now() + 2)
        guard process.terminationStatus == 0 else {
            let message = output.message
            throw GuestSetupDiskError.creationFailed(message.isEmpty
                ? "Utility exited with status \(process.terminationStatus)." : message)
        }
    }
}

private final class BoundedUtilityOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(data.prefix(max(0, 2048 - bytes.count)))
    }
    var message: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
