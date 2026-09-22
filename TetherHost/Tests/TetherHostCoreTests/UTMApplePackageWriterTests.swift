import Foundation
import XCTest
@testable import TetherHostCore

final class UTMApplePackageWriterTests: XCTestCase {
    func testCreatedPackageHasExactIdentityAndIndependentDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tether-utm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = VirtualMachineID(rawValue: UUID())
        let native = root.appendingPathComponent(id.description)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        let manifest = NativeVirtualMachineManifest(id: id, name: "Tether Test", guestImageVersion: "26.2")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: native.appendingPathComponent("manifest.json"))
        try Data([1, 2, 3, 4]).write(to: native.appendingPathComponent("hardware.bin"))
        try Data([5, 6, 7, 8]).write(to: native.appendingPathComponent("machine.bin"))
        try Data([9, 10]).write(to: native.appendingPathComponent("auxiliary.img"))
        try Data([11, 12, 13]).write(to: native.appendingPathComponent("disk.img"))
        let guestISO = root.appendingPathComponent("Tether Guest Setup.iso")
        try Data([14, 15, 16]).write(to: guestISO)

        let package = try UTMApplePackageWriter.createPackage(
            nativeBundle: native, guestSetupISO: guestISO,
            in: root.appendingPathComponent("UTM Virtual Machines")
        )
        let data = try Data(contentsOf: package.appendingPathComponent("config.plist"))
        let config = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(config["Backend"] as? String, "Apple")
        XCTAssertEqual((config["Information"] as? [String: Any])?["UUID"] as? String, id.description)
        XCTAssertEqual(((config["System"] as? [String: Any])?["Boot"] as? [String: Any])?["OperatingSystem"] as? String, "macOS")
        let drive = try XCTUnwrap((config["Drive"] as? [[String: Any]])?.first)
        let clonedDisk = package.appendingPathComponent("Data").appendingPathComponent(try XCTUnwrap(drive["ImageName"] as? String))
        XCTAssertEqual(try Data(contentsOf: clonedDisk), Data([11, 12, 13]))
        try Data([42]).write(to: clonedDisk)
        XCTAssertEqual(try Data(contentsOf: native.appendingPathComponent("disk.img")), Data([11, 12, 13]))
        let guestDrive = try XCTUnwrap((config["Drive"] as? [[String: Any]])?.last)
        XCTAssertEqual(guestDrive["ImageName"] as? String, "Tether Guest Setup.iso")
        XCTAssertEqual(guestDrive["ReadOnly"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("Data/Tether Guest Setup.iso")), Data([14, 15, 16]))
        try Data([17]).write(to: guestISO)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("Data/Tether Guest Setup.iso")), Data([14, 15, 16]))
        XCTAssertThrowsError(try UTMApplePackageWriter.createPackage(
            nativeBundle: native, guestSetupISO: guestISO,
            in: root.appendingPathComponent("UTM Virtual Machines")
        ))
    }
}
