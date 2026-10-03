import Foundation
import XCTest
@testable import TetherHostCore

final class GuestSetupDiskExporterTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func image(_ marker: UInt8) -> Data {
        var data = Data(repeating: marker, count: 40_960)
        let base = 32_768
        data.replaceSubrange(base..<(base + 2048), with: Data(repeating: 0, count: 2048))
        data.replaceSubrange(base..<(base + 7), with: [1, 67, 68, 48, 48, 49, 1])
        func setBoth(_ offset: Int, _ value: UInt32, width: Int) {
            for index in 0..<width {
                data[base + offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
                data[base + offset + width + index] = UInt8(truncatingIfNeeded: value >> ((width - index - 1) * 8))
            }
        }
        setBoth(80, 20, width: 4)
        setBoth(120, 1, width: 2)
        setBoth(124, 1, width: 2)
        setBoth(128, 2048, width: 2)
        data[base + 156] = 34
        setBoth(158, 19, width: 4)
        setBoth(166, 2048, width: 4)
        data[base + 881] = 1
        return data
    }

    func testFailedOrInvalidReplacementPreservesPreviousImage() throws {
        let directory = try workspace()
        let destination = directory.appendingPathComponent("setup.iso")
        let previous = image(42)
        try previous.write(to: destination)
        XCTAssertThrowsError(try GuestSetupDiskExporter.replaceImage(at: destination) { temporary in
            try Data("partial".utf8).write(to: temporary)
            throw CocoaError(.fileWriteUnknown)
        })
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        XCTAssertThrowsError(try GuestSetupDiskExporter.replaceImage(at: destination) { temporary in
            try Data("invalid image".utf8).write(to: temporary)
        })
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["setup.iso"])
    }

    func testSuccessfulReplacementAndFingerprintInvalidation() throws {
        let directory = try workspace()
        let destination = directory.appendingPathComponent("setup.iso")
        try image(42).write(to: destination)
        let before = try GuestSetupDiskExporter.contentFingerprint(directory)
        try GuestSetupDiskExporter.replaceImage(at: destination) { temporary in
            try self.image(43).write(to: temporary)
        }
        XCTAssertTrue(GuestSetupDiskExporter.isUsableImage(at: destination))
        XCTAssertEqual(try Data(contentsOf: destination), image(43))
        XCTAssertNotEqual(try GuestSetupDiskExporter.contentFingerprint(directory), before)
    }

    func testRejectsTruncatedOrInconsistentVolumeDescriptors() throws {
        let destination = try workspace().appendingPathComponent("setup.iso")
        let valid = image(42)
        for length in [32_775, 34_816, valid.count - 1] {
            try valid.prefix(length).write(to: destination)
            XCTAssertFalse(GuestSetupDiskExporter.isUsableImage(at: destination))
        }
        var inconsistent = valid
        inconsistent[32_768 + 84] = 1 // Big-endian volume size no longer matches.
        try inconsistent.write(to: destination)
        XCTAssertFalse(GuestSetupDiskExporter.isUsableImage(at: destination))
        XCTAssertFalse(GuestSetupDiskExporter.isUsableImage(at: destination.deletingLastPathComponent()))
    }

    func testUtilityDrainsLargeDiagnosticOutputWithoutDeadlock() throws {
        XCTAssertThrowsError(try GuestSetupDiskExporter.runUtility(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "dd if=/dev/zero bs=65536 count=4 >&2; exit 1"], timeout: 5
        )) { error in
            XCTAssertLessThan(error.localizedDescription.utf8.count, 2200)
            XCTAssertFalse(error.localizedDescription.contains("timed out"))
        }
    }

    func testUtilityTimeoutIsBounded() throws {
        let started = Date()
        XCTAssertThrowsError(try GuestSetupDiskExporter.runUtility(
            URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], timeout: 0.05
        )) { XCTAssertTrue($0.localizedDescription.contains("timed out")) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
