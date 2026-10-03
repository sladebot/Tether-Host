import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftUI
import Virtualization
import TetherHostCore

enum NativeVMError: LocalizedError {
    case unsupportedImage
    case newerGuestRequiresHostUpdate(guest: Int, host: Int)
    case insufficientSpace
    case insufficientDownloadSpace
    case missingVM
    case invalidVM
    case anotherVMRunning
    case anotherHostCopyRunning
    case operationInProgress
    case cannotRemoveRunningVM
    case cannotRemoveDuringInstall
    case cannotRemoveWithOtherHostCopy

    var errorDescription: String? {
        switch self {
        case .unsupportedImage: "This macOS IPSW is not compatible with this Mac's virtualization hardware. Choose another IPSW."
        case .newerGuestRequiresHostUpdate(let guest, let host):
            "This is a macOS \(guest) IPSW, but this Mac runs macOS \(host). Apple's installer requires a host software update. Choose a macOS \(host) IPSW or update this Mac first."
        case .insufficientSpace: "At least 45 GB of free disk space is needed to install a fresh macOS VM."
        case .insufficientDownloadSpace: "At least 65 GB of free disk space is needed to download macOS and install a fresh VM."
        case .missingVM: "The selected Tether VM is missing. Refresh the VM list."
        case .invalidVM: "The Tether VM is incomplete or damaged. Create a new VM from an IPSW."
        case .anotherVMRunning: "Another Tether VM is already running. Shut it down before starting this one."
        case .anotherHostCopyRunning: "Another Tether Host for Mac copy is open. Quit it before starting this VM."
        case .operationInProgress: "Wait for the current VM operation to finish."
        case .cannotRemoveRunningVM: "Shut down the built-in VM before deleting its files."
        case .cannotRemoveDuringInstall: "Wait for VM installation or setup to finish before deleting a VM."
        case .cannotRemoveWithOtherHostCopy: "Quit the other Tether Host copy before deleting this VM."
        }
    }
}

enum GuestClipboardError: LocalizedError {
    case vmNotRunning
    case serviceUnavailable
    case textTooLarge
    case invalidResponse
    case timedOut
    case disconnected
    case guestRejected(String)

    var errorDescription: String? {
        switch self {
        case .vmNotRunning: "Start the built-in VM before transferring clipboard text."
        case .serviceUnavailable: "Open Tether Guest Installer in the VM and click Text clipboard (built-in)."
        case .textTooLarge: "Clipboard text must be 64 KB or smaller."
        case .invalidResponse: "The VM sent an invalid clipboard response. Reopen Tether Guest Installer and enable the built-in VM text clipboard again."
        case .timedOut: "Clipboard transfer timed out. Check that the VM and Tether Guest Installer are responsive."
        case .disconnected: "The clipboard connection to the VM closed unexpectedly."
        case .guestRejected(let message): "The VM could not transfer clipboard text: \(message)"
        }
    }
}

private final class RestoreImageDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let stagedURL: URL
    private let startedAt = Date()
    private let onProgress: @Sendable (Int64, Int64, TimeInterval) -> Void
    private var session: URLSession?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var result: Result<URL, Error>?

    init(stagedURL: URL, onProgress: @escaping @Sendable (Int64, Int64, TimeInterval) -> Void) {
        self.stagedURL = stagedURL
        self.onProgress = onProgress
    }

    func run(from url: URL) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite,
                   Date().timeIntervalSince(startedAt))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        result = Result { try FileManager.default.moveItem(at: location, to: stagedURL); return stagedURL }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate(); self.session = nil }
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else if let result, let response = task.response {
            continuation.resume(with: result.map { ($0, response) })
        } else {
            continuation.resume(throwing: URLError(.cannotCreateFile))
        }
    }
}

@MainActor
final class NativeVMManager: ObservableObject {
    private static let macOS262URL = URL(string: "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-37399/E144C918-CF99-4BBC-B1D0-3E739B9A3F2D/UniversalMac_26.2_25C56_Restore.ipsw")!
    private static let macOS262SHA256 = "bc7c67b2a2cc4ac8c9da0c2b149b9f31e153cd542ce387e6fb8620e41b5278ef"
    private static let networkEnabledKey = "nativeVM.networkEnabled"
    private static let selectedImageKey = "restoreImage.lastSelectedPath"

