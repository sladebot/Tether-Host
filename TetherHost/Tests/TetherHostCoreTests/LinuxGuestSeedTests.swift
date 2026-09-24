import Foundation
import XCTest
@testable import TetherHostCore

final class LinuxGuestSeedTests: XCTestCase {
    func testManifestDecodesLegacyMacOSAndRoundTripsUbuntu() throws {
        let id = VirtualMachineID(rawValue: UUID())
        let manifest = NativeVirtualMachineManifest(
            id: id, guestImageVersion: "24.04", resources: NativeVMResources(cpuCount: 2, memoryGiB: 4, diskGiB: 24),
            guestOS: .ubuntu
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        XCTAssertEqual(try decoder.decode(NativeVirtualMachineManifest.self, from: data).guestOS, .ubuntu)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "guestOS")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try decoder.decode(NativeVirtualMachineManifest.self, from: legacyData)
        XCTAssertEqual(decoded.guestOS, .macOS)
        XCTAssertEqual(decoded.id, id)
    }

    func testCloudInitProvidesConsoleUserAndDoesNotCopySeedSecretsToGuestSetup() throws {
        let seed = LinuxGuestSeedWriter.userData(password: "TESTONEUSEPASSWORD")
        XCTAssertTrue(seed.contains("password: TESTONEUSEPASSWORD"))
        XCTAssertTrue(seed.contains("expire: true"))
        XCTAssertTrue(seed.contains("ssh_pwauth: false"))
        XCTAssertTrue(seed.contains("--no-install-recommends"))
        XCTAssertTrue(seed.contains("tether-vsock.service"))
        XCTAssertTrue(seed.contains("tether-guest-installer.desktop"))
        XCTAssertTrue(seed.contains("/opt/tether-guest/guest_installer.py"))
        XCTAssertTrue(seed.contains("/mnt/tether-seed/installer_flow.py"))
        XCTAssertTrue(seed.contains("/mnt/tether-seed/update-guest-tools.sh"))
        XCTAssertTrue(seed.contains("/mnt/tether-seed/installer-version.json"))
        XCTAssertTrue(seed.contains("gir1.2-vte-2.91"))
        XCTAssertTrue(seed.contains("tether-hermes-desktop.desktop"))
        XCTAssertTrue(seed.contains("tether-text-clipboard.desktop"))
        XCTAssertTrue(seed.contains("/mnt/tether-seed/clipboard-toggle.sh"))
        XCTAssertTrue(seed.contains("/mnt/tether-seed/clipboard_broker.py"))
        XCTAssertTrue(seed.contains("xclip"))
        XCTAssertTrue(seed.contains("session-start.sh"))
        XCTAssertFalse(seed.contains("serial-getty@hvc0.service"))
        XCTAssertTrue(seed.contains("TETHER_CLOUD_INIT_START"))
        XCTAssertTrue(seed.contains("TETHER_CLOUD_INIT_DONE"))
        XCTAssertTrue(seed.contains("APT::Update::Error-Mode=any"))
        XCTAssertTrue(seed.contains("set -e"))
        XCTAssertTrue(seed.contains("tether-dns-fallback.service"))
        let fallback = try XCTUnwrap(seed.range(of: "- [/opt/tether-guest/dns-fallback.sh]"))
        let update = try XCTUnwrap(seed.range(of: "apt-get update -o APT::Update::Error-Mode=any"))
        let install = try XCTUnwrap(seed.range(of: "apt-get, install, -y"))
        XCTAssertLessThan(fallback.lowerBound, update.lowerBound)
        XCTAssertLessThan(update.lowerBound, install.lowerBound)
        XCTAssertFalse(seed.contains("/mnt/tether-seed/README.txt, /opt/tether-guest/"))
        XCTAssertFalse(seed.contains("/mnt/tether-seed/."))
    }

    func testMissingGuestResourcesDoesNotCreateSeed() async throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-empty-seed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundle) }
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        do {
            _ = try await LinuxGuestSeedWriter.createSeed(
                in: bundle, vmID: VirtualMachineID(rawValue: UUID()), guestResourcesURL: nil
            )
            XCTFail("Expected missing guest resources to be rejected")
        } catch LinuxGuestSeedError.missingResources {
            XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("seed.iso").path))
        }
    }

    func testManualDNSSeedOnlyRepairsDNSAndLeavesInstallationInteractive() throws {
        let seed = ManualUbuntuDNSSeedWriter.userData(script: "#!/bin/sh\necho test\n")
        XCTAssertTrue(seed.hasPrefix("#cloud-config\nusers: []\n"))
        XCTAssertFalse(seed.contains("autoinstall:"))
        XCTAssertFalse(seed.contains("chpasswd:"))
        XCTAssertFalse(seed.contains("network-config"))
        XCTAssertTrue(seed.contains("tether-dns-fallback.service"))
        XCTAssertTrue(seed.contains("tether-dns-fallback.timer"))
        XCTAssertTrue(seed.contains("90-tether-dns-fallback"))
        XCTAssertTrue(seed.contains("dhcp4-change"))
        XCTAssertTrue(seed.contains("TETHER_MANUAL_DNS_READY"))
        XCTAssertTrue(seed.contains("TETHER_MANUAL_DNS_FAILED"))
        XCTAssertTrue(seed.contains(Data("#!/bin/sh\necho test\n".utf8).base64EncodedString()))
    }

    func testManualDNSSeedCreationAndIdempotence() async throws {
        let fm = FileManager.default
        let bundle = fm.temporaryDirectory.appendingPathComponent("tether-manual-dns-\(UUID().uuidString)")
        let resources = bundle.appendingPathComponent("resources")
        defer { try? fm.removeItem(at: bundle) }
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8)
            .write(to: resources.appendingPathComponent("dns-fallback.sh"))
        let id = VirtualMachineID(rawValue: UUID())
        let seed = try await ManualUbuntuDNSSeedWriter.ensureSeed(in: bundle, vmID: id, guestResourcesURL: resources)
        XCTAssertTrue(fm.fileExists(atPath: seed.path))
        let firstModification = try seed.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let second = try await ManualUbuntuDNSSeedWriter.ensureSeed(in: bundle, vmID: id, guestResourcesURL: resources)
        XCTAssertEqual(second, seed)
        XCTAssertEqual(try second.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       firstModification)
    }
}
