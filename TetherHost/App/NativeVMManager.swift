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
    case insufficientSpace(Int)
    case insufficientDownloadSpace
    case insufficientDebianDownloadSpace
    case utmCleanupIncomplete(String)
    case invalidResources(String)
    case noCompatibleDownload(host: String)
    case imageCatalogUnavailable
    case missingVM
    case invalidVM
    case anotherVMRunning
    case cannotStartDuringInstall
    case anotherHostCopyRunning
    case guestDiskUnavailable
    case cannotRemoveRunningVM
    case cannotRemoveDuringInstall
    case cannotRemoveWithOtherHostCopy

    var errorDescription: String? {
        switch self {
        case .unsupportedImage: "This macOS IPSW is not compatible with this Mac's virtualization hardware. Choose another IPSW."
        case .newerGuestRequiresHostUpdate(let guest, let host):
            "This is a macOS \(guest) IPSW, but this Mac runs macOS \(host). Choose a macOS \(host) IPSW or update this Mac first."
        case .insufficientSpace(let gib): "At least \(gib) GB of free space is needed on the selected VM drive to create this VM."
        case .utmCleanupIncomplete(let detail): "UTM registered the new VM, but cleanup did not finish. Both copies may remain; run only one copy. \(detail)"
        case .insufficientDownloadSpace: "At least 25 GB of free space is needed in Application Support to cache the macOS download."
        case .insufficientDebianDownloadSpace: "At least 2 GB of free space is needed in Application Support to cache Debian."
        case .invalidResources(let message): message
        case .noCompatibleDownload(let host): "No downloadable macOS IPSW was found for macOS \(host). Update this Mac or choose a compatible IPSW manually."
        case .imageCatalogUnavailable: "Could not check available macOS images. Check your internet connection, try again, or choose a compatible IPSW manually."
        case .missingVM: "The selected Tether VM is missing. Refresh the VM list."
        case .invalidVM: "The Tether VM is incomplete or damaged. Create a new VM."
        case .anotherVMRunning: "Another Tether VM is already running. Shut it down before starting this one."
        case .cannotStartDuringInstall: "Wait for the current VM operation to finish before starting a VM."
        case .anotherHostCopyRunning: "Another Tether Host for Mac copy is open. Quit it before starting this VM."
        case .guestDiskUnavailable: "The guest setup disk could not be prepared. Check the Tether Host installation and try Start VM again."
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
        case .serviceUnavailable: "Open Tether Guest Installer in the VM to finish clipboard setup, then check the clipboard connection again."
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
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(RestoreImagePolicy.isAppleImageURL(request.url) ? request : nil)
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

private struct CachedRestoreImage: Codable {
    let filename: String
    let sha256: String
    let majorVersion: Int
    let minorVersion: Int
    let buildVersion: String
}

private struct RemoteRestoreCandidate {
    let url: URL
    let version: OperatingSystemVersion
    let build: String
    let expectedSHA256: String?

    var versionLabel: String {
        version.patchVersion == 0 ? "\(version.majorVersion).\(version.minorVersion)" :
            "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

struct RestoreImageDownloadOption: Identifiable, Hashable {
    let id: String
    let title: String
    let versionLabel: String
}

private struct IPSWCatalog: Decodable {
    struct Firmware: Decodable {
        let identifier: String
        let version: String
        let buildid: String
        let url: URL
        let sha256sum: String?
    }
    let firmwares: [Firmware]
}

@MainActor
final class NativeVMManager: ObservableObject {
    private static let macOS262URL = URL(string: "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-37399/E144C918-CF99-4BBC-B1D0-3E739B9A3F2D/UniversalMac_26.2_25C56_Restore.ipsw")!
    private static let macOS262SHA256 = "bc7c67b2a2cc4ac8c9da0c2b149b9f31e153cd542ce387e6fb8620e41b5278ef"
    private static let selectedImageKey = "restoreImage.lastSelectedPath"
    private static let downloadedImageKey = "restoreImage.lastDownloadedFilename"
    private static let creationFolderPathKey = "vmCreation.folderPath"
    private static let creationFolderBookmarkKey = "vmCreation.folderBookmark"
    private static let creationFolderVolumeKey = "vmCreation.volumeIdentity"

    static var canDownloadHostImage: Bool {
        true // Keep the action visible so unsupported hosts receive an explanation.
    }

    @Published private(set) var imageURL: URL?
    @Published private(set) var imageDescription = "Choose a macOS IPSW to create a fresh VM."
    @Published private(set) var debianImageURL: URL?
    @Published private(set) var debianImageDescription = "Download Debian 13 ARM64 with automatic Xfce/X11 setup."
    @Published private(set) var status = "No VM installation has started."
    @Published private(set) var isBusy = false
    @Published private(set) var startingVMID: VirtualMachineID?
    @Published private(set) var installationProgress: Double?
    @Published private(set) var downloadProgress: DownloadProgressEstimate?
    @Published private(set) var downloadImageOptions: [RestoreImageDownloadOption] = []
    @Published var selectedDownloadVersion = ""
    @Published private(set) var recommendedDownloadVersion = ""
    @Published private(set) var isLoadingDownloadImageOptions = false
    @Published private(set) var isRunning = false
    @Published private(set) var runningGuestOS: NativeGuestOS = .macOS
    @Published private(set) var shutdownRequested = false
    @Published private(set) var virtualMachine: VZVirtualMachine?
    @Published private(set) var desktopReadyVMID: VirtualMachineID?
    @Published var showsDisplay = false
    @Published var creationCPUCount: Int
    @Published var creationMemoryGiB: Int
    @Published var creationDiskGiB: Int
    @Published private(set) var selectedCreationStorageURL: URL?
    @Published private(set) var creationStorageSelectionError: String?
    private var creationGuestOS: NativeGuestOS = .macOS

    private var restoreImage: VZMacOSRestoreImage?
    private var activeDownloadID: UUID?
    private var downloadCandidates: [RemoteRestoreCandidate] = []
    private var runningID: VirtualMachineID?
    private var forcePowerOffRequested = false
    private var serialLogHandle: FileHandle?
    var runningVMID: VirtualMachineID? { isRunning ? runningID : nil }
    private let rootURL: URL
    private let rootURLWasOverridden: Bool
    private let vmDelegate = NativeVMDelegate()
    private let preferences: UserDefaults
    private let serialInputHandleOverride: FileHandle?

    init(preferences: UserDefaults = .standard, rootURLOverride: URL? = nil,
         serialInputHandleOverride: FileHandle? = nil) {
        let defaults = Self.baseResourceLimits.defaults
        creationCPUCount = defaults.cpuCount
        creationMemoryGiB = defaults.memoryGiB
        creationDiskGiB = defaults.diskGiB
        self.preferences = preferences
        self.serialInputHandleOverride = serialInputHandleOverride
        rootURLWasOverridden = rootURLOverride != nil
        desktopReadyVMID = preferences.string(forKey: "setup.nativeDesktopReadyVMID").flatMap(VirtualMachineID.init)
        rootURL = rootURLOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tether Host for Mac/Virtual Machines", isDirectory: true)
        if let path = preferences.string(forKey: Self.creationFolderPathKey) {
            var stale = false
            let bookmarked = preferences.data(forKey: Self.creationFolderBookmarkKey).flatMap {
                try? URL(resolvingBookmarkData: $0, options: [.withoutUI, .withoutMounting],
                         bookmarkDataIsStale: &stale)
            }
            selectedCreationStorageURL = bookmarked ?? URL(fileURLWithPath: path, isDirectory: true)
        }
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
        Task { [weak self] in
            guard let self else { return }
            if let cached = try? await DebianVMImageService.verifiedCachedImage(in: self.debianCacheDirectory) {
                self.debianImageURL = cached
                self.debianImageDescription = "Verified Debian 13 ARM64 image is ready."
            }
        }
    }

    private static var baseResourceLimits: NativeVMResourceLimits {
        NativeVMResourceLimits(
            hostCPUCount: ProcessInfo.processInfo.activeProcessorCount,
            hostMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            maximumCPUCount: VZVirtualMachineConfiguration.maximumAllowedCPUCount,
            maximumMemoryBytes: VZVirtualMachineConfiguration.maximumAllowedMemorySize
        )
    }

    private var creationLimits: NativeVMResourceLimits {
        NativeVMResourceLimits(
            hostCPUCount: ProcessInfo.processInfo.activeProcessorCount,
            hostMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            minimumCPUCount: creationGuestOS == .debian ? 2 :
                (restoreImage?.mostFeaturefulSupportedConfiguration?.minimumSupportedCPUCount ?? 2),
            minimumMemoryBytes: creationGuestOS == .debian ? 4 * 1_073_741_824 :
                (restoreImage?.mostFeaturefulSupportedConfiguration?.minimumSupportedMemorySize ?? 4 * 1_073_741_824),
            maximumCPUCount: VZVirtualMachineConfiguration.maximumAllowedCPUCount,
            maximumMemoryBytes: VZVirtualMachineConfiguration.maximumAllowedMemorySize
        )
    }

    var creationCPURange: ClosedRange<Int> { creationLimits.cpu }
    var creationMemoryRange: ClosedRange<Int> { creationLimits.memoryGiB }
    var creationDiskRange: ClosedRange<Int> { creationLimits.diskGiB }
    var creationStorageDisplayName: String {
        selectedCreationStorageURL?.path ?? "This Mac (default)"
    }
    var creationStorageWarning: String? {
        guard let folder = selectedCreationStorageURL,
              (try? folder.resourceValues(forKeys: [.volumeSupportsSparseFilesKey]))?
                .volumeSupportsSparseFiles != true else { return nil }
        let required = NativeVMStorageCapacity.requiredFreeGiB(
            diskGiB: creationDiskGiB, guestOS: creationGuestOS, supportsSparseFiles: false
        )
        return "This drive cannot store sparse VM disks. A \(creationDiskGiB) GB VM may use the full \(creationDiskGiB) GB immediately. Keep at least \(required) GB free."
    }
    var creationStorageValidationMessage: String? {
        guard let folder = selectedCreationStorageURL else { return nil }
        if let creationStorageSelectionError { return creationStorageSelectionError }
        let resolvedFolder = folder.resolvingSymlinksInPath()
        let resolvedDefault = rootURL.resolvingSymlinksInPath()
        if resolvedFolder == resolvedDefault || resolvedFolder.path.hasPrefix(resolvedDefault.path + "/") {
            return "Choose a folder outside Tether's default Virtual Machines folder."
        }
        var ancestor = resolvedFolder
        while ancestor.path != "/" {
            if ancestor.pathExtension.lowercased() == "utm" ||
                FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(NativeVirtualMachineStore.manifestFilename).path) {
                return "Choose a storage folder outside an existing virtual machine."
            }
            ancestor.deleteLastPathComponent()
        }
        guard FileManager.default.fileExists(atPath: folder.path),
              let volume = try? NativeVMStorageRegistry.volumeIdentity(at: folder),
              volume == preferences.string(forKey: Self.creationFolderVolumeKey) else {
            return "The selected VM drive is unavailable or has changed. Reconnect it or choose another folder."
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            return "The selected VM folder is not writable. Choose a folder where you can save files."
        }
        let sparse = (try? folder.resourceValues(forKeys: [.volumeSupportsSparseFilesKey]))?
            .volumeSupportsSparseFiles == true
        let requiredGiB = NativeVMStorageCapacity.requiredFreeGiB(
            diskGiB: creationDiskGiB, guestOS: creationGuestOS, supportsSparseFiles: sparse
        )
        guard let available = try? NativeVMStorageCapacity.availableBytes(at: folder),
              available >= Int64(requiredGiB) * NativeVMStorageCapacity.bytesPerGiB else {
            return "This VM needs at least \(requiredGiB) GB free on the selected drive."
        }
        return nil
    }

    func chooseCreationStorageFolder() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "New virtual machines will be saved here. OS downloads stay on this Mac."
        if panel.runModal() == .OK, let folder = panel.url?.standardizedFileURL {
            // Keep the user's choice visible even if validation fails, so the
            // inline error explains why this particular folder cannot be used.
            selectedCreationStorageURL = folder
            creationStorageSelectionError = nil
            preferences.set(folder.path, forKey: Self.creationFolderPathKey)
            preferences.removeObject(forKey: Self.creationFolderBookmarkKey)
            preferences.removeObject(forKey: Self.creationFolderVolumeKey)
            do {
                let volume = try NativeVMStorageRegistry.volumeIdentity(at: folder)
                preferences.set(try folder.bookmarkData(), forKey: Self.creationFolderBookmarkKey)
                preferences.set(volume, forKey: Self.creationFolderVolumeKey)
            } catch {
                creationStorageSelectionError = "Could not remember this VM folder: \(error.localizedDescription) Choose the folder again."
            }
        }
    }

    func resetCreationStorageToDefault() {
        guard !isBusy else { return }
        preferences.removeObject(forKey: Self.creationFolderBookmarkKey)
        preferences.removeObject(forKey: Self.creationFolderPathKey)
        preferences.removeObject(forKey: Self.creationFolderVolumeKey)
        selectedCreationStorageURL = nil
        creationStorageSelectionError = nil
    }
    var creationResourceError: String? {
        creationLimits.validationMessage(for: NativeVMResources(
            cpuCount: creationCPUCount, memoryGiB: creationMemoryGiB, diskGiB: creationDiskGiB
        ))
    }

    func resetCreationResources() {
        creationGuestOS = .macOS
        let defaults = creationLimits.defaults
        creationCPUCount = defaults.cpuCount
        creationMemoryGiB = defaults.memoryGiB
        creationDiskGiB = defaults.diskGiB
    }

    func configureDebianCreationDefaults() {
        guard !isBusy else { return }
        creationGuestOS = .debian
        creationCPUCount = min(creationCPURange.upperBound, max(creationCPURange.lowerBound, 4))
        creationMemoryGiB = min(creationMemoryRange.upperBound, max(creationMemoryRange.lowerBound, 8))
        creationDiskGiB = 24
    }

    func configureMacOSCreationDefaults() {
        guard !isBusy else { return }
        resetCreationResources()
    }

    private var restoreCacheDirectory: URL {
        rootURL.deletingLastPathComponent()
            .appendingPathComponent("Restore Images", isDirectory: true)
    }

    private var debianCacheDirectory: URL {
        rootURL.deletingLastPathComponent().appendingPathComponent("Debian Images", isDirectory: true)
    }

    private var bundledDebianConverter: URL? {
        Bundle.main.url(forResource: "qemu-img", withExtension: nil, subdirectory: "Tools")
    }

    var debianConverterAvailable: Bool {
        DebianVMImageService.converterURL(bundledDebianConverter) != nil
    }

    var debianCreationReadinessMessage: String? {
        if !debianConverterAvailable { return DebianVMImageError.converterUnavailable.localizedDescription }
        guard let debianImageURL,
              FileManager.default.fileExists(atPath: debianImageURL.path) else {
            return "The downloaded Debian image is missing. Download and verify it again."
        }
        return creationResourceError ?? creationStorageValidationMessage
    }

    var hasCachedDebianImage: Bool {
        FileManager.default.fileExists(atPath: DebianVMImageService.cachedImageURL(in: debianCacheDirectory).path)
    }

    var debianCachedImageSizeDescription: String {
        let image = DebianVMImageService.cachedImageURL(in: debianCacheDirectory)
        guard let bytes = try? image.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    func revealCachedDebianImageInFinder() {
        guard hasCachedDebianImage else { return }
        NSWorkspace.shared.activateFileViewerSelecting([DebianVMImageService.cachedImageURL(in: debianCacheDirectory)])
    }

    func downloadDebianImage() async {
        guard !isBusy else { return }
        isBusy = true
        downloadProgress = nil
        let downloadID = UUID()
        activeDownloadID = downloadID
        status = "Downloading and checking Debian 13 for ARM64…"
        defer {
            isBusy = false
            activeDownloadID = nil
            downloadProgress = nil
        }
        do {
            try FileManager.default.createDirectory(at: debianCacheDirectory, withIntermediateDirectories: true)
            if try await DebianVMImageService.verifiedCachedImage(in: debianCacheDirectory) == nil {
                let capacity = try debianCacheDirectory
                    .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage ?? 0
                guard capacity >= 2 * 1_073_741_824 else { throw NativeVMError.insufficientDebianDownloadSpace }
            }
            let image = try await DebianVMImageService.downloadVerifiedImage(into: debianCacheDirectory) {
                [weak self] received, total, elapsed in
                Task { @MainActor [weak self] in
                    guard self?.activeDownloadID == downloadID else { return }
                    self?.downloadProgress = DownloadProgressEstimate(
                        receivedBytes: received, expectedBytes: total, elapsedSeconds: elapsed
                    )
                }
            }
            debianImageURL = image
            debianImageDescription = "Verified Debian 13 ARM64 image is ready."
            status = "Debian image is ready. Configure the VM, then choose Create VM."
        } catch {
            debianImageURL = nil
            debianImageDescription = "Debian image could not be verified. Download it again."
            status = "Debian download failed: \(error.localizedDescription)"
        }
    }

    func guestOS(for id: VirtualMachineID) -> NativeGuestOS {
        guard let bundle = VirtualMachineBundleLocator(nativeRoot: rootURL, utmRoots: [])
            .locate(id, provider: .builtIn),
              let manifest = try? readManifest(at: bundle) else { return .macOS }
        return manifest.guestOS
    }

    func revealDebianCredentials(for id: VirtualMachineID? = nil) {
        guard let id = id ?? runningID, guestOS(for: id) == .debian,
              let bundle = VirtualMachineBundleLocator(nativeRoot: rootURL, utmRoots: [])
                .locate(id, provider: .builtIn) else { return }
        let credentials = LinuxGuestSeedWriter.credentialsURL(in: bundle)
        guard FileManager.default.fileExists(atPath: credentials.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([credentials])
    }

    private var pinnedHostImageURL: URL {
        restoreCacheDirectory.appendingPathComponent("UniversalMac_26.2_25C56_Restore.ipsw")
    }

    var cachedHostImageURL: URL {
        if let filename = preferences.string(forKey: Self.downloadedImageKey),
           filename == URL(fileURLWithPath: filename).lastPathComponent,
           filename.hasSuffix(".ipsw") {
            let url = restoreCacheDirectory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path),
               FileManager.default.fileExists(atPath: cacheRecordURL(for: url).path) { return url }
        }
        return pinnedHostImageURL
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
            let cached = cachedHostImageURL
            let expectedDigest: String
            if cached == pinnedHostImageURL {
                expectedDigest = Self.macOS262SHA256
            } else {
                let record = try JSONDecoder().decode(CachedRestoreImage.self,
                    from: Data(contentsOf: cacheRecordURL(for: cached)))
                guard record.filename == cached.lastPathComponent else { throw NativeVMError.unsupportedImage }
                expectedDigest = record.sha256
            }
            guard try await Self.sha256(of: cached) == expectedDigest else {
                throw NativeVMError.unsupportedImage
            }
            isBusy = false
            await inspect(cached)
        } catch {
            isBusy = false
            status = "Saved image could not be verified. Choose Download again to replace it. \(error.localizedDescription)"
        }
    }

    private func cacheRecordURL(for image: URL) -> URL {
        image.appendingPathExtension("json")
    }

    func isDesktopReady(for id: VirtualMachineID) -> Bool {
        desktopReadyVMID == id
    }

    func confirmDesktopReady() {
        guard isRunning, let runningID else { return }
        desktopReadyVMID = runningID
        preferences.set(runningID.description, forKey: "setup.nativeDesktopReadyVMID")
        status = runningGuestOS == .debian
            ? "Debian desktop confirmed by you. Continue with guest setup in the VM."
            : "macOS desktop confirmed by you. Continue with the guest setup disk in the VM."
    }

    func confirmDesktopReadyFromGuestSetup() {
        guard isRunning, let runningID else { return }
        desktopReadyVMID = runningID
        preferences.set(runningID.description, forKey: "setup.nativeDesktopReadyVMID")
        status = runningGuestOS == .debian
            ? "The verified guest installer is running in Debian."
            : "The verified guest installer is running in the macOS desktop session."
    }

    func clearDesktopReady(for id: VirtualMachineID) {
        guard desktopReadyVMID == id else { return }
        desktopReadyVMID = nil
        preferences.removeObject(forKey: "setup.nativeDesktopReadyVMID")
        status = guestOS(for: id) == .debian
            ? "Sign in to Debian, then confirm when its desktop appears."
            : "Finish the macOS welcome screens, then confirm when the desktop appears."
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
            // A different IPSW may raise the guest minimum. Keep user choices
            // intact unless the new image makes them invalid.
            let limits = creationLimits
            let adjusted = !limits.cpu.contains(creationCPUCount) ||
                !limits.memoryGiB.contains(creationMemoryGiB) ||
                !limits.diskGiB.contains(creationDiskGiB)
            creationCPUCount = min(max(creationCPUCount, limits.cpu.lowerBound), limits.cpu.upperBound)
            creationMemoryGiB = min(max(creationMemoryGiB, limits.memoryGiB.lowerBound), limits.memoryGiB.upperBound)
            creationDiskGiB = min(max(creationDiskGiB, limits.diskGiB.lowerBound), limits.diskGiB.upperBound)
            imageURL = url
            preferences.set(url.path, forKey: Self.selectedImageKey)
            let version = image.operatingSystemVersion
            let versionLabel = version.patchVersion == 0 ?
                "\(version.majorVersion).\(version.minorVersion)" :
                "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            imageDescription = "macOS \(versionLabel) (\(image.buildVersion)) — compatible with this Mac"
            status = adjusted
                ? "VM resources were adjusted to meet this macOS image and Mac's limits. Review them before creating the VM."
                : "Ready to create a new, separate Tether Host VM."
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

    private static func discoverDownloadCandidates() async throws -> [RemoteRestoreCandidate] {
        let host = ProcessInfo.processInfo.operatingSystemVersion
        var candidates: [RemoteRestoreCandidate] = []
        var catalogAvailable = false

        if let latest = try? await VZMacOSRestoreImage.latestSupported,
           latest.isSupported, latest.mostFeaturefulSupportedConfiguration != nil,
           RestoreImagePolicy.isEligible(latest.operatingSystemVersion, for: host),
           RestoreImagePolicy.isAppleImageURL(latest.url) {
            candidates.append(RemoteRestoreCandidate(url: latest.url,
                version: latest.operatingSystemVersion, build: latest.buildVersion, expectedSHA256: nil))
        }

        // Apple publishes only its current IPSW in the public feed. The VM firmware
        // history is discovery metadata; image bytes must still come from Apple.
        let catalogURL = URL(string: "https://api.ipsw.me/v4/device/VirtualMac2,1?type=ipsw")!
        if let (data, response) = try? await URLSession.shared.data(from: catalogURL),
           (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 10_000_000,
           let catalog = try? JSONDecoder().decode(IPSWCatalog.self, from: data) {
            catalogAvailable = true
            for firmware in catalog.firmwares {
                guard firmware.identifier == "VirtualMac2,1",
                      let version = RestoreImagePolicy.parseVersion(firmware.version),
                      RestoreImagePolicy.isEligible(version, for: host),
                      RestoreImagePolicy.isAppleImageURL(firmware.url), !firmware.buildid.isEmpty else { continue }
                let digest = firmware.url == macOS262URL ? macOS262SHA256 : firmware.sha256sum
                guard let digest, digest.count == 64,
                      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
                candidates.append(RemoteRestoreCandidate(url: firmware.url, version: version,
                    build: firmware.buildid, expectedSHA256: digest))
            }
        }

        if RestoreImagePolicy.isEligible(OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0), for: host) {
            candidates.append(RemoteRestoreCandidate(url: macOS262URL,
                version: OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0),
                build: "25C56", expectedSHA256: macOS262SHA256))
        }
        candidates.sort { left, right in
            let leftVersion = (left.version.majorVersion, left.version.minorVersion, left.version.patchVersion)
            let rightVersion = (right.version.majorVersion, right.version.minorVersion, right.version.patchVersion)
            return leftVersion == rightVersion ?
                (left.expectedSHA256 != nil && right.expectedSHA256 == nil) :
                (leftVersion > rightVersion)
        }
        var seenVersions = Set<String>()
        let distinct = candidates.filter { seenVersions.insert($0.versionLabel).inserted }
        guard !distinct.isEmpty else {
            if !catalogAvailable { throw NativeVMError.imageCatalogUnavailable }
            throw NativeVMError.noCompatibleDownload(host: "\(host.majorVersion).\(host.minorVersion)")
        }
        return distinct
    }

    func loadDownloadImageOptions() async {
        guard !isBusy, !isLoadingDownloadImageOptions, downloadCandidates.isEmpty else { return }
        isLoadingDownloadImageOptions = true
        status = "Finding macOS images…"
        defer { isLoadingDownloadImageOptions = false }
        do {
            let candidates = try await Self.discoverDownloadCandidates()
            downloadCandidates = candidates
            downloadImageOptions = candidates.map {
                RestoreImageDownloadOption(id: $0.versionLabel,
                    title: "macOS \($0.versionLabel)", versionLabel: $0.versionLabel)
            }
            let host = ProcessInfo.processInfo.operatingSystemVersion
            let recommended = RestoreImagePolicy.preferredVersion(from: candidates.map(\.version), for: host)
            recommendedDownloadVersion = candidates.first(where: { candidate in
                guard let recommended else { return false }
                return (candidate.version.majorVersion, candidate.version.minorVersion, candidate.version.patchVersion) ==
                    (recommended.majorVersion, recommended.minorVersion, recommended.patchVersion)
            })?.versionLabel ?? ""
            let previous = RestoreImagePolicy.parseVersion(selectedDownloadVersion)
            let selected = RestoreImagePolicy.preferredVersion(from: candidates.map(\.version),
                for: host, retaining: previous)
            selectedDownloadVersion = candidates.first(where: { candidate in
                guard let selected else { return false }
                return (candidate.version.majorVersion, candidate.version.minorVersion, candidate.version.patchVersion) ==
                    (selected.majorVersion, selected.minorVersion, selected.patchVersion)
            })?.versionLabel ?? ""
            status = "Choose a macOS version, then download its IPSW from Apple."
        } catch {
            downloadCandidates = []
            downloadImageOptions = []
            recommendedDownloadVersion = ""
            status = error.localizedDescription
        }
    }

    func downloadHostImage() async {
        guard !isBusy, !isLoadingDownloadImageOptions else { return }
        if downloadCandidates.isEmpty { await loadDownloadImageOptions() }
        guard !downloadCandidates.isEmpty else { return }
        guard let candidate = downloadCandidates.first(where: { $0.versionLabel == selectedDownloadVersion }) else {
            status = "Choose an available macOS version to download."
            return
        }
        isBusy = true
        downloadProgress = nil
        defer {
            activeDownloadID = nil
            downloadProgress = nil
        }
        do {
            guard RestoreImagePolicy.isAppleImageURL(candidate.url) else { throw NativeVMError.unsupportedImage }
            let safeBuild = candidate.build.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            guard !safeBuild.isEmpty else { throw NativeVMError.unsupportedImage }
            let destination = candidate.url == Self.macOS262URL ? pinnedHostImageURL :
                restoreCacheDirectory.appendingPathComponent(
                    "UniversalMac_\(candidate.versionLabel)_\(safeBuild)_Restore.ipsw")
            status = "Downloading macOS \(candidate.versionLabel) from Apple's servers…"
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let available = try destination.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? 0
            guard available >= 25 * 1_073_741_824 else {
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
            let (temporary, response) = try await downloader.run(from: candidate.url)
            activeDownloadID = nil
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  RestoreImagePolicy.isAppleImageURL(response.url) else {
                throw URLError(.badServerResponse)
            }
            downloadProgress = nil
            status = "Verifying the downloaded IPSW…"
            let digest = try await Self.sha256(of: temporary)
            if let expected = candidate.expectedSHA256 {
                guard digest == expected else { throw NativeVMError.unsupportedImage }
            }
            let image = try await VZMacOSRestoreImage.image(from: temporary)
            guard image.isSupported, image.mostFeaturefulSupportedConfiguration != nil,
                  image.operatingSystemVersion.majorVersion == candidate.version.majorVersion,
                  image.operatingSystemVersion.minorVersion == candidate.version.minorVersion,
                  image.operatingSystemVersion.patchVersion == candidate.version.patchVersion,
                  image.buildVersion == candidate.build else { throw NativeVMError.unsupportedImage }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            if destination != pinnedHostImageURL {
                let record = CachedRestoreImage(filename: destination.lastPathComponent, sha256: digest,
                    majorVersion: candidate.version.majorVersion,
                    minorVersion: candidate.version.minorVersion, buildVersion: candidate.build)
                try JSONEncoder().encode(record).write(to: cacheRecordURL(for: destination), options: .atomic)
            }
            preferences.set(destination.lastPathComponent, forKey: Self.downloadedImageKey)
            isBusy = false
            await inspect(destination)
        } catch {
            isBusy = false
            status = "Could not download or verify macOS: \(error.localizedDescription)"
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

    func installDebian() async -> VirtualMachineID? {
        guard !isBusy, let imageURL = debianImageURL else { return nil }
        if let readinessMessage = debianCreationReadinessMessage {
            status = readinessMessage
            return nil
        }
        guard !hasOtherHostCopy else {
            status = NativeVMError.anotherHostCopyRunning.localizedDescription
            return nil
        }
        if let creationResourceError {
            status = creationResourceError
            return nil
        }
        isBusy = true
        defer { isBusy = false }
        let id = VirtualMachineID(rawValue: UUID())
        let resources = NativeVMResources(cpuCount: creationCPUCount,
                                          memoryGiB: creationMemoryGiB,
                                          diskGiB: creationDiskGiB)
        let creationRoot = selectedCreationStorageURL ?? rootURL
        let stage = creationRoot.appendingPathComponent(".creating-\(id.description)", isDirectory: true)
        let destination = creationRoot.appendingPathComponent(id.description, isDirectory: true)
        do {
            let verifiedImage = try await DebianVMImageService.verifiedCachedImage(in: debianCacheDirectory)
            guard verifiedImage == imageURL else {
                throw DebianVMImageError.checksumMismatch
            }
            if let creationStorageValidationMessage {
                status = creationStorageValidationMessage
                return nil
            }
            if selectedCreationStorageURL == nil {
                try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            }
            let sparse = (try? creationRoot.resourceValues(forKeys: [.volumeSupportsSparseFilesKey]))?
                .volumeSupportsSparseFiles == true
            let requiredGiB = NativeVMStorageCapacity.requiredFreeGiB(
                diskGiB: resources.diskGiB, guestOS: .debian, supportsSparseFiles: sparse
            )
            let capacity = try NativeVMStorageCapacity.availableBytes(at: creationRoot)
            guard capacity >= Int64(requiredGiB) * NativeVMStorageCapacity.bytesPerGiB else {
                throw NativeVMError.insufficientSpace(requiredGiB)
            }
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            status = "Preparing the Debian disk…"
            try await DebianVMImageService.createRawDisk(
                from: imageURL, at: stage.appendingPathComponent("disk.img"),
                diskGiB: resources.diskGiB,
                bundledConverter: bundledDebianConverter
            )
            let sourceDigest = try Data(contentsOf: DebianVMImageService.cachedDigestURL(in: debianCacheDirectory))
            try sourceDigest.write(to: stage.appendingPathComponent("debian-image.sha512"), options: .atomic)
            let machineID = VZGenericMachineIdentifier()
            try machineID.dataRepresentation.write(to: stage.appendingPathComponent("machine.bin"), options: .atomic)
            _ = try VZEFIVariableStore(creatingVariableStoreAt: stage.appendingPathComponent("efi-vars.bin"))
            status = "Preparing Debian first-boot setup…"
            _ = try await LinuxGuestSeedWriter.createSeed(
                in: stage, vmID: id,
                guestResourcesURL: Bundle.main.bundleURL.appendingPathComponent(
                    "Contents/Resources/LinuxGuestSetup", isDirectory: true)
            )
            let configuration = try makeDebianConfiguration(
                bundle: stage, machineID: machineID, cpuCount: resources.cpuCount,
                memorySize: UInt64(resources.memoryGiB) * 1_073_741_824,
                serialLogHandle: nil
            )
            _ = configuration // Validation happens before the bundle is published.
            let manifest = NativeVirtualMachineManifest(
                id: id, name: "Debian 13 · \(id.description.prefix(8))",
                guestImageVersion: "Debian 13 ARM64 · Xfce/X11",
                resources: resources, guestOS: .debian
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(manifest).write(
                to: stage.appendingPathComponent(NativeVirtualMachineStore.manifestFilename), options: .atomic
            )
            try FileManager.default.moveItem(at: stage, to: destination)
            try NativeVMStorageRegistry(defaultRootURL: rootURL).register(manifest, at: destination)
            if isRunning {
                status = "Debian VM saved. Shut down the running VM, then start Debian. Its console login is in debian-credentials.txt."
                return id
            }
            status = "Starting the fresh Debian VM…"
            try await boot(id, allowWhileInstalling: true)
            return id
        } catch {
            try? FileManager.default.removeItem(at: stage)
            if FileManager.default.fileExists(atPath: destination.appendingPathComponent(NativeVirtualMachineStore.manifestFilename).path) {
                status = "Debian VM was saved, but could not start: \(error.localizedDescription)"
                return id
            }
            status = "Debian VM creation failed: \(error.localizedDescription)"
            return nil
        }
    }

    func install(for provider: VMProvider = .builtIn) async -> VirtualMachineID? {
        guard !isBusy, let imageURL, let restoreImage,
              let requirements = restoreImage.mostFeaturefulSupportedConfiguration else { return nil }
        if let creationResourceError {
            status = creationResourceError
            return nil
        }
        let resources = NativeVMResources(
            cpuCount: creationCPUCount, memoryGiB: creationMemoryGiB, diskGiB: creationDiskGiB
        )
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
        let creationRoot = selectedCreationStorageURL ?? rootURL
        let stage = creationRoot.appendingPathComponent(".creating-\(id.description)", isDirectory: true)
        let destination = creationRoot.appendingPathComponent(id.description, isDirectory: true)
        var presentedInstallerVM: VZVirtualMachine?
        do {
            if let creationStorageValidationMessage {
                status = creationStorageValidationMessage
                return nil
            }
            if selectedCreationStorageURL == nil {
                try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            }
            let sparse = (try? creationRoot.resourceValues(forKeys: [.volumeSupportsSparseFilesKey]))?
                .volumeSupportsSparseFiles == true
            let requiredGiB = NativeVMStorageCapacity.requiredFreeGiB(
                diskGiB: resources.diskGiB, guestOS: .macOS, supportsSparseFiles: sparse
            )
            let capacity = try NativeVMStorageCapacity.availableBytes(at: creationRoot)
            guard capacity >= Int64(requiredGiB) * NativeVMStorageCapacity.bytesPerGiB else {
                throw NativeVMError.insufficientSpace(requiredGiB)
            }
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
            try disk.truncate(atOffset: UInt64(resources.diskGiB) * 1_073_741_824)
            try disk.close()

            let configuration = try makeConfiguration(
                bundle: stage, hardware: hardware, machineID: machineID,
                cpuCount: resources.cpuCount,
                memorySize: UInt64(resources.memoryGiB) * 1_073_741_824,
                includeGuestDisk: false
            )
            let vm = VZVirtualMachine(configuration: configuration)
            if !isRunning {
                virtualMachine = vm
                presentedInstallerVM = vm
                showsDisplay = true
            }
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
            if let presentedInstallerVM, virtualMachine === presentedInstallerVM {
                virtualMachine = nil
                showsDisplay = false
            }

            let version = restoreImage.operatingSystemVersion
            let manifest = NativeVirtualMachineManifest(
                id: id, name: "Tether Host VM · \(id.description.prefix(8))",
                guestImageVersion: "\(version.majorVersion).\(version.minorVersion) (\(restoreImage.buildVersion))",
                resources: resources
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(manifest).write(
                to: stage.appendingPathComponent(NativeVirtualMachineStore.manifestFilename), options: .atomic
            )
            try FileManager.default.moveItem(at: stage, to: destination)
            try NativeVMStorageRegistry(defaultRootURL: rootURL).register(manifest, at: destination)
            if provider == .utm {
                do {
                    try await moveInstalledVMToUTM(id, nativeBundle: destination)
                    status = "Fresh macOS VM registered with UTM. Open it in UTM to finish the welcome screens."
                    return id
                } catch {
                    status = "macOS was installed, but UTM setup could not finish: \(error.localizedDescription) The Apple VM remains saved in Tether Host."
                    return nil
                }
            }
            if isRunning {
                status = "New VM installed and saved. Shut down the running VM, then select this VM and choose Start VM."
                return id
            }
            status = "Starting the fresh VM…"
            try await boot(id, allowWhileInstalling: true)
            return id
        } catch {
            if let presentedInstallerVM, virtualMachine === presentedInstallerVM {
                virtualMachine = nil
                showsDisplay = false
            }
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
        guard guestOS(for: id) == .macOS else {
            status = "Debian VMs can run only with Tether Host's built-in virtualization."
            return false
        }
        guard !isBusy, !isRunning, !hasOtherHostCopy else {
            status = "Shut down the Apple VM and quit any other Tether Host copy before moving it to UTM."
            return false
        }
        guard UTMInstallation.detect() == .installed else {
            status = "Install a compatible UTM in Applications before moving this VM."
            return false
        }
        let locator = VirtualMachineBundleLocator(nativeRoot: rootURL, utmRoots: [])
        guard let nativeBundle = locator.locate(id, provider: .builtIn) else {
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
            status = "UTM setup could not finish: \(error.localizedDescription) The Apple VM is still saved in Tether Host."
            return false
        }
    }

    private func moveInstalledVMToUTM(_ id: VirtualMachineID, nativeBundle: URL) async throws {
        let external = nativeBundle.deletingLastPathComponent() != rootURL
        let packageRoot = external ? nativeBundle.deletingLastPathComponent() :
            rootURL.deletingLastPathComponent().appendingPathComponent("UTM Virtual Machines", isDirectory: true)
        let candidate = packageRoot.appendingPathComponent("\(id.description).utm", isDirectory: true)
        let locator = VirtualMachineBundleLocator(nativeRoot: rootURL, utmRoots: [packageRoot])
        let package: URL
        if FileManager.default.fileExists(atPath: candidate.path) {
            guard locator.locate(id, provider: .utm) == candidate else {
                throw UTMApplePackageError.packageAlreadyExists
            }
            package = candidate
        } else {
            status = "Preparing the guest installer for the UTM VM…"
            let guestISO = FileManager.default.temporaryDirectory
                .appendingPathComponent("tether-guest-\(UUID().uuidString).iso")
            defer { try? FileManager.default.removeItem(at: guestISO) }
            try await GuestSetupDiskExporter.export(appURL: Bundle.main.bundleURL, to: guestISO)
            status = "Preparing a UTM package with the guest installer ready…"
            package = try UTMApplePackageWriter.createPackage(
                nativeBundle: nativeBundle, guestSetupISO: guestISO, in: packageRoot
            )
        }
        status = "Registering the VM with UTM…"
        try await registerWithUTM(package, id: id)
        do {
            let registry = NativeVMStorageRegistry(defaultRootURL: rootURL)
            if external {
                let manifest = try readManifest(at: nativeBundle)
                try registry.registerUTM(id: id, name: manifest.name, at: package)
            }
            try removeNativeBundle(nativeBundle, id: id)
        } catch {
            throw NativeVMError.utmCleanupIncomplete(error.localizedDescription)
        }
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

    func boot(_ id: VirtualMachineID, allowWhileInstalling: Bool = false) async throws {
        guard startingVMID == nil, !isBusy || allowWhileInstalling else { throw NativeVMError.cannotStartDuringInstall }
        if isRunning, runningID == id { showsDisplay = true; return }
        if isRunning { throw NativeVMError.anotherVMRunning }
        guard !hasOtherHostCopy else { throw NativeVMError.anotherHostCopyRunning }
        // Reserve the lifecycle before the first await: repeated clicks must not
        // create a second VZVirtualMachine while the first one is still starting.
        let wasBusy = isBusy
        isBusy = true
        startingVMID = id
        defer {
            startingVMID = nil
            isBusy = wasBusy
        }
        let locator = VirtualMachineBundleLocator(nativeRoot: rootURL, utmRoots: [])
        guard let bundle = locator.locate(id, provider: .builtIn) else { throw NativeVMError.missingVM }
        let manifestURL = bundle.appendingPathComponent(NativeVirtualMachineStore.manifestFilename)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(NativeVirtualMachineManifest.self, from: Data(contentsOf: manifestURL)),
              manifest.id == id,
              manifest.schemaVersion == NativeVirtualMachineManifest.currentSchemaVersion else {
            throw NativeVMError.invalidVM
        }
        if manifest.guestOS == .debian {
            try await bootDebian(id, bundle: bundle, manifest: manifest)
            return
        }
        guard await prepareGuestDisk() else { throw NativeVMError.guestDiskUnavailable }
        let hardwareData = try Data(contentsOf: bundle.appendingPathComponent("hardware.bin"))
        let machineData = try Data(contentsOf: bundle.appendingPathComponent("machine.bin"))
        guard let hardware = VZMacHardwareModel(dataRepresentation: hardwareData),
              let machineID = VZMacMachineIdentifier(dataRepresentation: machineData),
              hardware.isSupported else { throw NativeVMError.invalidVM }
        // Old manifests did not store resources; preserve their launch behavior.
        let cpuCount = manifest.resources?.cpuCount ?? min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        let memoryGiB = manifest.resources?.memoryGiB ?? 8
        guard cpuCount > 0, memoryGiB > 0,
              cpuCount <= VZVirtualMachineConfiguration.maximumAllowedCPUCount,
              UInt64(memoryGiB) <= VZVirtualMachineConfiguration.maximumAllowedMemorySize / 1_073_741_824 else {
            throw NativeVMError.invalidVM
        }
        let configuration = try makeConfiguration(
            bundle: bundle, hardware: hardware, machineID: machineID,
            cpuCount: cpuCount,
            memorySize: UInt64(memoryGiB) * 1_073_741_824, includeGuestDisk: true
        )
        let vm = VZVirtualMachine(configuration: configuration)
        vm.delegate = vmDelegate
        virtualMachine = vm
        do {
            try await vm.start()
            guard virtualMachine === vm, vm.state == .running else { throw NativeVMError.invalidVM }
            runningID = id
            isRunning = true
            runningGuestOS = .macOS
            shutdownRequested = false
            showsDisplay = true
            markBundleUsed(id)
            status = "VM started. Finish macOS setup or sign in to continue."
        } catch {
            virtualMachine = nil
            showsDisplay = false
            status = "Could not boot the VM: \(error.localizedDescription)"
            throw error
        }
    }

    private func bootDebian(_ id: VirtualMachineID, bundle: URL,
                            manifest: NativeVirtualMachineManifest) async throws {
        let machineData = try Data(contentsOf: bundle.appendingPathComponent("machine.bin"))
        guard let machineID = VZGenericMachineIdentifier(dataRepresentation: machineData) else {
            throw NativeVMError.invalidVM
        }
        let cpuCount = manifest.resources?.cpuCount ?? 4
        let memoryGiB = manifest.resources?.memoryGiB ?? 8
        guard cpuCount >= VZVirtualMachineConfiguration.minimumAllowedCPUCount,
              cpuCount <= VZVirtualMachineConfiguration.maximumAllowedCPUCount,
              memoryGiB > 0,
              UInt64(memoryGiB) * 1_073_741_824 >= VZVirtualMachineConfiguration.minimumAllowedMemorySize,
              UInt64(memoryGiB) * 1_073_741_824 <= VZVirtualMachineConfiguration.maximumAllowedMemorySize else {
            throw NativeVMError.invalidVM
        }
        let serialURL = bundle.appendingPathComponent("serial.log")
        if !FileManager.default.fileExists(atPath: serialURL.path) {
            FileManager.default.createFile(atPath: serialURL.path, contents: nil)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: serialURL.path)
        let logHandle = try FileHandle(forWritingTo: serialURL)
        try logHandle.seekToEnd()
        do {
            let configuration = try makeDebianConfiguration(
                bundle: bundle, machineID: machineID, cpuCount: cpuCount,
                memorySize: UInt64(memoryGiB) * 1_073_741_824,
                serialLogHandle: logHandle
            )
            let vm = VZVirtualMachine(configuration: configuration)
            vm.delegate = vmDelegate
            virtualMachine = vm
            try await vm.start()
            guard virtualMachine === vm, vm.state == .running else { throw NativeVMError.invalidVM }
            serialLogHandle = logHandle
            runningID = id
            isRunning = true
            runningGuestOS = .debian
            shutdownRequested = false
            showsDisplay = true
            markBundleUsed(id)
            status = "Debian is starting. On first boot, wait while Xfce, Chromium, and guest setup tools are prepared."
        } catch {
            try? logHandle.close()
            virtualMachine = nil
            showsDisplay = false
            status = "Could not boot Debian: \(error.localizedDescription)"
            throw error
        }
    }

    func startOrShow(_ id: VirtualMachineID) async {
        do { try await boot(id) }
        catch {
            status = "Could not start the VM: \(error.localizedDescription) If another Tether Host copy is open, quit it and try again."
        }
    }

    func requestShutdown(for id: VirtualMachineID? = nil) {
        guard isRunning, !isBusy, !shutdownRequested,
              id == nil || runningID == id, let virtualMachine else { return }
        do {
            try virtualMachine.requestStop()
            shutdownRequested = true
            status = "Asked the guest to shut down. Wait for the VM status to change to Off."
        } catch {
            status = "The guest did not accept the shutdown request: \(error.localizedDescription)"
        }
    }

    /// Clipboard text moves only after an explicit host UI action. The guest
    /// installer listens on this private VM socket; neither clipboard is polled.
    func readGuestClipboardText() async throws -> String {
        try await transferGuestClipboard(opcode: 1, text: nil)
    }

    /// Checks the guest bridge without reading or changing either clipboard.
    func checkGuestClipboardConnection() async throws {
        _ = try await transferGuestClipboard(opcode: 4, text: nil)
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

    func forcePowerOff(for id: VirtualMachineID? = nil) async {
        guard isRunning, !isBusy, id == nil || runningID == id,
              let virtualMachine else { return }
        isBusy = true
        forcePowerOffRequested = true
        status = "Powering off the VM…"
        defer { isBusy = false }
        do {
            try await virtualMachine.stop()
            // A host-initiated stop completes here; guestDidStop is only for
            // guest-initiated shutdown. Release state even if no delegate fires.
            guestStopped(ObjectIdentifier(virtualMachine), error: nil)
        } catch {
            if virtualMachine.state == .stopped {
                guestStopped(ObjectIdentifier(virtualMachine), error: nil)
                return
            }
            forcePowerOffRequested = false
            status = "Could not power off the VM: \(error.localizedDescription)"
        }
    }

    func deleteFiles(_ id: VirtualMachineID) throws {
        guard !isBusy else { throw NativeVMError.cannotRemoveDuringInstall }
        guard !isRunning else { throw NativeVMError.cannotRemoveRunningVM }
        guard !hasOtherHostCopy else { throw NativeVMError.cannotRemoveWithOtherHostCopy }
        let locator = VirtualMachineBundleLocator(nativeRoot: rootURL, utmRoots: [])
        guard let bundle = locator.locate(id, provider: .builtIn) else { throw NativeVMError.missingVM }
        try removeNativeBundle(bundle, id: id)
        clearDesktopReady(for: id)
        status = "Tether Host VM \(id.description) and its files were deleted."
    }

    private func readManifest(at bundle: URL) throws -> NativeVirtualMachineManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NativeVirtualMachineManifest.self,
                                  from: Data(contentsOf: bundle.appendingPathComponent(NativeVirtualMachineStore.manifestFilename)))
    }

    private func removeNativeBundle(_ bundle: URL, id: VirtualMachineID) throws {
        let registry = NativeVMStorageRegistry(defaultRootURL: rootURL)
        let external = bundle.deletingLastPathComponent() != rootURL
        let manifest = external ? try readManifest(at: bundle) : nil
        if external { try registry.unregister(id) }
        do {
            try FileManager.default.removeItem(at: bundle)
        } catch {
            if let manifest { try? registry.register(manifest, at: bundle) }
            throw error
        }
    }

    var hasOtherHostCopy: Bool {
        #if TETHER_E2E
        let normalizedRoot = rootURL.standardizedFileURL.path
        if rootURLWasOverridden,
           Bundle.main.bundleIdentifier == "app.tether.debian.e2e",
           (normalizedRoot == "/tmp/tether-debian-e2e" ||
            normalizedRoot.hasPrefix("/tmp/tether-debian-e2e/") ||
            normalizedRoot.hasPrefix("/tmp/tether-debian-e2e-")) {
            return false
        }
        #endif
        return NSRunningApplication.runningApplications(withBundleIdentifier: "app.tether.host")
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
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
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

    private func makeDebianConfiguration(
        bundle: URL, machineID: VZGenericMachineIdentifier,
        cpuCount: Int, memorySize: UInt64, serialLogHandle: FileHandle?
    ) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: bundle.appendingPathComponent("efi-vars.bin"))
        configuration.bootLoader = bootLoader
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = machineID
        configuration.platform = platform
        configuration.cpuCount = cpuCount
        configuration.memorySize = memorySize
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1600,
                                                                  heightInPixels: 1000)]
        configuration.graphicsDevices = [graphics]
        let network = VZVirtioNetworkDeviceConfiguration()
        network.macAddress = try debianMACAddress(in: bundle)
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]
        let disk = try VZDiskImageStorageDeviceAttachment(
            url: bundle.appendingPathComponent("disk.img"), readOnly: false)
        let seed = try VZDiskImageStorageDeviceAttachment(
            url: bundle.appendingPathComponent("seed.iso"), readOnly: true)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk),
                                        VZVirtioBlockDeviceConfiguration(attachment: seed)]
        let toolsDisk = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Tether Debian Guest Tools.img")
        guard FileManager.default.fileExists(atPath: toolsDisk.path) else {
            throw NativeVMError.guestDiskUnavailable
        }
        let attachment = try VZDiskImageStorageDeviceAttachment(url: toolsDisk, readOnly: true)
        configuration.storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
        if let serialLogHandle {
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: serialInputHandleOverride,
                fileHandleForWriting: serialLogHandle)
            configuration.serialPorts = [serial]
        }
        try configuration.validate()
        return configuration
    }

    private func debianMACAddress(in bundle: URL) throws -> VZMACAddress {
        let file = bundle.appendingPathComponent("network.mac")
        if FileManager.default.fileExists(atPath: file.path) {
            let stored = try String(contentsOf: file, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let address = VZMACAddress(string: stored),
                  address.isLocallyAdministeredAddress,
                  address.isUnicastAddress else { throw NativeVMError.invalidVM }
            return address
        }
        // VZ otherwise creates a different MAC on every launch. Debian's
        // persistent network configuration and DHCP identity need one address.
        let address = VZMACAddress.randomLocallyAdministered()
        try Data("\(address.string)\n".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return address
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

    fileprivate func guestStopped(_ identity: ObjectIdentifier, error: Error?) {
        guard virtualMachine.map(ObjectIdentifier.init) == identity else { return }
        if let runningID {
            markBundleUsed(runningID)
        }
        forcePowerOffRequested = false
        isRunning = false
        shutdownRequested = false
        runningID = nil
        try? serialLogHandle?.close()
        serialLogHandle = nil
        runningGuestOS = .macOS
        virtualMachine = nil
        showsDisplay = false
        status = error.map { "The VM stopped: \($0.localizedDescription)" } ?? "The VM is off. Choose Start VM to resume."
    }

    private func markBundleUsed(_ id: VirtualMachineID) {
        let locator = VirtualMachineBundleLocator(nativeRoot: rootURL, utmRoots: [])
        if let bundle = locator.locate(id, provider: .builtIn) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: bundle.path)
        }
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
        if (opcode == 2 || opcode == 4) && !text.isEmpty { throw GuestClipboardError.invalidResponse }
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
        Task { @MainActor [weak owner] in owner?.guestStopped(identity, error: nil) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        let identity = ObjectIdentifier(virtualMachine)
        Task { @MainActor [weak owner] in owner?.guestStopped(identity, error: error) }
    }
}

enum NativeVMTypeTextError: LocalizedError {
    case empty
    case tooLong
    case unsupportedCharacter
    case displayUnavailable
    case vmNotRunning
    case alreadyTyping
    case eventUnavailable

    var errorDescription: String? {
        switch self {
        case .empty: "The clipboard has no text to type."
        case .tooLong: "Paste as typing supports up to 4,096 characters. Use the guest clipboard after signing in for longer text."
        case .unsupportedCharacter: "Paste as typing supports printable US keyboard characters only. Use the guest clipboard after signing in for other text."
        case .displayUnavailable: "Show this VM's display before pasting as typing."
        case .vmNotRunning: "Start the VM before pasting as typing."
        case .alreadyTyping: "Wait for the current paste to finish."
        case .eventUnavailable: "The VM display could not receive a key event. Try again."
        }
    }
}

@MainActor
struct NativeVMDisplay: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine
    private static weak var registeredView: VZVirtualMachineView?
    private static var isTyping = false

    private struct Stroke {
        let keyCode: UInt16
        let base: Character
        let rendered: Character
        let shift: Bool
    }

    /// Uses the VM's virtual keyboard before any guest clipboard service exists.
    /// The caller owns clipboard access; this method never reads, logs, or stores text.
    static func typeText(_ text: String, into vm: VZVirtualMachine) async throws {
        guard !text.isEmpty else { throw NativeVMTypeTextError.empty }
        guard text.utf8.count <= 4_096 else { throw NativeVMTypeTextError.tooLong }
        // Resolve every key before sending the first one, so unsupported text
        // never leaves a partially typed password in the guest.
        let strokes = try text.unicodeScalars.map { scalar -> Stroke in
            guard (0x20...0x7e).contains(scalar.value) else {
                throw NativeVMTypeTextError.unsupportedCharacter
            }
            let rendered = Character(String(scalar))
            let base: Character
            let shift: Bool
            if (0x41...0x5a).contains(scalar.value) {
                base = Character(String(scalar).lowercased())
                shift = true
            } else if let shiftedBase = shiftedBases[rendered] {
                base = shiftedBase
                shift = true
            } else {
                base = rendered
                shift = false
            }
            guard let keyCode = keyCodes[base] else {
                throw NativeVMTypeTextError.unsupportedCharacter
            }
            return Stroke(keyCode: keyCode, base: base, rendered: rendered, shift: shift)
        }
        guard !isTyping else { throw NativeVMTypeTextError.alreadyTyping }
        guard vm.state == .running else { throw NativeVMTypeTextError.vmNotRunning }
        guard let view = registeredView, view.virtualMachine === vm,
              let window = view.window, window.makeFirstResponder(view) else {
            throw NativeVMTypeTextError.displayUnavailable
        }

        isTyping = true
        var shiftDown = false
        defer {
            if shiftDown { try? sendShift(false, to: view) }
            isTyping = false
        }
        for stroke in strokes {
            try Task.checkCancellation()
            guard vm.state == .running, view.window === window,
                  window.firstResponder === view, view.virtualMachine === vm else {
                throw NativeVMTypeTextError.displayUnavailable
            }
            if stroke.shift != shiftDown {
                try sendShift(stroke.shift, to: view)
                shiftDown = stroke.shift
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let down = keyEvent(.keyDown, stroke: stroke, view: view),
                  let up = keyEvent(.keyUp, stroke: stroke, view: view) else {
                throw NativeVMTypeTextError.eventUnavailable
            }
            view.keyDown(with: down)
            view.keyUp(with: up)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func sendShift(_ pressed: Bool, to view: VZVirtualMachineView) throws {
        guard let event = NSEvent.keyEvent(
            with: .flagsChanged, location: .zero,
            modifierFlags: pressed ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56
        ) else { throw NativeVMTypeTextError.eventUnavailable }
        view.flagsChanged(with: event)
    }

    private static func keyEvent(_ type: NSEvent.EventType, stroke: Stroke,
                                 view: VZVirtualMachineView) -> NSEvent? {
        NSEvent.keyEvent(
            with: type, location: .zero,
            modifierFlags: stroke.shift ? [.shift] : [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil,
            // AppKit preserves Shift in charactersIgnoringModifiers.
            characters: String(stroke.rendered), charactersIgnoringModifiers: String(stroke.rendered),
            isARepeat: false, keyCode: stroke.keyCode
        )
    }

    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32,
        "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40,
        ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        " ": 49, "`": 50
    ]
    private static let shiftedBases: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", ":": ";", "\"": "'",
        "|": "\\", "<": ",", ">": ".", "?": "/", "~": "`"
    ]

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        Self.registeredView = view
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        view.virtualMachine = virtualMachine
        Self.registeredView = view
    }
}
