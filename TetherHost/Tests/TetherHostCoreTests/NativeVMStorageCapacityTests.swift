import Foundation
import XCTest
@testable import TetherHostCore

final class NativeVMStorageCapacityTests: XCTestCase {
    func testNonsparseVolumeRequiresFullVirtualDiskPlusHeadroom() {
        XCTAssertEqual(NativeVMStorageCapacity.requiredFreeGiB(
            diskGiB: 24, guestOS: .debian, supportsSparseFiles: false), 28)
        XCTAssertEqual(NativeVMStorageCapacity.requiredFreeGiB(
            diskGiB: 128, guestOS: .macOS, supportsSparseFiles: false), 132)
    }

    func testSparseVolumeUsesInstallationBudget() {
        XCTAssertEqual(NativeVMStorageCapacity.requiredFreeGiB(
            diskGiB: 24, guestOS: .debian, supportsSparseFiles: true), 12)
        XCTAssertEqual(NativeVMStorageCapacity.requiredFreeGiB(
            diskGiB: 128, guestOS: .macOS, supportsSparseFiles: true), 45)
    }

    func testFSKitZeroImportantCapacityFallsBackToOrdinaryCapacity() throws {
        XCTAssertEqual(NativeVMStorageCapacity.effectiveAvailableBytes(
            important: 0, ordinary: 1_640_741_470_208), 1_640_741_470_208)
        XCTAssertEqual(NativeVMStorageCapacity.effectiveAvailableBytes(
            important: 9, ordinary: 100), 9)
    }
}