    static var canDownloadHostImage: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion == 26 && version.minorVersion == 2
    }

    @Published private(set) var imageURL: URL?
    @Published private(set) var imageDescription = "Choose a macOS IPSW to create a fresh VM."
    @Published private(set) var status = "No VM installation has started."
    @Published private(set) var operationState = NativeVMOperationState()
    var isBusy: Bool { operationState.isBusy }
    @Published private(set) var installationProgress: Double?
    @Published private(set) var downloadProgress: DownloadProgressEstimate?
    @Published private(set) var isRunning = false
    @Published private(set) var shutdownRequested = false
    @Published private(set) var virtualMachine: VZVirtualMachine?
    @Published private(set) var desktopReadyVMID: VirtualMachineID?
    @Published var showsDisplay = false
    @Published var networkEnabled = true {
        didSet { preferences.set(networkEnabled, forKey: Self.networkEnabledKey) }
    }
    var networkStatus: String {
        networkEnabled
            ? "Shared internet (NAT). Guest access to the host and local network is not blocked."
            : "Offline. The VM has no network device; Tailscale and internet access are unavailable."
    }

    private var restoreImage: VZMacOSRestoreImage?
    private var activeDownloadID: UUID?
    private var runningID: VirtualMachineID?
    var runningVMID: VirtualMachineID? { isRunning ? runningID : nil }
    private let otherHostCopyRunning: @MainActor () -> Bool
    private let rootURL: URL
    private let guestDiskExporter: @Sendable (URL) async throws -> Void
    private let vmDelegate = NativeVMDelegate()
    private let preferences: UserDefaults

    init(
        preferences: UserDefaults = .standard,
        rootURL: URL? = nil,
        otherHostCopyRunning: @escaping @MainActor () -> Bool = {
            NSRunningApplication.runningApplications(withBundleIdentifier: "app.tether.host")
                .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        },
        guestDiskExporter: @escaping @Sendable (URL) async throws -> Void = { destination in
            try await GuestSetupDiskExporter.export(appURL: Bundle.main.bundleURL, to: destination)
        }
    ) {
        self.preferences = preferences
        self.otherHostCopyRunning = otherHostCopyRunning
        networkEnabled = preferences.object(forKey: Self.networkEnabledKey) as? Bool ?? true
        desktopReadyVMID = preferences.string(forKey: "setup.nativeDesktopReadyVMID").flatMap(VirtualMachineID.init)
        self.guestDiskExporter = guestDiskExporter
        self.rootURL = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tether Host for Mac/Virtual Machines", isDirectory: true)
        vmDelegate.owner = self
        if let savedPath = preferences.string(forKey: Self.selectedImageKey) {
            let savedURL = URL(fileURLWithPath: savedPath)
            if FileManager.default.fileExists(atPath: savedPath) {
                imageDescription = "Checking previously selected image: \(savedURL.lastPathComponent)…"
                Task { await inspect(savedURL) }
            } else {
                preferences.removeObject(forKey: Self.selectedImageKey)
            }
        }
    }

    var cachedHostImageURL: URL {
        rootURL.deletingLastPathComponent()
            .appendingPathComponent("Restore Images/UniversalMac_26.2_25C56_Restore.ipsw")
    }

    var hasCachedHostImage: Bool {
        FileManager.default.fileExists(atPath: cachedHostImageURL.path)
    }

    func revealCachedHostImageInFinder() {
        guard hasCachedHostImage else { return }
        NSWorkspace.shared.activateFileViewerSelecting([cachedHostImageURL])
    }

    func revealSelectedImageInFinder() {
        guard let imageURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([imageURL])
    }

    func useCachedHostImage() async {
        guard !isBusy, hasCachedHostImage else { return }
        operationState.begin(.checkingImage)
        status = "Verifying the saved macOS image…"
        do {
            guard try await Self.sha256(of: cachedHostImageURL) == Self.macOS262SHA256 else {
                throw NativeVMError.unsupportedImage
            }
            operationState.finish()
            await inspect(cachedHostImageURL)
        } catch {
            operationState.finish()
            status = "Saved image could not be verified. Choose Download again to replace it. \(error.localizedDescription)"
        }
    }

    func isDesktopReady(for id: VirtualMachineID) -> Bool {
        desktopReadyVMID == id
    }

    func confirmDesktopReady() {
        guard isRunning, let runningID else { return }
        desktopReadyVMID = runningID
        preferences.set(runningID.description, forKey: "setup.nativeDesktopReadyVMID")
        status = "macOS desktop confirmed by you. Continue with the guest setup disk in the VM."
    }

    func confirmDesktopReadyFromGuestSetup() {
        guard isRunning, let runningID else { return }
        desktopReadyVMID = runningID
        preferences.set(runningID.description, forKey: "setup.nativeDesktopReadyVMID")
        status = "The verified guest installer is running in the macOS desktop session."
    }

    func clearDesktopReady(for id: VirtualMachineID) {
        guard desktopReadyVMID == id else { return }
        desktopReadyVMID = nil
        preferences.removeObject(forKey: "setup.nativeDesktopReadyVMID")
        status = "Finish the macOS welcome screens, then confirm when the desktop appears."
    }

    func chooseIPSW() {
        let panel = NSOpenPanel()
        panel.title = "Choose a macOS restore image"
        panel.message = "Tether Host will check compatibility before creating a fresh VM."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "ipsw")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await inspect(url) }
    }

    func inspect(_ url: URL) async {
        guard !isBusy else { return }
        operationState.begin(.checkingImage)
        status = "Checking the macOS image…"
        defer { operationState.finish() }
        do {
            let image = try await VZMacOSRestoreImage.image(from: url)
            guard image.isSupported, image.mostFeaturefulSupportedConfiguration != nil else {
                throw NativeVMError.unsupportedImage
            }
            let hostMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            let guestMajor = image.operatingSystemVersion.majorVersion
            guard guestMajor <= hostMajor else {
                throw NativeVMError.newerGuestRequiresHostUpdate(guest: guestMajor, host: hostMajor)
            }
            restoreImage = image
            imageURL = url
            preferences.set(url.path, forKey: Self.selectedImageKey)
            let version = image.operatingSystemVersion
            imageDescription = "macOS \(version.majorVersion).\(version.minorVersion) (\(image.buildVersion)) — compatible with this Mac"
            status = "Ready to create a new, separate Tether Host VM."
        } catch {
            restoreImage = nil
            imageURL = nil
            imageDescription = "No compatible macOS IPSW selected."
            status = error.localizedDescription
            if preferences.string(forKey: Self.selectedImageKey) == url.path {
                preferences.removeObject(forKey: Self.selectedImageKey)
            }
        }
    }

    func downloadHostImage() async {
        guard Self.canDownloadHostImage, !isBusy else { return }
        operationState.begin(.downloadingImage)
        downloadProgress = nil
        defer {
            activeDownloadID = nil
            downloadProgress = nil
        }
        status = "Downloading macOS 26.2 from Apple's servers (about 18 GB)…"
        let destination = cachedHostImageURL
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let available = try destination.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? 0
            guard available >= 65 * 1_073_741_824 else {
                throw NativeVMError.insufficientDownloadSpace
            }
            let staged = destination.deletingLastPathComponent()
                .appendingPathComponent(".download-\(UUID().uuidString).ipsw")
            defer { try? FileManager.default.removeItem(at: staged) }
            let downloadID = UUID()
            activeDownloadID = downloadID
            let downloader = RestoreImageDownload(stagedURL: staged) { [weak self] received, total, elapsed in
                Task { @MainActor [weak self] in
                    guard self?.activeDownloadID == downloadID else { return }
                    self?.downloadProgress = DownloadProgressEstimate(
                        receivedBytes: received, expectedBytes: total, elapsedSeconds: elapsed
                    )
                }
            }
            let (temporary, response) = try await downloader.run(from: Self.macOS262URL)
            activeDownloadID = nil
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  response.url?.host == "updates.cdn-apple.com" else {
                throw URLError(.badServerResponse)
            }
            downloadProgress = nil
            status = "Verifying the downloaded IPSW…"
            let digest = try await Self.sha256(of: temporary)
            guard digest == Self.macOS262SHA256 else { throw NativeVMError.unsupportedImage }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            operationState.finish()
            await inspect(destination)
        } catch {
            operationState.finish()
            status = "Could not download or verify macOS 26.2: \(error.localizedDescription)"
        }
    }

    private static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
                hasher.update(data: bytes)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    func install() async -> VirtualMachineID? {
        guard !isBusy, !isRunning, !shutdownRequested, let imageURL, let restoreImage,
              let requirements = restoreImage.mostFeaturefulSupportedConfiguration else { return nil }
        guard !hasOtherHostCopy else {
            status = NativeVMError.anotherHostCopyRunning.localizedDescription
            return nil
        }
        operationState.begin(.installing)
        defer { operationState.finish() }
        let id = VirtualMachineID(rawValue: UUID())
        let stage = rootURL.appendingPathComponent(".creating-\(id.description)", isDirectory: true)
        let destination = rootURL.appendingPathComponent(id.description, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let capacity = try rootURL
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? 0
            guard capacity >= 45 * 1_073_741_824 else { throw NativeVMError.insufficientSpace }
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            let hardware = requirements.hardwareModel
            let machineID = VZMacMachineIdentifier()
            try hardware.dataRepresentation.write(to: stage.appendingPathComponent("hardware.bin"), options: .atomic)
            try machineID.dataRepresentation.write(to: stage.appendingPathComponent("machine.bin"), options: .atomic)
            _ = try VZMacAuxiliaryStorage(
                creatingStorageAt: stage.appendingPathComponent("auxiliary.img"),
                hardwareModel: hardware,
                options: []
            )
            let diskURL = stage.appendingPathComponent("disk.img")
            FileManager.default.createFile(atPath: diskURL.path, contents: nil)
            let disk = try FileHandle(forWritingTo: diskURL)
            try disk.truncate(atOffset: 64 * 1_073_741_824)
            try disk.close()

            let configuration = try makeConfiguration(
                bundle: stage, hardware: hardware, machineID: machineID,
                cpuCount: max(requirements.minimumSupportedCPUCount, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)),
                memorySize: max(requirements.minimumSupportedMemorySize, 8 * 1_073_741_824),
                includeGuestDisk: false
            )
            let vm = VZVirtualMachine(configuration: configuration)
            virtualMachine = vm
            showsDisplay = true
            status = "Installing macOS from the selected IPSW. This can take a while; keep Tether Host open."
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: imageURL)
            let progressMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    self?.installationProgress = installer.progress.fractionCompleted
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer {
                progressMonitor.cancel()
                installationProgress = nil
            }
            try await installer.install()
            if vm.state == .running { try await vm.stop() }
            virtualMachine = nil
            showsDisplay = false

            let version = restoreImage.operatingSystemVersion
            let manifest = NativeVirtualMachineManifest(
                id: id, name: "Tether Host VM · \(id.description.prefix(8))",
                guestImageVersion: "\(version.majorVersion).\(version.minorVersion) (\(restoreImage.buildVersion))"
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(manifest).write(
                to: stage.appendingPathComponent(NativeVirtualMachineStore.manifestFilename), options: .atomic
            )
            try FileManager.default.moveItem(at: stage, to: destination)
            operationState.transition(from: .installing, to: .starting)
            status = "Starting the fresh VM…"
            try await bootWhileBusy(id)
            return id
        } catch {
            virtualMachine = nil
            showsDisplay = false
            try? FileManager.default.removeItem(at: stage)
            if FileManager.default.fileExists(atPath: destination.appendingPathComponent(NativeVirtualMachineStore.manifestFilename).path) {
                status = "macOS is installed, but the VM could not start: \(error.localizedDescription)"
                return id
            }
            status = "VM installation failed: \(error.localizedDescription)"
            return nil
        }
    }

    func boot(_ id: VirtualMachineID) async throws {
        guard !isBusy, !shutdownRequested else { throw NativeVMError.operationInProgress }
        operationState.begin(.starting)
        defer { operationState.finish() }
        try await bootWhileBusy(id)
    }

    /// The installation transaction deliberately retains its operation lock through boot.
    private func bootWhileBusy(_ id: VirtualMachineID) async throws {
        if isRunning, runningID == id { showsDisplay = true; return }
        if isRunning { throw NativeVMError.anotherVMRunning }
        guard !hasOtherHostCopy else { throw NativeVMError.anotherHostCopyRunning }
        let bundle = rootURL.appendingPathComponent(id.description, isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundle.path) else { throw NativeVMError.missingVM }
        let freshMedia = await prepareGuestDiskWhileBusy()
        let includeGuestDisk = GuestSetupDiskExporter.isUsableImage(at: guestDiskURL)
        let hardwareData = try Data(contentsOf: bundle.appendingPathComponent("hardware.bin"))
        let machineData = try Data(contentsOf: bundle.appendingPathComponent("machine.bin"))
        guard let hardware = VZMacHardwareModel(dataRepresentation: hardwareData),
              let machineID = VZMacMachineIdentifier(dataRepresentation: machineData),
              hardware.isSupported else { throw NativeVMError.invalidVM }
        let configuration = try makeConfiguration(
            bundle: bundle, hardware: hardware, machineID: machineID,
            cpuCount: min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)),
            memorySize: 8 * 1_073_741_824, includeGuestDisk: includeGuestDisk
        )
        let vm = VZVirtualMachine(configuration: configuration)
        vm.delegate = vmDelegate
        virtualMachine = vm
        do {
            try await vm.start()
            guard self.virtualMachine === vm, vm.state == .running else {
                throw NativeVMError.invalidVM
            }
            runningID = id
            isRunning = true
            shutdownRequested = false
            showsDisplay = true
            markBundleUsed(id)
            status = "Tether Host VM started. Finish the macOS welcome screens in this window."
            if !freshMedia {
                status += includeGuestDisk
                    ? " Using the previous guest setup disk because its update failed."
                    : " Guest setup disk unavailable; the VM started without it. Repair or reinstall Tether Host to restore the installer."
            }
        } catch {
            virtualMachine = nil
            showsDisplay = false
            status = "Could not boot the VM: \(error.localizedDescription)"
            throw error
        }
    }

    func startOrShow(_ id: VirtualMachineID) async {
        do { try await boot(id) }
        catch {
            status = "Could not start the VM: \(error.localizedDescription) If another Tether Host copy is open, quit it and try again."
        }
    }

    func requestShutdown() {
        guard isRunning, !isBusy, !shutdownRequested, let virtualMachine else { return }
        do {
            try virtualMachine.requestStop()
            shutdownRequested = true
            status = "Asked macOS to shut down. Wait for the VM status to change to Off."
        } catch {
            status = "macOS did not accept the shutdown request: \(error.localizedDescription)"
        }
    }

    /// Clipboard text moves only after an explicit host UI action. The guest
    /// installer listens on this private VM socket; neither clipboard is polled.
    func readGuestClipboardText() async throws -> String {
        try await transferGuestClipboard(opcode: 1, text: nil)
    }

    func writeGuestClipboardText(_ text: String) async throws {
        _ = try await transferGuestClipboard(opcode: 2, text: text)
    }

    /// The guest releases its private connection receipt only after its own final
    /// verification and a fresh Tailscale status check. This never uses NSPasteboard.
    func readVerifiedGuestConnectionJSON() async throws -> String {
        try await transferGuestClipboard(opcode: 3, text: nil)
    }

    private func transferGuestClipboard(opcode: UInt8, text: String?) async throws -> String {
        guard isRunning, let virtualMachine,
              let socket = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
            throw GuestClipboardError.vmNotRunning
        }
        let payload = text.map { Data($0.utf8) } ?? Data()
        guard payload.count <= GuestClipboardTransport.maximumTextBytes else {
            throw GuestClipboardError.textTooLarge
        }
        let connection: VZVirtioSocketConnection
        do {
            connection = try await socket.connect(toPort: GuestClipboardTransport.port)
        } catch {
            throw GuestClipboardError.serviceUnavailable
        }
        let retainedConnection = GuestClipboardConnection(connection)
        return try await Task.detached(priority: .userInitiated) {
            try GuestClipboardTransport.exchange(connection: retainedConnection.value, opcode: opcode, payload: payload)
        }.value
    }

    func forcePowerOff() async {
        guard isRunning, !isBusy, let virtualMachine else { return }
        operationState.begin(.stopping)
        status = "Powering off the VM…"
        defer { operationState.finish() }
        do {
            try await virtualMachine.stop()
            guestStopped(identity: ObjectIdentifier(virtualMachine), error: nil)
        } catch {
            status = "Could not power off the VM: \(error.localizedDescription)"
        }
    }

    func deleteFiles(_ id: VirtualMachineID) throws {
        guard !isBusy else { throw NativeVMError.cannotRemoveDuringInstall }
        guard !isRunning else { throw NativeVMError.cannotRemoveRunningVM }
        guard !hasOtherHostCopy else { throw NativeVMError.cannotRemoveWithOtherHostCopy }
        let locator = VirtualMachineBundleLocator(nativeRoot: rootURL)
        guard let bundle = locator.locate(id) else { throw NativeVMError.missingVM }
        try FileManager.default.removeItem(at: bundle)
        clearDesktopReady(for: id)
        status = "Tether Host VM \(id.description) and its files were deleted."
    }

    var hasOtherHostCopy: Bool {
        otherHostCopyRunning()
    }

    private func makeConfiguration(
        bundle: URL, hardware: VZMacHardwareModel, machineID: VZMacMachineIdentifier,
        cpuCount: Int, memorySize: UInt64, includeGuestDisk: Bool
    ) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.bootLoader = VZMacOSBootLoader()
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardware
        platform.machineIdentifier = machineID
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: bundle.appendingPathComponent("auxiliary.img"))
        configuration.platform = platform
        configuration.cpuCount = min(max(cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        configuration.memorySize = min(max(memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize), VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration()]
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1600, heightInPixels: 1000, pixelsPerInch: 144)]
        configuration.graphicsDevices = [graphics]
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = networkEnabled ? [network] : []
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: bundle.appendingPathComponent("disk.img"), readOnly: false)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]
        if includeGuestDisk {
            let isoURL = rootURL.deletingLastPathComponent().appendingPathComponent("Tether Guest Setup.iso")
            if FileManager.default.fileExists(atPath: isoURL.path) {
                let attachment = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
                configuration.storageDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
            }
        }
        try configuration.validate()
        return configuration
    }

    private var guestDiskURL: URL {
        rootURL.deletingLastPathComponent().appendingPathComponent("Tether Guest Setup.iso")
    }

    @discardableResult
    func prepareGuestDisk() async -> Bool {
        guard !isBusy, !isRunning else { return false }
        operationState.begin(.preparingMedia)
        defer { operationState.finish() }
        return await prepareGuestDiskWhileBusy()
    }

    private func prepareGuestDiskWhileBusy() async -> Bool {
        let destination = guestDiskURL
        do {
            status = "Preparing the guest setup disk…"
            try await guestDiskExporter(destination)
            status = "Guest setup disk is ready. It will appear when the VM next starts."
            return true
        } catch {
            status = "Guest setup disk failed: \(error.localizedDescription)"
            return false
        }
    }

    fileprivate func guestStopped(identity: ObjectIdentifier, error: Error?) {
        guard let currentVM = virtualMachine, ObjectIdentifier(currentVM) == identity else { return }
        if let runningID { markBundleUsed(runningID) }
        isRunning = false
        shutdownRequested = false
        runningID = nil
        virtualMachine = nil
        showsDisplay = false
        status = error.map { "The VM stopped: \($0.localizedDescription)" } ?? "The VM shut down. Select Start / Show to boot it again."
    }

    private func markBundleUsed(_ id: VirtualMachineID) {
        let bundle = rootURL.appendingPathComponent(id.description, isDirectory: true)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: bundle.path)
    }
}

