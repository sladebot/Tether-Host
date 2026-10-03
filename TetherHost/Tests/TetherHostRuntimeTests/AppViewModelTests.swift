import Foundation
import XCTest
import TetherHostCore
@testable import TetherHostRuntime

final class AppViewModelTests: XCTestCase {
    @MainActor
    func testVerifiedConnectionExpiresWithoutCredentialChanges() async {
        let suite = "app.tether.tests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let clock = TestClock()
        let vault = MemoryVault()
        let model = AppViewModel(provider: EmptyStatusProvider(), preferences: preferences,
                                 nativeVM: NativeVMManager(preferences: preferences),
                                 connectionVerifier: ConnectionVerifier(client: HealthyAPI()),
                                 connectionVault: vault, isInsideGuest: true, now: { clock.date })
        model.setConnectionURLFromUser("https://guest.example.ts.net")
        model.setConnectionTokenFromUser("private-test-token")
        await model.verifyConnection()
        XCTAssertEqual(model.connectionVerifiedAt, clock.date)

        clock.date.addTimeInterval(ConnectionVerificationFreshness.lifetime)
        await model.refreshVerifiedGuestConnection()

        XCTAssertNil(model.connectionVerifiedAt)
        XCTAssertNil(model.verifiedForVMID)
        XCTAssertEqual(model.connectionURL, "https://guest.example.ts.net")
        XCTAssertEqual(model.connectionToken, "private-test-token")
    }

    @MainActor
    func testLegacyProviderSelectionIsRetiredWithoutAdoptingItsVM() async {
        let suite = "app.tether.tests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let id = VirtualMachineID(rawValue: UUID())
        preferences.set("utm", forKey: "setup.vmProvider")
        preferences.set(id.description, forKey: "setup.vmID")
        preferences.set(id.description, forKey: "setup.utmDesktopReadyVMID")
        preferences.set(id.description, forKey: "connection.id")
        preferences.set("https://old.example.ts.net", forKey: "connection.endpoint")

        let model = AppViewModel(provider: EmptyStatusProvider(), preferences: preferences,
                                 nativeVM: NativeVMManager(preferences: preferences))

        XCTAssertNil(model.selectedVMID)
        XCTAssertEqual(model.providerSetup.provider, .builtIn)
        XCTAssertTrue(model.connectionURL.isEmpty)
        for key in ["setup.vmProvider", "setup.vmID", "setup.utmDesktopReadyVMID",
                    "connection.id", "connection.endpoint"] {
            XCTAssertNil(preferences.object(forKey: key))
        }
    }

    @MainActor
    func testAppleSelectionSurvivesUpgradeButReadinessDoesNot() async {
        let suite = "app.tether.tests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let id = VirtualMachineID(rawValue: UUID())
        preferences.set("builtIn", forKey: "setup.vmProvider")
        preferences.set(id.description, forKey: "setup.vmID")
        preferences.set(id.description, forKey: "setup.tailscaleConfirmedVMID")

        let model = AppViewModel(provider: EmptyStatusProvider(), preferences: preferences,
                                 nativeVM: NativeVMManager(preferences: preferences))

        XCTAssertEqual(model.selectedVMID, id)
        XCTAssertNil(model.tailscaleConfirmedVMID)
        XCTAssertNil(model.connectionVerifiedAt)
        XCTAssertFalse(model.setupDependencies.hermesReady)
        XCTAssertEqual(preferences.string(forKey: "setup.vmID"), id.description)
    }
}

@MainActor private final class TestClock {
    var date = Date(timeIntervalSince1970: 1_000)
}

private actor MemoryVault: SecretStoring {
    private var values: [SecretHandle: SecretValue] = [:]
    func store(_ secret: SecretValue, for handle: SecretHandle) { values[handle] = secret }
    func load(_ handle: SecretHandle) -> SecretValue? { values[handle] }
    func remove(_ handle: SecretHandle) { values.removeValue(forKey: handle) }
}

private struct HealthyAPI: ConnectionHTTPClient {
    func get(_ url: URL, bearer: String?) async throws -> ConnectionHTTPResponse {
        guard bearer == "private-test-token" else { return .init(status: 401, data: Data()) }
        if url.path == "/v1/models" {
            return .init(status: 200, data: Data(#"{"data":[{"id":"hermes-agent"}]}"#.utf8))
        }
        return .init(status: 200, data: Data(#"{"platform":"hermes-agent","auth":{"type":"bearer","required":true},"features":{"run_submission":true,"run_status":true,"run_events_sse":true,"run_stop":true,"runs_idempotency":{"supported":true,"durable":true,"retention_seconds":3600}}}"#.utf8))
    }
}

private struct EmptyStatusProvider: HostStatusProviding {
    func snapshot(for vmProvider: VMProvider) async throws -> HostDashboardSnapshot { .unobserved }
}
