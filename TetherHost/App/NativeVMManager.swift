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
    case invalidResources(String)
    case noCompatibleDownload(host: String)
    case imageCatalogUnavailable
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
            "This is a macOS \(guest) IPSW, but this Mac runs macOS \(host). Choose a macOS \(host) IPSW or update this Mac first."
        case .insufficientSpace: "At least 45 GB of free disk space is needed to install a fresh macOS VM."
        case .insufficientDownloadSpace: "At least 65 GB of free disk space is needed to download macOS and install a fresh VM."
        case .invalidResources(let message): message
        case .noCompatibleDownload(let host): "No downloadable macOS IPSW was found for macOS \(host). Update this Mac or choose a compatible IPSW manually."
        case .imageCatalogUnavailable: "Could not check available macOS images. Check your internet connection, try again, or choose a compatible IPSW manually."
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

    static var canDownloadHostImage: Bool {
        true // Keep the action visible so unsupported hosts receive an explanation.
    }

    @Published private(set) var imageURL: URL?
    @Published private(set) var imageDescription = "Choose a macOS IPSW to create a fresh VM."
    @Published private(set) var status = "No VM installation has started."
    @Published private(set) var isBusy = false
    @Published private(set) var installationProgress: Double?
    @Published private(set) var downloadProgress: DownloadProgressEstimate?
    @Published private(set) var downloadImageOptions: [RestoreImageDownloadOption] = []
    @Published var selectedDownloadVersion = ""
    @Published private(set) var recommendedDownloadVersion = ""
    @Published private(set) var isLoadingDownloadImageOptions = false
    @Published private(set) var isRunning = false
    @Published private(set) var shutdownRequested = false
    @Published private(set) var virtualMachine: VZVirtualMachine?
    @Published private(set) var desktopReadyVMID: VirtualMachineID?
    @Published var showsDisplay = false
    @Published var creationCPUCount: Int
    @Published var creationMemoryGiB: Int
    @Published var creationDiskGiB: Int

    private var restoreImage: VZMacOSRestoreImage?
    private var activeDownloadID: UUID?
    private var downloadCandidates: [RemoteRestoreCandidate] = []
    private var runningID: VirtualMachineID?
    var runningVMID: VirtualMachineID? { isRunning ? runningID : nil }
    private let rootURL: URL
    private let vmDelegate = NativeVMDelegate()
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        let defaults = Self.baseResourceLimits.defaults
        creationCPUCount = defaults.cpuCount
        creationMemoryGiB = defaults.memoryGiB
        creationDiskGiB = defaults.diskGiB
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
            minimumCPUCount: restoreImage?.mostFeaturefulSupportedConfiguration?.minimumSupportedCPUCount ?? 2,
            minimumMemoryBytes: restoreImage?.mostFeaturefulSupportedConfiguration?.minimumSupportedMemorySize ?? 4 * 1_073_741_824,
            maximumCPUCount: VZVirtualMachineConfiguration.maximumAllowedCPUCount,
            maximumMemoryBytes: VZVirtualMachineConfiguration.maximumAllowedMemorySize
        )
    }

    var creationCPURange: ClosedRange<Int> { creationLimits.cpu }
    var creationMemoryRange: ClosedRange<Int> { creationLimits.memoryGiB }
    var creationDiskRange: ClosedRange<Int> { creationLimits.diskGiB }
    var creationResourceError: String? {
        creationLimits.validationMessage(for: NativeVMResources(
            cpuCount: creationCPUCount, memoryGiB: creationMemoryGiB, diskGiB: creationDiskGiB
        ))
    }

    func resetCreationResources() {
        let defaults = creationLimits.defaults
        creationCPUCount = defaults.cpuCount
        creationMemoryGiB = defaults.memoryGiB
        creationDiskGiB = defaults.diskGiB
    }

    private var restoreCacheDirectory: URL {
        rootURL.deletingLastPathComponent()
            .appendingPathComponent("Restore Images", isDirectory: true)
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
            try disk.truncate(atOffset: UInt64(resources.diskGiB) * 1_073_741_824)
            try disk.close()

            let configuration = try makeConfiguration(
                bundle: stage, hardware: hardware, machineID: machineID,
                cpuCount: resources.cpuCount,
                memorySize: UInt64(resources.memoryGiB) * 1_073_741_824,
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
        let manifestURL = bundle.appendingPathComponent(NativeVirtualMachineStore.manifestFilename)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(NativeVirtualMachineManifest.self, from: Data(contentsOf: manifestURL)),
              manifest.id == id,
              manifest.schemaVersion == NativeVirtualMachineManifest.currentSchemaVersion else {
            throw NativeVMError.invalidVM
        }
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
            runningID = id
            isRunning = true
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
        status = error.map { "The VM stopped: \($0.localizedDescription)" } ?? "The VM is off. Choose Start VM to resume."
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
        view.automaticallyReconfiguresDisplay = true
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        view.virtualMachine = virtualMachine
    }
}
