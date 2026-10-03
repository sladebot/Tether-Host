import Foundation
import XCTest
@testable import TetherHostCore

final class NativeVMStorageRegistryTests: XCTestCase {
    func testExternalBundleSurvivesStoreAndLocatorRecreationAndMissingFolderStaysUnavailable() async throws {
        guard AppleVirtualizationSupport.isAvailable else {
            throw XCTSkip("Apple virtualization is unavailable on this test host")
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tether-external-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let defaultRoot = base.appendingPathComponent("support/Virtual Machines")
        let external = base.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let id = VirtualMachineID(rawValue: UUID())
        let manifest = NativeVirtualMachineManifest(id: id, name: "External Test", guestImageVersion: "test")
        let bundle = external.appendingPathComponent(id.description)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: bundle.appendingPathComponent(NativeVirtualMachineStore.manifestFilename))
        try NativeVMStorageRegistry(defaultRootURL: defaultRoot).register(manifest, at: bundle)

        let available = try await NativeVirtualMachineStore(rootURL: defaultRoot).list()
        XCTAssertEqual(available,
                       [VirtualMachineRecord(id: id, name: "External Test", state: .stopped)])
        XCTAssertEqual(VirtualMachineBundleLocator(nativeRoot: defaultRoot).locate(id)?.resolvingSymlinksInPath(),
                       bundle.resolvingSymlinksInPath())

        try FileManager.default.removeItem(at: external)
        let unavailable = try await NativeVirtualMachineStore(rootURL: defaultRoot).list()
        XCTAssertEqual(unavailable,
                       [VirtualMachineRecord(id: id, name: "External Test", state: .unavailable)])
        XCTAssertNil(VirtualMachineBundleLocator(nativeRoot: defaultRoot).locate(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
    }

}
