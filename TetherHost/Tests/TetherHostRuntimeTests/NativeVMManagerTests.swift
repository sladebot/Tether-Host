import Foundation
import XCTest
import TetherHostCore
@testable import TetherHostRuntime

final class NativeVMManagerTests: XCTestCase {
    @MainActor
    func testStartupBlocksAnotherBootAndDeletionWhilePreparingMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = VirtualMachineID(rawValue: UUID())
        let bundle = root.appendingPathComponent(id.description)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let manifest = NativeVirtualMachineManifest(id: id, guestImageVersion: "test")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: bundle.appendingPathComponent(NativeVirtualMachineStore.manifestFilename))
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "app.tether.tests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let entered = expectation(description: "Media export suspended")
        let exporter = SuspendedExporter(entered: entered)
        let manager = NativeVMManager(preferences: preferences, rootURL: root,
                                      otherHostCopyRunning: { false }) { _ in
            await exporter.suspend()
        }
        let startup = Task { try await manager.boot(id) }
        await fulfillment(of: [entered], timeout: 5)

        XCTAssertTrue(manager.isBusy)
        XCTAssertEqual(manager.operationState.operation, .starting)
        do {
            try await manager.boot(id)
            XCTFail("A second startup must not enter the media exporter")
        } catch NativeVMError.operationInProgress { }
        catch { XCTFail("Unexpected startup error: \(error)") }
        XCTAssertThrowsError(try manager.deleteFiles(id)) { error in
            guard case NativeVMError.cannotRemoveDuringInstall = error else {
                return XCTFail("Deletion was not blocked by the lifecycle transaction")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
        await exporter.resume()
        // The fixture has no hardware image. It fails before any real VM is created.
        do { try await startup.value; XCTFail("Incomplete VM must fail") } catch { }
        XCTAssertFalse(manager.isBusy)
        XCTAssertFalse(manager.isRunning)
        XCTAssertNil(manager.virtualMachine)
        let count = await exporter.count
        XCTAssertEqual(count, 1)
    }
}

private actor SuspendedExporter {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var count = 0
    init(entered: XCTestExpectation) { self.entered = entered }
    func suspend() async {
        count += 1
        await withCheckedContinuation {
            continuation = $0
            entered.fulfill()
        }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
