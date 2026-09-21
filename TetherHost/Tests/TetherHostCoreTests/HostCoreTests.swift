import CryptoKit
import Foundation
import XCTest
@testable import TetherHostCore

final class HostCoreTests: XCTestCase {
    private let vmID = VirtualMachineID(rawValue: UUID(uuidString: "738EECC5-6357-43D9-BE03-298E0B3DE206")!)

    func testUTMListParsesExactIDsAndDuplicateNames() throws {
        let input = """
        UUID                                 Status   Name
        738EECC5-6357-43D9-BE03-298E0B3DE206 started  Hermes Sandbox
        DBAD34AA-6E6F-41BB-A23D-2C57DC8B3334 stopped  Hermes Sandbox
        """
        let records = try UTMCTLAdapter.parseList(input)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].id, vmID)
        XCTAssertEqual(records[0].state, .started)
        if case .ambiguousName(let matches) = VirtualMachineSelector.select(
            designated: nil, expectedName: "Hermes Sandbox", from: records
        ) {
            XCTAssertEqual(matches.count, 2)
        } else {
            XCTFail("Duplicate names must remain ambiguous")
        }
    }

    func testExactDesignationWinsOverDuplicateName() throws {
        let other = VirtualMachineID(rawValue: UUID())
        let records = [
            VirtualMachineRecord(id: vmID, name: "Hermes Sandbox", state: .started),
            VirtualMachineRecord(id: other, name: "Hermes Sandbox", state: .stopped)
        ]
        let selection = VirtualMachineSelector.select(
            designated: DesignatedVirtualMachine(id: vmID, expectedName: "Hermes Sandbox"),
            expectedName: "Hermes Sandbox",
            from: records
        )
        XCTAssertEqual(selection, .selected(records[0]))
    }

    func testDuplicateExactUUIDIsRejected() throws {
        let line = "738EECC5-6357-43D9-BE03-298E0B3DE206 started Hermes Sandbox"
        XCTAssertThrowsError(try UTMCTLAdapter.parseList("UUID Status Name\n\(line)\n\(line)"))
    }

    func testInterruptedSetupRequiresReconciliation() {
        let start = Date(timeIntervalSince1970: 100)
        var journal = SetupJournal(now: start)
        journal.record(.running, for: .utmDetection, diagnostic: "checking", now: start)
        let recovered = journal.recoveredAfterInterruption(now: start.addingTimeInterval(5))
        let stage = recovered.stages.first { $0.stage == .utmDetection }
        XCTAssertEqual(stage?.state, .interrupted)
        XCTAssertEqual(stage?.attempts, 1)
        XCTAssertTrue(stage?.diagnostic?.contains("reconciliation") == true)
    }

    func testJournalStoreRedactsDiagnosticAndRecovers() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-host-tests-\(UUID().uuidString)")
            .appendingPathComponent("setup.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileSetupJournalStore(fileURL: url)
        var journal = SetupJournal()
        journal.record(.running, for: .utmDetection, diagnostic: "token=super-secret-value")
        try await store.save(journal)
        let bytes = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("super-secret-value"))
        let restored = try await store.load()
        XCTAssertEqual(restored?.stages.first { $0.stage == .utmDetection }?.state, .interrupted)
    }

    func testEndpointValidatorRejectsPublicAndInsecureOrigins() throws {
        XCTAssertThrowsError(try EndpointValidator.tailnetHTTPS("http://guest.tailnet.ts.net"))
        XCTAssertThrowsError(try EndpointValidator.tailnetHTTPS("https://example.com"))
        XCTAssertThrowsError(try EndpointValidator.tailnetHTTPS("https://guest.tailnet.ts.net/path"))
        let endpoint = try EndpointValidator.tailnetHTTPS("https://guest.tailnet.ts.net")
        XCTAssertEqual(endpoint.url.absoluteString, "https://guest.tailnet.ts.net")
    }

    func testSecretRedactionCoversHeadersParametersAndLiterals() {
        let redactor = SecretRedactor(literalSecrets: ["known-value"])
        let result = redactor.redact(
            "Authorization: Bearer abc token=xyz https://user:pass@example.com known-value"
        )
        XCTAssertFalse(result.contains("abc"))
        XCTAssertFalse(result.contains("xyz"))
        XCTAssertFalse(result.contains("pass"))
        XCTAssertFalse(result.contains("known-value"))
    }

    func testFirewallPlanIsDeterministicAndDefaultsToBlock() throws {
        let request = HostFirewallRequest(
            installationID: UUID(),
            virtualMachineID: vmID,
            guestAddresses: [
                NetworkAddress(value: "fd00::2", family: .ipv6),
                NetworkAddress(value: "192.168.64.2", family: .ipv4)
            ],
            egressAllowances: [
                EgressAllowance(
                    purpose: .dns,
                    destination: NetworkAddress(value: "8.8.8.8", family: .ipv4),
                    port: 53,
                    transport: .udp
                )
            ]
        )
        let first = try FirewallPolicyGenerator.generate(request)
        let second = try FirewallPolicyGenerator.generate(request)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.rules.last { $0.family == .ipv4 }?.action, .block)
        XCTAssertEqual(first.rules.last { $0.family == .ipv6 }?.action, .block)
    }

    func testFirewallRejectsPrivateAllowDestinationAndMissingIPv6() {
        let request = HostFirewallRequest(
            installationID: UUID(),
            virtualMachineID: vmID,
            guestAddresses: [NetworkAddress(value: "192.168.64.2", family: .ipv4)],
            egressAllowances: []
        )
        XCTAssertThrowsError(try FirewallPolicyGenerator.generate(request)) { error in
            XCTAssertEqual(error as? FirewallRequestError, .missingAddressFamily(.ipv6))
        }
    }

    func testTailscaleServeAcceptsOnlyHermesLoopbackAndNoFunnel() throws {
        let good = Data(#"{"Web":{"guest.tailnet.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8642"}}}},"AllowFunnel":{"guest.tailnet.ts.net:443":false}}"#.utf8)
        XCTAssertTrue(try TailscaleServeParser.parse(json: good).isSecureHermesOnly)
        let publicRoute = Data(#"{"Web":{"guest.tailnet.ts.net:443":{"Handlers":{"/":{"Proxy":"http://192.168.1.2:8642"}}}}}"#.utf8)
        XCTAssertFalse(try TailscaleServeParser.parse(json: publicRoute).isSecureHermesOnly)
    }

    func testGuestCannotCertifyHostIsolationAndEvidenceExpires() {
        let now = Date()
        let guestClaim = HealthObservation(
            component: .networkIsolation,
            state: .healthy,
            summary: "guest says pass",
            source: .guest,
            observedAt: now,
            validFor: 60
        )
        XCTAssertEqual(guestClaim.effectiveState(at: now), .unknown)
        let fresh = HealthObservation(
            component: .networkIsolation,
            state: .healthy,
            summary: "probe pass",
            source: .independentProbe,
            observedAt: now,
            validFor: 60
        )
        XCTAssertEqual(fresh.effectiveState(at: now), .healthy)
        XCTAssertEqual(fresh.effectiveState(at: now.addingTimeInterval(61)), .unknown)
    }

    func testPairingLinkContainsMetadataWithoutBearerToken() throws {
        let endpoint = try EndpointValidator.tailnetHTTPS("https://guest.tailnet.ts.net")
        let payload = PairingPayload(
            pairingID: UUID(),
            endpoint: endpoint,
            expiresAt: Date().addingTimeInterval(120),
            hostPublicKeyFingerprint: String(repeating: "a", count: 64)
        )
        let link = try PairingPayloadBuilder.deepLink(for: payload)
        XCTAssertEqual(link.scheme, "tether")
        XCTAssertFalse(link.absoluteString.lowercased().contains("token"))
        XCTAssertFalse(link.absoluteString.lowercased().contains("password"))
    }

    func testUninstallPreservesForeignAndAdoptedVMArtifacts() throws {
        let installation = UUID()
        let foreign = OwnedArtifact(kind: .networkPolicy, identifier: "foreign", installationID: UUID())
        let adoptedDisk = OwnedArtifact(
            kind: .virtualMachineDisk,
            identifier: vmID.description,
            installationID: installation,
            adopted: true
        )
        let request = UninstallRequest(
            installationID: installation,
            deleteVirtualMachineDisk: false
        )
        let targets = try ScopedOperationPlanner.uninstallTargets(
            request: request,
            inventory: [foreign, adoptedDisk],
            designatedVMID: vmID
        )
        XCTAssertTrue(targets.isEmpty)
    }

    func testManifestSignatureDigestAndIdempotentReceipts() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let bytes = Data("component".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let components = ProvisionedComponentID.allCases.map {
            ProvisionedComponent(
                id: $0,
                version: "1.2.3",
                downloadURL: URL(string: "https://releases.tether.app/\($0.rawValue)")!,
                sha256: digest
            )
        }
        let manifest = ProvisioningManifest(
            sequence: 3,
            expiresAt: Date().addingTimeInterval(3600),
            components: components
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        let payload = try encoder.encode(manifest)
        let signature = try privateKey.signature(for: payload)
        let verifier = try ManifestVerifier(
            publicKey: privateKey.publicKey.rawRepresentation,
            allowedDownloadHosts: ["releases.tether.app"]
        )
        let verified = try verifier.verify(payload: payload, signature: signature, minimumSequence: 3)
        try ManifestVerifier.verifyDownload(bytes, component: components[0])
        let plan = try IdempotentProvisioningPlan(
            virtualMachineID: vmID,
            manifest: verified,
            receipts: [ComponentInstallationReceipt(virtualMachineID: vmID, component: components[0])]
        )
        XCTAssertEqual(plan.pending.count, 2)
        XCTAssertFalse(plan.pending.contains(components[0]))
    }

    func testNativeVMStoreCreatesAndReadsOwnedBundle() async throws {
        guard AppleVirtualizationSupport.isAvailable else {
            throw XCTSkip("Apple virtualization is unavailable on this test host")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-native-vm-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeVirtualMachineStore(rootURL: root)
        let manifest = NativeVirtualMachineManifest(
            id: vmID,
            guestImageVersion: "test-1",
            createdAt: Date(timeIntervalSince1970: 123)
        )

        let bundle = try store.createBundle(for: manifest)
        let records = try await store.list()
        XCTAssertEqual(bundle.lastPathComponent, vmID.description)
        XCTAssertEqual(
            records,
            [VirtualMachineRecord(id: vmID, name: "Tether Sandbox", state: .stopped)]
        )
    }

    func testNativeVMStoreRejectsManifestDirectoryIdentityMismatch() async throws {
        guard AppleVirtualizationSupport.isAvailable else {
            throw XCTSkip("Apple virtualization is unavailable on this test host")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-native-vm-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(vmID.description)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = NativeVirtualMachineManifest(
            id: VirtualMachineID(rawValue: UUID()),
            guestImageVersion: "test-1"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent(NativeVirtualMachineStore.manifestFilename)
        )

        do {
            _ = try await NativeVirtualMachineStore(rootURL: root).list()
            XCTFail("Expected a mismatched identity to fail closed")
        } catch let error as NativeVirtualMachineStoreError {
            XCTAssertEqual(error, .identityMismatch)
        }
    }

    func testGuestSetupDiskExporterBuildsTransferImage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-guest-disk-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Tether Host for Mac.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let helper = app.appendingPathComponent("Contents/Resources/GuestSetup", isDirectory: true)
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        for filename in ["Set up Tether Guest.command", "guest_setup.py", "components.json"] {
            try Data("guest-helper".utf8).write(to: helper.appendingPathComponent(filename))
        }
        let image = root.appendingPathComponent("Tether Guest Setup.iso")

        try await GuestSetupDiskExporter.export(appURL: app, to: image)

        let attributes = try FileManager.default.attributesOfItem(atPath: image.path)
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 0)
        let mount = root.appendingPathComponent("mounted", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, image.path]
        attach.standardOutput = FileHandle.nullDevice
        try attach.run()
        attach.waitUntilExit()
        XCTAssertEqual(attach.terminationStatus, 0)
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mount.path]
            detach.standardOutput = FileHandle.nullDevice
            if (try? detach.run()) != nil { detach.waitUntilExit() }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: mount.appendingPathComponent("guest_setup.py").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: mount.appendingPathComponent("Set up Tether Guest.command").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mount.appendingPathComponent("Tether Host for Mac.app").path))
    }

    func testGuestSetupDiskExporterRequiresHelperResources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-missing-helper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Tether Host for Mac.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        do {
            try await GuestSetupDiskExporter.export(appURL: app, to: root.appendingPathComponent("Guest.iso"))
            XCTFail("Expected a missing helper to be rejected")
        } catch let error as GuestSetupDiskError {
            guard case .missingGuestHelper = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testFinderLocatorUsesExactUTMIdentityAndRejectsAmbiguousCopies() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-vm-locator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstID = VirtualMachineID(rawValue: UUID())
        let secondID = VirtualMachineID(rawValue: UUID())
        func makeUTM(_ name: String, id: VirtualMachineID) throws -> URL {
            let bundle = root.appendingPathComponent("\(name).utm", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
            let plist: [String: Any] = ["Information": ["UUID": id.description, "Name": "Same display name"]]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: bundle.appendingPathComponent("config.plist"))
            return bundle
        }
        let first = try makeUTM("first", id: firstID)
        _ = try makeUTM("second", id: secondID)
        let locator = VirtualMachineBundleLocator(nativeRoot: root, utmRoots: [root])
        XCTAssertEqual(locator.locate(firstID, provider: .utm)?.resolvingSymlinksInPath(),
                       first.resolvingSymlinksInPath())
        XCTAssertNil(locator.locate(VirtualMachineID(rawValue: UUID()), provider: .utm))
        let otherRoot = root.appendingPathComponent("another", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: false)
        let duplicate = otherRoot.appendingPathComponent("duplicate.utm", isDirectory: true)
        try FileManager.default.createDirectory(at: duplicate, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: first.appendingPathComponent("config.plist"),
                                         to: duplicate.appendingPathComponent("config.plist"))
        let ambiguous = VirtualMachineBundleLocator(nativeRoot: root, utmRoots: [root, otherRoot])
        XCTAssertNil(ambiguous.locate(firstID, provider: .utm))
    }

    func testGuestSetupDiskExporterRejectsWrongExtension() async {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-invalid-disk-test-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        do {
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try await GuestSetupDiskExporter.export(
                appURL: app,
                to: FileManager.default.temporaryDirectory.appendingPathComponent("guest.dmg")
            )
            XCTFail("Expected a non-ISO destination to be rejected")
        } catch let error as GuestSetupDiskError {
            guard case .invalidDestination = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGuestDependencyScannerReadsOnlySuppliedGuestRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-guest-scan-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("guest-home", isDirectory: true)
        let applications = root.appendingPathComponent("guest-applications", isDirectory: true)
        let hermesBin = home.appendingPathComponent(".hermes/hermes-agent/venv/bin", isDirectory: true)
        let tailscaleBin = applications.appendingPathComponent("Tailscale.app/Contents/MacOS", isDirectory: true)
        let state = home.appendingPathComponent("Library/Application Support/Tether Host for Mac/Guest Setup", isDirectory: true)
        try FileManager.default.createDirectory(at: hermesBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tailscaleBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)

        for executable in [hermesBin.appendingPathComponent("hermes"), hermesBin.appendingPathComponent("python"), tailscaleBin.appendingPathComponent("Tailscale")] {
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        try Data("API_SERVER_ENABLED=true\nAPI_SERVER_HOST=127.0.0.1\nAPI_SERVER_PORT=8642\nAPI_SERVER_KEY=abcdefghijklmnopqrstuvwxyz_12345\n".utf8)
            .write(to: home.appendingPathComponent(".hermes/.env"))
        try JSONSerialization.data(withJSONObject: [
            "BackendState": "Running",
            "Self": ["DNSName": "guest.example.ts.net."]
        ]).write(to: state.appendingPathComponent("tailscale-status.json"))
        let receipt = state.appendingPathComponent("connection.json")
        try Data("{}".utf8).write(to: receipt)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)

        let results = GuestDependencyScanner.scan(homeDirectory: home, applicationsDirectory: applications)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0.state) }), [
            "tailscale": .installed,
            "hermes": .installed,
            "verification": .installed
        ])
    }

    func testGuestDependencyScannerDoesNotUsePhysicalHostInstallations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-empty-guest-scan-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("guest-home", isDirectory: true)
        let applications = root.appendingPathComponent("guest-applications", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)

        let results = GuestDependencyScanner.scan(homeDirectory: home, applicationsDirectory: applications)
        let states = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0.state) })
        XCTAssertEqual(states["tailscale"], .missing)
        XCTAssertEqual(states["hermes"], .missing)
        XCTAssertEqual(states["verification"], .needsConfiguration)
    }

    func testGuestDependencyScannerRejectsUnsafeHermesAPIConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-unsafe-guest-scan-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("guest-home", isDirectory: true)
        let applications = root.appendingPathComponent("guest-applications", isDirectory: true)
        let hermesBin = home.appendingPathComponent(".hermes/hermes-agent/venv/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: hermesBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        for executable in [hermesBin.appendingPathComponent("hermes"), hermesBin.appendingPathComponent("python")] {
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        try Data("API_SERVER_ENABLED=false\nAPI_SERVER_HOST=0.0.0.0\nAPI_SERVER_PORT=8642\nAPI_SERVER_KEY=short\n".utf8)
            .write(to: home.appendingPathComponent(".hermes/.env"))

        let results = GuestDependencyScanner.scan(homeDirectory: home, applicationsDirectory: applications)
        XCTAssertEqual(results.first(where: { $0.id == "hermes" })?.state, .needsConfiguration)
    }
}
