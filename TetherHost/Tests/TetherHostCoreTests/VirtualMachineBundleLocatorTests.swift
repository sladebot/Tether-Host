import XCTest
@testable import TetherHostCore

final class VirtualMachineBundleLocatorTests: XCTestCase {
    func testNativeLookupRequiresMatchingManifestIdentityAndRejectsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = VirtualMachineID(rawValue: UUID())
        let bundle = root.appendingPathComponent(id.description)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let manifest = bundle.appendingPathComponent(NativeVirtualMachineStore.manifestFilename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let locator = VirtualMachineBundleLocator(nativeRoot: root)
        XCTAssertNil(locator.locate(id))
        try encoder.encode(NativeVirtualMachineManifest(id: id, guestImageVersion: "test")).write(to: manifest)
        XCTAssertEqual(locator.locate(id)?.path, bundle.path)
        try encoder.encode(NativeVirtualMachineManifest(id: VirtualMachineID(rawValue: UUID()), guestImageVersion: "test")).write(to: manifest)
        XCTAssertNil(locator.locate(id))
        try FileManager.default.removeItem(at: manifest)
        let external = root.appendingPathComponent("external.json")
        try encoder.encode(NativeVirtualMachineManifest(id: id, guestImageVersion: "test")).write(to: external)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: external)
        XCTAssertNil(locator.locate(id))
    }
}
