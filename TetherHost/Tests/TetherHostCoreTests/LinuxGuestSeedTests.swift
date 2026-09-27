import Foundation
import XCTest
@testable import TetherHostCore

final class LinuxGuestSeedTests: XCTestCase {
    func testManifestDecodesLegacyMacOSAndRoundTripsDebian() throws {
        let id = VirtualMachineID(rawValue: UUID())
        let manifest = NativeVirtualMachineManifest(
            id: id, guestImageVersion: "13", resources: NativeVMResources(cpuCount: 2, memoryGiB: 4, diskGiB: 24),
            guestOS: .debian
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        XCTAssertEqual(try decoder.decode(NativeVirtualMachineManifest.self, from: data).guestOS, .debian)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "guestOS")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try decoder.decode(NativeVirtualMachineManifest.self, from: legacyData)
        XCTAssertEqual(decoded.guestOS, .macOS)
        XCTAssertEqual(decoded.id, id)
    }

    func testDebianAccountValidation() {
        XCTAssertNil(DebianAccountSetup.usernameError("souranil_2"))
        for invalid in ["", "root", "Uppercase", "bad name", "bad:name", "user\nroot"] {
            XCTAssertNotNil(DebianAccountSetup.usernameError(invalid), invalid)
        }
        XCTAssertNil(DebianAccountSetup.passwordError("long!Password123", confirmation: "long!Password123"))
        XCTAssertNotNil(DebianAccountSetup.passwordError("short", confirmation: "short"))
        XCTAssertNotNil(DebianAccountSetup.passwordError("long!Password123", confirmation: "different"))
        XCTAssertNotNil(DebianAccountSetup.passwordError("long!Password\n123", confirmation: "long!Password\n123"))
    }

    func testSHA512CryptMatchesOpenSSLVector() {
        XCTAssertEqual(DebianPasswordHash.make("Hello world!", salt: "saltstring"),
                       "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1")
    }

    func testCloudInitUsesChosenUserAndOnlyPasswordHash() throws {
        let hash = DebianPasswordHash.make("TESTONEUSEPASSWORD", salt: "0123456789abcdef")
        let seed = LinuxGuestSeedWriter.userData(username: "alice", passwordHash: hash)
        XCTAssertTrue(seed.contains("name: alice"))
        XCTAssertTrue(seed.contains("User=alice"))
        XCTAssertTrue(seed.contains("Group=alice"))
        XCTAssertTrue(seed.contains("/etc/tether-guest/user"))
        XCTAssertTrue(seed.contains("password: '\(hash)'"))
        XCTAssertFalse(seed.contains("TESTONEUSEPASSWORD"))
        XCTAssertTrue(seed.contains("expire: false"))
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
        XCTAssertTrue(seed.contains("chromium, chromium-driver"))
        XCTAssertTrue(seed.contains("user-session=xfce"))
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
                in: bundle, vmID: VirtualMachineID(rawValue: UUID()), username: "alice",
                password: "long!Password123", guestResourcesURL: nil
            )
            XCTFail("Expected missing guest resources to be rejected")
        } catch LinuxGuestSeedError.missingResources {
            XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("seed.iso").path))
        }
    }

    func testCreatedSeedKeepsPlaintextOutOfBundle() async throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-private-seed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundle) }
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/LinuxGuestSetup", isDirectory: true)
        let password = "DoNotPersistThis123!"
        let seed = try await LinuxGuestSeedWriter.createSeed(
            in: bundle, vmID: VirtualMachineID(rawValue: UUID()), username: "alice",
            password: password, guestResourcesURL: resources
        )
        let bytes = try Data(contentsOf: seed)
        XCTAssertNil(bytes.range(of: Data(password.utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("debian-credentials.txt").path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: seed.path)[.posixPermissions] as? Int, 0o600)
    }

}
