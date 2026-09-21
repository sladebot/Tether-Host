import XCTest
@testable import TetherHostCore

private actor FixtureConnectionClient: ConnectionHTTPClient {
    var responses: [ConnectionHTTPResponse]
    var bearers: [String?] = []
    init(_ responses: [ConnectionHTTPResponse]) { self.responses = responses }
    func get(_ url: URL, bearer: String?) async throws -> ConnectionHTTPResponse {
        bearers.append(bearer)
        guard !responses.isEmpty else { throw ConnectionVerificationError.failed("Unexpected request") }
        return responses.removeFirst()
    }
}

final class ConnectionVerifierTests: XCTestCase {
    private let endpoint = "https://guest.example.ts.net"
    private var capabilities: Data {
        Data(#"{"platform":"hermes-agent","auth":{"type":"bearer","required":true},"features":{"run_submission":true,"run_status":true,"run_events_sse":true,"run_stop":true,"runs_idempotency":{"supported":true,"durable":true,"retention_seconds":3600}}}"#.utf8)
    }

    func testVerifiedOnlyAfterAuthRejectionsCapabilitiesAndModels() async throws {
        let client = FixtureConnectionClient([
            .init(status: 401, data: Data()), .init(status: 401, data: Data()),
            .init(status: 200, data: capabilities),
            .init(status: 200, data: Data(#"{"data":[{"id":"hermes-agent"}]}"#.utf8))
        ])
        let result = try await ConnectionVerifier(client: client).verify(endpoint: endpoint, token: "private-test-token")
        XCTAssertEqual(result.endpoint.url.absoluteString, endpoint)
        let bearers = await client.bearers
        XCTAssertNil(bearers[0])
        XCTAssertNotEqual(bearers[1], "private-test-token")
        XCTAssertEqual(bearers[2], "private-test-token")
    }

    func testAnonymousSuccessAndRedirectCannotPass() async {
        for status in [200, 301, 302, 500] {
            let client = FixtureConnectionClient([.init(status: status, data: capabilities)])
            do {
                _ = try await ConnectionVerifier(client: client).verify(endpoint: endpoint, token: "private-test-token")
                XCTFail("Unexpected success for \(status)")
            } catch { }
            let calls = await client.bearers
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testUnsafeEndpointAndHeaderTokenAreRejectedBeforeNetwork() async {
        let client = FixtureConnectionClient([])
        for (url, token) in [("https://public.example", "token"), (endpoint, "token\r\nInjected: header"), (endpoint, "")] {
            do {
                _ = try await ConnectionVerifier(client: client).verify(endpoint: url, token: token)
                XCTFail("Unexpected success")
            } catch { }
        }
        let calls = await client.bearers
        XCTAssertEqual(calls.count, 0)
    }

    func testMissingDurableContractIsRejected() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: capabilities) as? [String: Any])
        root["features"] = ["run_submission": true]
        XCTAssertThrowsError(try ConnectionVerifier.validateCapabilities(JSONSerialization.data(withJSONObject: root)))
    }
}