/// Keeps the Virtualization-owned descriptor alive while a single background transfer runs.
private final class GuestClipboardConnection: @unchecked Sendable {
    let value: VZVirtioSocketConnection
    init(_ value: VZVirtioSocketConnection) { self.value = value }
}

/// One request per connection: opcode + big-endian length + UTF-8 request,
/// then status + big-endian length + UTF-8 response. Shared with the guest installer.
/// Opcodes 1/2 transfer explicit clipboard text; opcode 3 fetches the verified
/// guest connection over the same private socket without touching either clipboard.
private enum GuestClipboardTransport {
    static let port: UInt32 = 45251
    static let maximumTextBytes = 65_536
    private static let deadlineSeconds: TimeInterval = 10

    static func exchange(connection: VZVirtioSocketConnection, opcode: UInt8, payload: Data) throws -> String {
        let descriptor = connection.fileDescriptor
        guard descriptor >= 0 else { throw GuestClipboardError.disconnected }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw GuestClipboardError.disconnected
        }
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw GuestClipboardError.disconnected
        }
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        var frame = Data([opcode])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        try writeAll(frame, to: descriptor, deadline: deadline)

        let header = try readExactly(5, from: descriptor, deadline: deadline)
        let status = header[0]
        let count = header.dropFirst().reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        guard count <= maximumTextBytes else { throw GuestClipboardError.invalidResponse }
        let response = try readExactly(Int(count), from: descriptor, deadline: deadline)
        guard let text = String(data: response, encoding: .utf8) else {
            throw GuestClipboardError.invalidResponse
        }
        guard status == 0 else {
            throw GuestClipboardError.guestRejected(text.isEmpty ? "Request failed." : text)
        }
        if opcode == 2 && !text.isEmpty { throw GuestClipboardError.invalidResponse }
        return text
    }

    private static func writeAll(_ data: Data, to fd: Int32, deadline: Date) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                try wait(for: Int16(POLLOUT), on: fd, deadline: deadline)
                let written = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                if written > 0 { offset += written }
                else if written == 0 { throw GuestClipboardError.disconnected }
                else if errno != EINTR && errno != EAGAIN { throw GuestClipboardError.disconnected }
            }
        }
    }

    private static func readExactly(_ count: Int, from fd: Int32, deadline: Date) throws -> Data {
        var result = Data()
        while result.count < count {
            try wait(for: Int16(POLLIN), on: fd, deadline: deadline)
            var buffer = [UInt8](repeating: 0, count: min(4096, count - result.count))
            let received = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if received > 0 { result.append(contentsOf: buffer.prefix(received)) }
            else if received == 0 { throw GuestClipboardError.disconnected }
            else if errno != EINTR && errno != EAGAIN { throw GuestClipboardError.disconnected }
        }
        return result
    }

    private static func wait(for events: Int16, on fd: Int32, deadline: Date) throws {
        while true {
            let remaining = Int32(max(0, min(Int(Int32.max), Int(deadline.timeIntervalSinceNow * 1000))))
            guard remaining > 0 else { throw GuestClipboardError.timedOut }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, remaining)
            if result > 0 {
                if descriptor.revents & events != 0 { return }
                throw GuestClipboardError.disconnected
            }
            if result == 0 { throw GuestClipboardError.timedOut }
            if errno != EINTR { throw GuestClipboardError.disconnected }
        }
    }
}

private final class NativeVMDelegate: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    weak var owner: NativeVMManager?

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        let identity = ObjectIdentifier(virtualMachine)
        Task { @MainActor [weak owner] in owner?.guestStopped(identity: identity, error: nil) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        let identity = ObjectIdentifier(virtualMachine)
        Task { @MainActor [weak owner] in owner?.guestStopped(identity: identity, error: error) }
    }
}

struct NativeVMDisplay: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        view.virtualMachine = virtualMachine
    }
}
