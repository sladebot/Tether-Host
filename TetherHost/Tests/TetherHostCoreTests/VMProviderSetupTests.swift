import XCTest
@testable import TetherHostCore

final class VMProviderSetupTests: XCTestCase {
    func testMissingUTMCannotAdvanceEvenWhenInvokedDirectly() {
        var setup = VMProviderSetup(provider: .utm)
        XCTAssertFalse(setup.advance { _ in UTMInstallation.missing.availability })
        XCTAssertFalse(setup.hasContinued)
    }

    func testInstallingThenRemovingUTMRechecksBeforeAdvancing() {
        var setup = VMProviderSetup(provider: .utm)
        setup.refresh { _ in .ready }
        XCTAssertFalse(setup.advance { _ in UTMInstallation.missing.availability })
        XCTAssertTrue(setup.advance { _ in .ready })
        setup.refresh { _ in UTMInstallation.missing.availability }
        XCTAssertFalse(setup.hasContinued)
    }

    func testSwitchingProviderInvalidatesPreviousApproval() {
        var setup = VMProviderSetup()
        XCTAssertEqual(setup.provider, .builtIn)
        XCTAssertTrue(setup.advance { _ in .ready })
        setup.select(.utm)
        XCTAssertEqual(setup.availability, .unchecked)
        XCTAssertFalse(setup.hasContinued)
        XCTAssertFalse(setup.advance { _ in .blocked("Install UTM") })
        setup.select(.builtIn)
        XCTAssertTrue(setup.advance { provider in provider == .builtIn ? .ready : .blocked("Install UTM") })
    }

    func testInstallationIsReadFreshAndRequiresCompatibleExecutable() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("UTM.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        XCTAssertEqual(UTMInstallation.detect(at: app), .missing)
        let contents = app.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/utmctl")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        func writeInfo(version: String, identifier: String = "com.utmapp.UTM") throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try writeInfo(version: "4.7.5")
        XCTAssertEqual(UTMInstallation.detect(at: app), .missingCommand)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        XCTAssertEqual(UTMInstallation.detect(at: app), .missingCommand)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertEqual(UTMInstallation.detect(at: app), .installed)
        try writeInfo(version: "4.8.0")
        XCTAssertEqual(UTMInstallation.detect(at: app), .unsupportedVersion("4.8.0"))
        try writeInfo(version: "4.7.5", identifier: "example.other")
        XCTAssertEqual(UTMInstallation.detect(at: app), .invalidApplication)
        try FileManager.default.removeItem(at: app)
        XCTAssertEqual(UTMInstallation.detect(at: app), .missing)
    }
}
