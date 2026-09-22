import AppKit
import CryptoKit
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
    case guestDiskUnavailable
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
        case .guestDiskUnavailable: "The guest setup disk could not be prepared. Check the Tether Host installation and try Start VM again."
        case .cannotRemoveRunningVM: "Shut down the built-in VM before deleting its files."
        case .cannotRemoveDuringInstall: "Wait for VM installation or setup to finish before deleting a VM."
        case .cannotRemoveWithOtherHostCopy: "Quit the other Tether Host copy before deleting this VM."
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
    private static let selectedImageKey = "restoreImage.lastSelectedPath"

    static var canDownloadHostImage: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion == 26 && version.minorVersion == 2
    }

    @Published private(set) var imageURL: URL?
    @Published private(set) var imageDescription = "Choose a macOS IPSW to create a fresh VM."
    @Published private(set) var status = "No VM installation has started."
    @Published private(set) var isBusy = false
    @Published private(set) var installationProgress: Double?
    @Published private(set) var downloadProgress: DownloadProgressEstimate?
    @Published private(set) var isRunning = false
    @Published private(set) var shutdownRequested = false
    @Published private(set) var virtualMachine: VZVirtualMachine?
    @Published private(set) var desktopReadyVMID: VirtualMachineID?
    @Published var showsDisplay = false

    private var restoreImage: VZMacOSRestoreImage?
    private var activeDownloadID: UUID?
    private var runningID: VirtualMachineID?
    var runningVMID: VirtualMachineID? { isRunning ? runningID : nil }
    private let rootURL: URL
    private let vmDelegate = NativeVMDelegate()
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        desktopReadyVMID = preferences.string(forKey: "setup.nativeDesktopReadyVMID").flatMap(VirtualMachineID.init)
        rootURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
        isBusy = true
        status = "Verifying the saved macOS image…"
        do {
            guard try await Self.sha256(of: cachedHostImageURL) == Self.macOS262SHA256 else {
                throw NativeVMError.unsupportedImage
            }
            isBusy = false
            await inspect(cachedHostImageURL)
        } catch {
            isBusy = false
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
        isBusy = true
        status = "Checking the macOS image…"
        defer { isBusy = false }
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
        isBusy = true
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
            isBusy = false
            await inspect(destination)
        } catch {
            isBusy = false
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

    func install(for provider: VMProvider = .builtIn) async -> VirtualMachineID? {
        guard !isBusy, let imageURL, let restoreImage,
              let requirements = restoreImage.mostFeaturefulSupportedConfiguration else { return nil }
        if provider == .utm && UTMInstallation.detect() != .installed {
            status = "Install a compatible UTM in Applications before creating a UTM VM."
            return nil
        }
        guard !hasOtherHostCopy else {
            status = NativeVMError.anotherHostCopyRunning.localizedDescription
            return nil
        }
        isBusy = true
        defer { isBusy = false }
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
            if provider == .utm {
                do {
                    try await moveInstalledVMToUTM(id, nativeBundle: destination)
                    status = "Fresh macOS VM registered with UTM. Open it in UTM to finish the welcome screens."
                    return id
                } catch {
                    status = "macOS was installed, but UTM registration was not confirmed: \(error.localizedDescription) The Apple VM remains saved in Tether Host."
                    return nil
                }
            }
            status = "Starting the fresh VM…"
            try await boot(id)
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

    func moveToUTM(_ id: VirtualMachineID) async -> Bool {
        guard !isBusy, !isRunning, !hasOtherHostCopy else {
            status = "Shut down the Apple VM and quit any other Tether Host copy before moving it to UTM."
            return false
        }
        guard UTMInstallation.detect() == .installed else {
            status = "Install a compatible UTM in Applications before moving this VM."
            return false
        }
        let nativeBundle = rootURL.appendingPathComponent(id.description, isDirectory: true)
        let locator = VirtualMachineBundleLocator(nativeRoot: rootURL, utmRoots: [])
        guard locator.locate(id, provider: .builtIn) == nativeBundle else {
            status = "The exact Apple VM bundle could not be found. Refresh the VM list."
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await moveInstalledVMToUTM(id, nativeBundle: nativeBundle)
            status = "VM \(id.description.prefix(8)) now appears in UTM."
            return true
        } catch {
            status = "Could not confirm UTM registration: \(error.localizedDescription) The Apple VM is still saved in Tether Host."
            return false
        }
    }

    private func moveInstalledVMToUTM(_ id: VirtualMachineID, nativeBundle: URL) async throws {
        let packageRoot = rootURL.deletingLastPathComponent()
            .appendingPathComponent("UTM Virtual Machines", isDirectory: true)
        let candidate = packageRoot.appendingPathComponent("\(id.description).utm", isDirectory: true)
        let locator = VirtualMachineBundleLocator(nativeRoot: rootURL, utmRoots: [packageRoot])
        let package: URL
        if FileManager.default.fileExists(atPath: candidate.path) {
            guard locator.locate(id, provider: .utm) == candidate else {
                throw UTMApplePackageError.packageAlreadyExists
            }
            package = candidate
        } else {
            status = "Preparing a UTM package without changing the Apple VM…"
            package = try UTMApplePackageWriter.createPackage(nativeBundle: nativeBundle, in: packageRoot)
        }
        status = "Registering the VM with UTM…"
        try await registerWithUTM(package, id: id)
        try FileManager.default.removeItem(at: nativeBundle)
    }

    private func registerWithUTM(_ package: URL, id: VirtualMachineID) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([package], withApplicationAt: UTMInstallation.applicationURL,
                                    configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        let adapter = UTMCTLAdapter(executor: try UTMCTLProcessExecutor())
        for _ in 0..<20 {
            if let inventory = try? await adapter.list(), inventory.contains(where: { $0.id == id }) {
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw UTMAdapterError.vmNotFound(id)
    }

    func boot(_ id: VirtualMachineID) async throws {
        guard !isBusy || virtualMachine == nil else { return }
        if isRunning, runningID == id { showsDisplay = true; return }
        if isRunning { throw NativeVMError.anotherVMRunning }
        guard !hasOtherHostCopy else { throw NativeVMError.anotherHostCopyRunning }
        let bundle = rootURL.appendingPathComponent(id.description, isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundle.path) else { throw NativeVMError.missingVM }
        guard await prepareGuestDisk() else { throw NativeVMError.guestDiskUnavailable }
        let hardwareData = try Data(contentsOf: bundle.appendingPathComponent("hardware.bin"))
        let machineData = try Data(contentsOf: bundle.appendingPathComponent("machine.bin"))
        guard let hardware = VZMacHardwareModel(dataRepresentation: hardwareData),
              let machineID = VZMacMachineIdentifier(dataRepresentation: machineData),
              hardware.isSupported else { throw NativeVMError.invalidVM }
        let configuration = try makeConfiguration(
            bundle: bundle, hardware: hardware, machineID: machineID,
            cpuCount: min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)),
            memorySize: 8 * 1_073_741_824, includeGuestDisk: true
        )
        let vm = VZVirtualMachine(configuration: configuration)
        vm.delegate = vmDelegate
        virtualMachine = vm
        do {
            try await vm.start()
            runningID = id
            isRunning = true
            shutdownRequested = false
            showsDisplay = true
            markBundleUsed(id)
            status = "Tether Host VM started. Finish the macOS welcome screens in this window."
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
        guard isRunning, let virtualMachine else { return }
        do {
            try virtualMachine.requestStop()
            shutdownRequested = true
            status = "Asked macOS to shut down. Wait for the VM status to change to Off."
        } catch {
            status = "macOS did not accept the shutdown request: \(error.localizedDescription)"
        }
    }

    func forcePowerOff() async {
        guard isRunning, !isBusy, let virtualMachine else { return }
        isBusy = true
        status = "Powering off the VM…"
        defer { isBusy = false }
        do {
            try await virtualMachine.stop()
        } catch {
            status = "Could not power off the VM: \(error.localizedDescription)"
        }
    }

    func deleteFiles(_ id: VirtualMachineID) throws {
        guard !isBusy else { throw NativeVMError.cannotRemoveDuringInstall }
        guard !isRunning else { throw NativeVMError.cannotRemoveRunningVM }
        guard !hasOtherHostCopy else { throw NativeVMError.cannotRemoveWithOtherHostCopy }
        let locator = VirtualMachineBundleLocator(nativeRoot: rootURL, utmRoots: [])
        guard let bundle = locator.locate(id, provider: .builtIn) else { throw NativeVMError.missingVM }
        try FileManager.default.removeItem(at: bundle)
        clearDesktopReady(for: id)
        status = "Tether Host VM \(id.description) and its files were deleted."
    }

    var hasOtherHostCopy: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "app.tether.host")
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
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
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration()]
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1600, heightInPixels: 1000, pixelsPerInch: 144)]
        configuration.graphicsDevices = [graphics]
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]
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

    @discardableResult
    func prepareGuestDisk() async -> Bool {
        let destination = rootURL.deletingLastPathComponent().appendingPathComponent("Tether Guest Setup.iso")
        do {
            status = "Preparing the guest setup disk…"
            try await GuestSetupDiskExporter.export(appURL: Bundle.main.bundleURL, to: destination)
            status = "Guest setup disk is ready. It will appear when the VM next starts."
            return true
        } catch {
            status = "Guest setup disk failed: \(error.localizedDescription)"
            return false
        }
    }

    fileprivate func guestStopped(error: Error?) {
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

private final class NativeVMDelegate: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    weak var owner: NativeVMManager?

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor [weak owner] in owner?.guestStopped(error: nil) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        Task { @MainActor [weak owner] in owner?.guestStopped(error: error) }
    }
}

struct NativeVMDisplay: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = true
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        view.virtualMachine = virtualMachine
    }
}
