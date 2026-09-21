import Foundation
import XCTest
@testable import TetherHostCore

final class TetherHostCoreTests: XCTestCase {
    private let vmID = VirtualMachineID(rawValue: UUID(uuidString: "738EECC5-6357-43D9-BE03-298E0B3DE206")!)

    func testUTMParsesSupportedTableAndPreservesExactUUID() throws {
        let text = "UUID Status Name\n\(vmID) started Hermes Sandbox\n"
        XCTAssertEqual(
            try UTMCTLAdapter.parseList(text),
            [VirtualMachineRecord(id: vmID, name: "Hermes Sandbox", state: .started)]
        )
    }

    func testUTMStatusUsesListAndExactUUIDStatusOnly() async throws {
        let executor = MockUTMExecutor(vmID: vmID)
        let adapter = UTMCTLAdapter(executor: executor)
        let state = try await adapter.status(of: vmID)
        let commands = await executor.commands
        XCTAssertEqual(state, VirtualMachineState.started)
        XCTAssertEqual(commands, [UTMCommand.list, UTMCommand.status(vmID)])
    }

    func testUTMStatusRejectsMissingExactUUID() async {
        let executor = MockUTMExecutor(vmID: VirtualMachineID(rawValue: UUID()))
        let adapter = UTMCTLAdapter(executor: executor)
        do {
            _ = try await adapter.status(of: vmID)
            XCTFail("Expected exact UUID lookup to fail")
        } catch let error as UTMAdapterError {
            XCTAssertEqual(error, .vmNotFound(vmID))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let commands = await executor.commands
        XCTAssertEqual(commands, [UTMCommand.list])
    }

    func testUTMDeleteUsesExactStoppedUUIDAndConfirmsRemoval() async throws {
        let executor = DeletingUTMExecutor(vmID: vmID, state: .stopped)
        try await UTMCTLAdapter(executor: executor).delete(vmID)
        let commands = await executor.commands
        XCTAssertEqual(commands, [.list, .status(vmID), .delete(vmID), .list])
    }

    func testUTMDeleteRefusesRunningVM() async {
        let executor = DeletingUTMExecutor(vmID: vmID, state: .started)
        do {
            try await UTMCTLAdapter(executor: executor).delete(vmID)
            XCTFail("Running VM must not be deleted")
        } catch let error as UTMAdapterError {
            XCTAssertEqual(error, .vmNotStopped(vmID))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let commands = await executor.commands
        XCTAssertEqual(commands, [.list, .status(vmID)])
    }

    func testDuplicateNamesAreAmbiguousUntilUUIDIsDesignated() {
        let other = VirtualMachineID(rawValue: UUID())
        let records = [
            VirtualMachineRecord(id: vmID, name: "Hermes Sandbox", state: .started),
            VirtualMachineRecord(id: other, name: "Hermes Sandbox", state: .stopped)
        ]
        guard case .ambiguousName(let matches) = VirtualMachineSelector.select(
            designated: nil,
            expectedName: "Hermes Sandbox",
            from: records
        ) else { return XCTFail("Expected ambiguous names") }
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(
            VirtualMachineSelector.select(
                designated: DesignatedVirtualMachine(id: vmID, expectedName: "Hermes Sandbox"),
                expectedName: "Hermes Sandbox",
                from: records
            ),
            .selected(records[0])
        )
    }

    func testInterruptedJournalRecoversAndRedactsDiagnostics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("setup.json")
        let secret = "never-save-this-token"
        let store = FileSetupJournalStore(fileURL: url, redactor: SecretRedactor(literalSecrets: [secret]))
        var journal = SetupJournal(now: Date(timeIntervalSince1970: 1))
        journal.record(.running, for: .guestProvisioning, diagnostic: "Bearer \(secret)")
        try await store.save(journal)

        let bytes = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(secret))
        let restored = try await store.load()
        XCTAssertEqual(restored?.stages.first(where: { $0.stage == .guestProvisioning })?.state, .interrupted)
        try await store.remove()
    }

    func testTailnetEndpointRejectsPublicAndInsecureURLs() throws {
        XCTAssertEqual(
            try EndpointValidator.tailnetHTTPS("https://guest.example.ts.net/").url.absoluteString,
            "https://guest.example.ts.net"
        )
        for value in ["http://guest.example.ts.net", "https://example.com", "https://guest.example.ts.net:8443", "https://u:p@guest.example.ts.net"] {
            XCTAssertThrowsError(try EndpointValidator.tailnetHTTPS(value), value)
        }
    }

