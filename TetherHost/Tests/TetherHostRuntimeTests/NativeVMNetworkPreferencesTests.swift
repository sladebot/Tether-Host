import Foundation
import XCTest
@testable import TetherHostRuntime

final class NativeVMNetworkPreferencesTests: XCTestCase {
    @MainActor
    func testOfflineIntentSurvivesManagerRecreationAndCanBeExplicitlyEnabled() {
        let suite = "app.tether.tests.network.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = NativeVMManager(preferences: preferences, otherHostCopyRunning: { false })
        XCTAssertTrue(first.networkEnabled)
        first.networkEnabled = false
        let recreated = NativeVMManager(preferences: preferences, otherHostCopyRunning: { false })
        XCTAssertFalse(recreated.networkEnabled)
        recreated.networkEnabled = true
        XCTAssertTrue(NativeVMManager(preferences: preferences, otherHostCopyRunning: { false }).networkEnabled)
    }
}
