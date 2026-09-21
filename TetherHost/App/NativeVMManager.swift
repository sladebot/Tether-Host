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
        }
    }
}

@MainActor
final class NativeVMManager: ObservableObject {
    private static let macOS262URL = URL(string: "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-37399/E144C918-CF99-4BBC-B1D0-3E739B9A3F2D/UniversalMac_26.2_25C56_Restore.ipsw")!
    private static let macOS262SHA256 = "bc7c67b2a2cc4ac8c9da0c2b149b9f31e153cd542ce387e6fb8620e41b5278ef"

    static var canDownloadHostImage: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion == 26 && version.minorVersion == 2
    }

    @Published private(set) var imageURL: URL?
    @Published private(set) var imageDescription = "Choose a macOS IPSW to create a fresh VM."
    @Published private(set) var status = "No VM installation has started."
    @Published private(set) var isBusy = false
    @Published private(set) var isRunning = false
    @Published private(set) var virtualMachine: VZVirtualMachine?
    @Published var showsDisplay = false

    private var restoreImage: VZMacOSRestoreImage?
    private var runningID: VirtualMachineID?
    var runningVMID: VirtualMachineID? { isRunning ? runningID : nil }
    private let rootURL: URL
    private let vmDelegate = NativeVMDelegate()

    init() {
        rootURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tether Host for Mac/Virtual Machines", isDirectory: true)
        vmDelegate.owner = self
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
            let version = image.operatingSystemVersion
            imageDescription = "macOS \(version.majorVersion).\(version.minorVersion) (\(image.buildVersion)) — compatible with this Mac"
            status = "Ready to create a new, separate Tether Host VM."
        } catch {
            restoreImage = nil
            imageURL = nil
            imageDescription = "No compatible macOS IPSW selected."
            status = error.localizedDescription
        }
    }

    func downloadHostImage() async {
        guard Self.canDownloadHostImage, !isBusy else { return }
        isBusy = true
        status = "Downloading macOS 26.2 from Apple's servers (about 18 GB)…"
        let destination = rootURL.deletingLastPathComponent()
            .appendingPathComponent("Restore Images/UniversalMac_26.2_25C56_Restore.ipsw")
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let available = try destination.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? 0
            guard available >= 65 * 1_073_741_824 || FileManager.default.fileExists(atPath: destination.path) else {
                throw NativeVMError.insufficientDownloadSpace
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                let digest = try await Self.sha256(of: destination)
                if digest != Self.macOS262SHA256 { try FileManager.default.removeItem(at: destination) }
            }
            if !FileManager.default.fileExists(atPath: destination.path) {
                let (temporary, response) = try await URLSession.shared.download(from: Self.macOS262URL)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      response.url?.host == "updates.cdn-apple.com" else {
                    throw URLError(.badServerResponse)
                }
                status = "Verifying the downloaded IPSW…"
                let digest = try await Self.sha256(of: temporary)
                guard digest == Self.macOS262SHA256 else { throw NativeVMError.unsupportedImage }
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

    func install() async -> VirtualMachineID? {
        guard !isBusy, let imageURL, let restoreImage,
              let requirements = restoreImage.mostFeaturefulSupportedConfiguration else { return nil }
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
            try await installer.install()
            if vm.state == .running { try await vm.stop() }
            virtualMachine = nil
            showsDisplay = false

            let version = restoreImage.operatingSystemVersion
            let manifest = NativeVirtualMachineManifest(
                id: id, name: "Tether Host VM",
                guestImageVersion: "\(version.majorVersion).\(version.minorVersion) (\(restoreImage.buildVersion))"
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(manifest).write(
                to: stage.appendingPathComponent(NativeVirtualMachineStore.manifestFilename), options: .atomic
            )
            try FileManager.default.moveItem(at: stage, to: destination)
            status = "macOS installed. Preparing its Tether guest setup disk…"
            await prepareGuestDisk()
            status = "Starting the fresh VM…"
            try await boot(id)
            return id
        } catch {
            virtualMachine = nil
            showsDisplay = false
            try? FileManager.default.removeItem(at: stage)
            status = "VM installation failed: \(error.localizedDescription)"
            return nil
        }
    }

    func boot(_ id: VirtualMachineID) async throws {
        guard !isBusy || virtualMachine == nil else { return }
        if isRunning, runningID == id { showsDisplay = true; return }
        if isRunning { throw NativeVMError.anotherVMRunning }
        let bundle = rootURL.appendingPathComponent(id.description, isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundle.path) else { throw NativeVMError.missingVM }
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
        showsDisplay = true
        do {
            try await vm.start()
            runningID = id
            isRunning = true
            status = "Tether Host VM started. Finish the macOS welcome screens in this window."
        } catch {
            virtualMachine = nil
            showsDisplay = false
            status = "Could not boot the VM: \(error.localizedDescription)"
            throw error
        }
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

    func prepareGuestDisk() async {
        let destination = rootURL.deletingLastPathComponent().appendingPathComponent("Tether Guest Setup.iso")
        do {
            status = "Preparing the guest setup disk…"
            try await GuestSetupDiskExporter.export(appURL: Bundle.main.bundleURL, to: destination)
            status = "Guest setup disk is ready. It will appear when the VM next starts."
        } catch { status = "Guest setup disk failed: \(error.localizedDescription)" }
    }

    fileprivate func guestStopped(error: Error?) {
        isRunning = false
        runningID = nil
        virtualMachine = nil
        showsDisplay = false
        status = error.map { "The VM stopped: \($0.localizedDescription)" } ?? "The VM shut down. Select Start / Show to boot it again."
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