    func testGuestLoopbackEndpointIsNarrowlyScoped() throws {
        XCTAssertEqual(
            try EndpointValidator.guestLoopbackHermes("http://127.0.0.1:8642").kind,
            .guestLoopbackHermes
        )
        XCTAssertThrowsError(try EndpointValidator.guestLoopbackHermes("http://192.168.64.2:8642"))
        XCTAssertThrowsError(try EndpointValidator.guestLoopbackHermes("http://127.0.0.1:8080"))
    }

    func testSecretRedactionAndDescriptionNeverRevealValue() {
        let value = "sensitive-credential"
        let secret = SecretValue(data: Data(value.utf8))
        XCTAssertEqual(secret.description, "<redacted>")
        XCTAssertEqual(secret.debugDescription, "<redacted>")
        let text = SecretRedactor(literalSecrets: [value]).redact(
            "Authorization: Bearer abc token=xyz literal=\(value) https://me:password@example.com"
        )
        XCTAssertFalse(text.contains("abc"))
        XCTAssertFalse(text.contains("xyz"))
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains(value))
    }

    func testTwoPhaseTokenRotationCommitsAndClearsPending() async throws {
        let store = MemorySecretStore()
        let expected = SecretValue(data: Data("fixed-test-value".utf8))
        let rotator = TokenRotator(store: store, generator: FixedTokenGenerator(value: expected))
        let generated = try await rotator.begin(for: vmID)
        let pendingBeforeCommit = try await store.load(.pendingHermes(vmID))
        let activeBeforeCommit = try await store.load(.activeHermes(vmID))
        XCTAssertEqual(generated, expected)
        XCTAssertEqual(pendingBeforeCommit, expected)
        XCTAssertNil(activeBeforeCommit)
        try await rotator.commit(for: vmID)
        let activeAfterCommit = try await store.load(.activeHermes(vmID))
        let pendingAfterCommit = try await store.load(.pendingHermes(vmID))
        XCTAssertEqual(activeAfterCommit, expected)
        XCTAssertNil(pendingAfterCommit)
    }

    func testServeParserRequiresSingleHTTPSLoopbackRouteAndNoFunnel() throws {
        let valid = Data(#"{"Web":{"guest.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8642"}}}},"AllowFunnel":{"guest.example.ts.net:443":false}}"#.utf8)
        XCTAssertTrue(try TailscaleServeParser.parse(json: valid).isSecureHermesOnly)

        let funnel = Data(#"{"Web":{"guest.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8642"}}}},"AllowFunnel":{"guest.example.ts.net:443":true}}"#.utf8)
        XCTAssertFalse(try TailscaleServeParser.parse(json: funnel).isSecureHermesOnly)
    }

    func testHealthAggregationExpiresEvidenceAndUnknownIsNotHealthy() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fresh = HealthObservation(
            component: .hermes,
            state: .healthy,
            summary: "Authenticated probe passed",
            source: .guest,
            observedAt: now,
            validFor: 30
        )
        XCTAssertEqual(HealthAggregator.aggregate([fresh], required: [.hermes], now: now).overall, .healthy)
        XCTAssertEqual(HealthAggregator.aggregate([fresh], required: [.hermes], now: now.addingTimeInterval(31)).overall, .unknown)
        XCTAssertEqual(HealthAggregator.aggregate([], required: [.networkIsolation], now: now).overall, .unknown)
    }

    func testPairingDeepLinkContainsNoReusableCredential() throws {
        let endpoint = try EndpointValidator.tailnetHTTPS("https://guest.example.ts.net")
        let payload = PairingPayload(
            pairingID: UUID(),
            endpoint: endpoint,
            expiresAt: Date(timeIntervalSince1970: 2_000),
            hostPublicKeyFingerprint: String(repeating: "a", count: 64)
        )
        let link = try PairingPayloadBuilder.deepLink(for: payload, now: Date(timeIntervalSince1970: 1_000))
        let queryNames = Set(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        XCTAssertFalse(queryNames.contains("token"))
        XCTAssertFalse(queryNames.contains("api_key"))
        XCTAssertEqual(link.scheme, "tether")
    }

    func testFirewallPlanIsDeterministicDualStackAndRejectsPrivateAllowTargets() throws {
        let allowances = [
            EgressAllowance(purpose: .dns, destination: NetworkAddress(value: "1.1.1.1", family: .ipv4), port: 53, transport: .udp),
            EgressAllowance(purpose: .tailscaleControl, destination: NetworkAddress(value: "2606:4700:4700::1111", family: .ipv6), port: 443, transport: .tcp)
        ]
        let request = HostFirewallRequest(
            installationID: UUID(),
            virtualMachineID: vmID,
            guestAddresses: [
                NetworkAddress(value: "192.168.64.10", family: .ipv4),
                NetworkAddress(value: "fd00::10", family: .ipv6)
            ],
            egressAllowances: allowances
        )
        let plan = try FirewallPolicyGenerator.generate(request)
        XCTAssertEqual(plan.rules.filter { $0.action == FirewallRule.Action.block }.count, 2)
        XCTAssertEqual(try FirewallPolicyGenerator.generate(request), plan)

        let unsafe = HostFirewallRequest(
            installationID: request.installationID,
            virtualMachineID: vmID,
            guestAddresses: request.guestAddresses,
            egressAllowances: [EgressAllowance(
                purpose: .modelProvider,
                destination: NetworkAddress(value: "10.0.0.151", family: .ipv4),
                port: 443,
                transport: .tcp
            )]
        )
        XCTAssertThrowsError(try FirewallPolicyGenerator.generate(unsafe))
    }

    func testUninstallPreservesAdoptedVMAndRequiresExactDiskConfirmation() throws {
        let installationID = UUID()
        let disk = OwnedArtifact(
            kind: .virtualMachineDisk,
            identifier: vmID.description,
            installationID: installationID,
            adopted: true
        )
        XCTAssertThrowsError(try ScopedOperationPlanner.uninstallTargets(
            request: UninstallRequest(
                installationID: installationID,
                deleteVirtualMachineDisk: true,
                confirmedDiskDeletionVMID: vmID
            ),
            inventory: [disk],
            designatedVMID: vmID
        ))
        let keep = try ScopedOperationPlanner.uninstallTargets(
            request: UninstallRequest(installationID: installationID),
            inventory: [disk],
            designatedVMID: vmID
        )
        XCTAssertTrue(keep.isEmpty)
    }
}

private actor MockUTMExecutor: UTMCommandExecuting {
    private(set) var commands: [UTMCommand] = []
    let vmID: VirtualMachineID

    init(vmID: VirtualMachineID) { self.vmID = vmID }

    func execute(_ command: UTMCommand) -> UTMCommandOutput {
        commands.append(command)
        switch command {
        case .list:
            return UTMCommandOutput(standardOutput: "\(vmID) started Hermes Sandbox\n")
        case .status:
            return UTMCommandOutput(standardOutput: "started\n")
        case .delete:
            return UTMCommandOutput(standardOutput: "")
        }
    }
}

private actor DeletingUTMExecutor: UTMCommandExecuting {
    private(set) var commands: [UTMCommand] = []
    let vmID: VirtualMachineID
    let state: VirtualMachineState
    private var exists = true

    init(vmID: VirtualMachineID, state: VirtualMachineState) {
        self.vmID = vmID
        self.state = state
    }

    func execute(_ command: UTMCommand) -> UTMCommandOutput {
        commands.append(command)
        switch command {
        case .list:
            return UTMCommandOutput(standardOutput: exists ? "\(vmID) \(state.rawValue) Test VM\n" : "")
        case .status:
            return UTMCommandOutput(standardOutput: "\(state.rawValue)\n")
        case .delete:
            exists = false
            return UTMCommandOutput(standardOutput: "")
        }
    }
}

private actor MemorySecretStore: SecretStoring {
    private var values: [SecretHandle: SecretValue] = [:]

    func store(_ secret: SecretValue, for handle: SecretHandle) { values[handle] = secret }
    func load(_ handle: SecretHandle) -> SecretValue? { values[handle] }
    func remove(_ handle: SecretHandle) { values.removeValue(forKey: handle) }
}

private struct FixedTokenGenerator: TokenGenerating {
    let value: SecretValue
    func generate() -> SecretValue { value }
}
