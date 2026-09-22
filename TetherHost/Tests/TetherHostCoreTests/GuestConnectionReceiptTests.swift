import XCTest
@testable import TetherHostCore

final class GuestConnectionReceiptTests: XCTestCase {
    func testAcceptsPrivateTailnetURLAndBoundedToken() throws {
        let data = Data(#"{"endpoint":"https://vm.example.ts.net","token":"abcdefghijklmnopqrstuvwxyzABCDEF"}"#.utf8)
        let receipt = try GuestConnectionReceipt(json: data)
        XCTAssertEqual(receipt.endpoint, "https://vm.example.ts.net")
        XCTAssertEqual(receipt.token.count, 32)
    }

    func testRejectsMalformedPublicAndOversizedReplies() {
        let token = String(repeating: "a", count: 32)
        for json in ["not json", "{\"endpoint\":\"https://public.example\",\"token\":\"\(token)\"}",
                     "{\"endpoint\":\"https://vm.example.ts.net\",\"token\":\"short\"}"] {
            XCTAssertThrowsError(try GuestConnectionReceipt(json: Data(json.utf8)))
        }
        XCTAssertThrowsError(try GuestConnectionReceipt(json: Data(repeating: 65, count: 16_384)))
    }
}
