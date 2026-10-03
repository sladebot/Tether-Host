import XCTest
@testable import TetherHostCore

final class ConnectionVerificationFreshnessTests: XCTestCase {
    func testUnchangedCredentialsCannotKeepVerificationFreshForever() {
        let verifiedAt = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(ConnectionVerificationFreshness.isFresh(verifiedAt, now: verifiedAt.addingTimeInterval(59)))
        XCTAssertFalse(ConnectionVerificationFreshness.isFresh(verifiedAt, now: verifiedAt.addingTimeInterval(60)))
        XCTAssertFalse(ConnectionVerificationFreshness.isFresh(nil, now: verifiedAt))
    }

    func testClockRollbackRequiresNewVerification() {
        let timestamp = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(ConnectionVerificationFreshness.isFresh(timestamp, now: timestamp.addingTimeInterval(-1)))
        XCTAssertTrue(ConnectionVerificationFreshness.shouldAttempt(after: timestamp, now: timestamp.addingTimeInterval(-1)))
    }

    func testFailuresAreThrottledButRetried() {
        let timestamp = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(ConnectionVerificationFreshness.shouldAttempt(after: nil, now: timestamp))
        XCTAssertFalse(ConnectionVerificationFreshness.shouldAttempt(after: timestamp, now: timestamp.addingTimeInterval(29)))
        XCTAssertTrue(ConnectionVerificationFreshness.shouldAttempt(after: timestamp, now: timestamp.addingTimeInterval(30)))
    }
}
