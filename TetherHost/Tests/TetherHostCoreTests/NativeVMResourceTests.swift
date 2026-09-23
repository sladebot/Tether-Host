import Foundation
import XCTest
@testable import TetherHostCore

final class NativeVMResourceTests: XCTestCase {
    func testResourceLimitsUseHostHeadroomAndImageMinimums() {
        let limits = NativeVMResourceLimits(
            hostCPUCount: 8, hostMemoryBytes: 8 * 1_073_741_824,
            minimumCPUCount: 4, minimumMemoryBytes: 4 * 1_073_741_824
        )
        XCTAssertEqual(limits.cpu, 4...8)
        XCTAssertEqual(limits.memoryGiB, 4...4)
        XCTAssertEqual(limits.diskGiB, 64...1024)
        XCTAssertEqual(limits.defaults, NativeVMResources(cpuCount: 4, memoryGiB: 4, diskGiB: 128))
        XCTAssertNotNil(limits.validationMessage(for: NativeVMResources(cpuCount: 3, memoryGiB: 4, diskGiB: 128)))
        XCTAssertNotNil(limits.validationMessage(for: NativeVMResources(cpuCount: 4, memoryGiB: 4, diskGiB: 32)))
        XCTAssertNil(limits.validationMessage(for: limits.defaults))
    }

    func testManifestRoundTripAndLegacyDecode() throws {
        let id = VirtualMachineID(rawValue: UUID())
        let resources = NativeVMResources(cpuCount: 6, memoryGiB: 12, diskGiB: 256)
        let manifest = NativeVirtualMachineManifest(
            id: id, guestImageVersion: "26.2", createdAt: Date(timeIntervalSince1970: 123), resources: resources
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(NativeVirtualMachineManifest.self, from: encoder.encode(manifest)), manifest)

        let legacy = NativeVirtualMachineManifest(id: id, guestImageVersion: "26.2")
        let legacyData = try encoder.encode(legacy)
        XCTAssertNil(try decoder.decode(NativeVirtualMachineManifest.self, from: legacyData).resources)
    }

    func testImageMinimumBeyondHostBudgetIsUnavailable() {
        let limits = NativeVMResourceLimits(
            hostCPUCount: 8, hostMemoryBytes: 8 * 1_073_741_824,
            minimumMemoryBytes: 8 * 1_073_741_824
        )
        XCTAssertNotNil(limits.hostCapabilityError)
        XCTAssertNotNil(limits.validationMessage(for: limits.defaults))
    }
}
