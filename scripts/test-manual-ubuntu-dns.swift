import AppKit
import Foundation
import Virtualization
import TetherHostCore

@main
struct ManualDNSCheck {
    @MainActor static var window: NSWindow?
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 4 else { fatalError("Usage: test ROOT ISO RESOURCES") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard root.path.hasPrefix("/private/tmp/tether-ubuntu-e2e-dns"), !FileManager.default.fileExists(atPath: root.path) else { fatalError("Use a fresh isolated test root") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seed = try await ManualUbuntuDNSSeedWriter.ensureSeed(in: root, vmID: VirtualMachineID(rawValue: UUID()), guestResourcesURL: URL(fileURLWithPath: CommandLine.arguments[3]))
        let disk = root.appendingPathComponent("disk.img")
        FileManager.default.createFile(atPath: disk.path, contents: nil)
        let diskHandle = try FileHandle(forWritingTo: disk)
        try diskHandle.truncate(atOffset: 24 * 1024 * 1024 * 1024)
        try diskHandle.close()
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = 2
        config.memorySize = 4 * 1024 * 1024 * 1024
        let loader = VZEFIBootLoader()
        loader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: root.appendingPathComponent("efi.bin"))
        config.bootLoader = loader
        config.platform = VZGenericPlatformConfiguration()
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1024, heightInPixels: 768)]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)),
            VZUSBMassStorageDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: CommandLine.arguments[2]), readOnly: true)),
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: seed, readOnly: true))]
        let log = root.appendingPathComponent("serial.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: output)
        config.serialPorts = [serial]
        try config.validate()
        let vm = VZVirtualMachine(configuration: config)
        let view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
        view.virtualMachine = vm
        let panel = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Tether isolated Ubuntu DNS test"
        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)
        window = panel
        NSApplication.shared.setActivationPolicy(.regular)
        try await vm.start()
        print("Isolated live Ubuntu DNS test started; log: \(log.path)")
        for _ in 0..<240 {
            try await Task.sleep(for: .seconds(2))
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if text.contains("TETHER_MANUAL_DNS_READY") {
                print("TETHER_MANUAL_DNS_READY verified on stock desktop ISO")
                try await vm.stop()
                return
            }
        }
        try await vm.stop()
        throw NSError(domain: "ManualDNSCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "No DNS-ready marker within 8 minutes; inspect serial.log"])
    }
}
