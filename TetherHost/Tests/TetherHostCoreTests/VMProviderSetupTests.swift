import XCTest
@testable import TetherHostCore

final class VMProviderSetupTests: XCTestCase {
    func testUnavailableVirtualizationCannotAdvance() {
        var setup = VMProviderSetup()
        XCTAssertEqual(VMProvider.allCases, [.builtIn])
        XCTAssertFalse(setup.advance { _ in .blocked("Unsupported Mac") })
        XCTAssertFalse(setup.hasContinued)
    }

    func testAdvancingRechecksAvailability() {
        var setup = VMProviderSetup()
        setup.refresh { _ in .ready }
        XCTAssertFalse(setup.advance { _ in .blocked("Unavailable") })
        XCTAssertTrue(setup.advance { _ in .ready })
        setup.refresh { _ in .blocked("Unavailable") }
        XCTAssertFalse(setup.hasContinued)
    }

    func testLegacyJournalStageDecodesToAppleSupport() throws {
        let stage = try JSONDecoder().decode(SetupStage.self, from: Data("\"utmDetection\"".utf8))
        XCTAssertEqual(stage, .virtualizationSupport)
        XCTAssertEqual(String(data: try JSONEncoder().encode(stage), encoding: .utf8), "\"virtualizationSupport\"")
    }
}
