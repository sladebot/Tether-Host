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
        XCTAssertEqual(VirtualMachineBundleLocator(nativeRoot: defaultRoot, utmRoots: []).locate(id, provider: .builtIn)?.resolvingSymlinksInPath(),
                       bundle.resolvingSymlinksInPath())

        try FileManager.default.removeItem(at: external)
        let unavailable = try await NativeVirtualMachineStore(rootURL: defaultRoot).list()
        XCTAssertEqual(unavailable,
                       [VirtualMachineRecord(id: id, name: "External Test", state: .unavailable)])
        XCTAssertNil(VirtualMachineBundleLocator(nativeRoot: defaultRoot, utmRoots: []).locate(id, provider: .builtIn))
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
    }

    func testRegisteredExternalUTMPackageResolvesByExactIdentity() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tether-utm-external-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let defaultRoot = base.appendingPathComponent("support/Virtual Machines")
        let external = base.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let id = VirtualMachineID(rawValue: UUID())
        let package = external.appendingPathComponent("\(id.description).utm")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let data = try PropertyListSerialization.data(fromPropertyList: ["Information": ["UUID": id.description]],
                                                      format: .xml, options: 0)
        try data.write(to: package.appendingPathComponent("config.plist"))
        try NativeVMStorageRegistry(defaultRootURL: defaultRoot).registerUTM(id: id, name: "UTM External", at: package)
        XCTAssertEqual(VirtualMachineBundleLocator(nativeRoot: defaultRoot, utmRoots: []).locate(id, provider: .utm)?.resolvingSymlinksInPath(),
                       package.resolvingSymlinksInPath())
        let duplicateRoot = base.appendingPathComponent("local-utm")
        let duplicate = duplicateRoot.appendingPathComponent("duplicate.utm")
        try FileManager.default.createDirectory(at: duplicate, withIntermediateDirectories: true)
        try data.write(to: duplicate.appendingPathComponent("config.plist"))
        try FileManager.default.removeItem(at: package)
        XCTAssertNil(VirtualMachineBundleLocator(nativeRoot: defaultRoot, utmRoots: [duplicateRoot]).locate(id, provider: .utm))
        try FileManager.default.removeItem(at: external)
        XCTAssertNil(VirtualMachineBundleLocator(nativeRoot: defaultRoot, utmRoots: [duplicateRoot]).locate(id, provider: .utm))
    }
}
