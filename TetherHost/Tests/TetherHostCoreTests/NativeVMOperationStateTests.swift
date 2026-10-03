import XCTest
@testable import TetherHostCore

final class NativeVMOperationStateTests: XCTestCase {
    func testStartupExcludesEveryOtherOperationUntilFinished() {
        var state = NativeVMOperationState()
        XCTAssertTrue(state.begin(.starting))
        for operation: NativeVMOperationState.Operation in [.starting, .installing, .stopping, .preparingMedia, .checkingImage, .downloadingImage] {
            XCTAssertFalse(state.begin(operation))
            XCTAssertEqual(state.operation, .starting)
        }
        state.finish()
        XCTAssertFalse(state.isBusy)
        XCTAssertTrue(state.begin(.starting))
    }

    func testInstallToBootRetainsExclusiveTransaction() {
        var state = NativeVMOperationState()
        XCTAssertTrue(state.begin(.installing))
        XCTAssertFalse(state.transition(from: .stopping, to: .starting))
        XCTAssertEqual(state.operation, .installing)
        XCTAssertTrue(state.transition(from: .installing, to: .starting))
        XCTAssertTrue(state.isBusy)
        XCTAssertFalse(state.begin(.preparingMedia))
        state.finish()
        XCTAssertTrue(state.begin(.installing))
    }
}
