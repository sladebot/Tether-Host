import XCTest
@testable import TetherHostCore

final class PhoneSetupConfirmationTests: XCTestCase {
    func testAcknowledgementMatchesOnlyTheSameVMAndCanonicalEndpoint() throws {
        let vm = VirtualMachineID(rawValue: UUID())
        let otherVM = VirtualMachineID(rawValue: UUID())
        let confirmation = try XCTUnwrap(PhoneSetupConfirmation(
            vmID: vm, endpoint: "  HTTPS://My-VM.Example.TS.NET:443/  "
        ))

        XCTAssertTrue(confirmation.matches(vmID: vm, endpoint: "https://my-vm.example.ts.net"))
        XCTAssertFalse(confirmation.matches(vmID: otherVM, endpoint: "https://my-vm.example.ts.net"))
        XCTAssertFalse(confirmation.matches(vmID: vm, endpoint: "https://other.example.ts.net"))
        XCTAssertFalse(confirmation.matches(vmID: nil, endpoint: "https://my-vm.example.ts.net"))
    }

    func testPersistedAcknowledgementStoresOnlyVMAndEndpoint() throws {
        let vm = VirtualMachineID(rawValue: UUID())
        let confirmation = try XCTUnwrap(PhoneSetupConfirmation(vmID: vm, endpoint: "https://my-vm.ts.net"))
        let data = try JSONEncoder().encode(confirmation)
        let restored = try JSONDecoder().decode(PhoneSetupConfirmation.self, from: data)

        XCTAssertEqual(restored, confirmation)
        XCTAssertTrue(restored.matches(vmID: vm, endpoint: "https://my-vm.ts.net/"))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["vmID", "endpoint"])
    }

    func testRejectsUntrustedEndpointBeforeAcknowledgement() {
        let vm = VirtualMachineID(rawValue: UUID())
        XCTAssertNil(PhoneSetupConfirmation(vmID: vm, endpoint: "http://my-vm.ts.net"))
        XCTAssertNil(PhoneSetupConfirmation(vmID: vm, endpoint: "https://public.example.com"))
        XCTAssertNil(PhoneSetupConfirmation(vmID: vm, endpoint: "https://my-vm.ts.net/path"))
    }
}
