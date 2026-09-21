import Foundation

public enum ConnectionVerificationError: Error, LocalizedError, Sendable {
    case invalidToken, failed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidToken: "Enter the API token generated inside the VM."
        case .failed(let reason): reason
        }
    }
}

public struct ConnectionHTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}

public protocol ConnectionHTTPClient: Sendable {
    func get(_ url: URL, bearer: String?) async throws -> ConnectionHTTPResponse
}

private final class RejectConnectionRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct LiveConnectionHTTPClient: ConnectionHTTPClient {
    public init() {}
    public func get(_ url: URL, bearer: String?) async throws -> ConnectionHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: RejectConnectionRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 1_048_576 else {
            throw ConnectionVerificationError.failed("The VM returned an invalid response.")
        }
        return ConnectionHTTPResponse(status: http.statusCode, data: data)
    }
}

public struct VerifiedConnection: Sendable {
    public let endpoint: ValidatedEndpoint
    public let verifiedAt: Date
}

public struct ConnectionVerifier: Sendable {
    private let client: any ConnectionHTTPClient
    public init(client: any ConnectionHTTPClient = LiveConnectionHTTPClient()) { self.client = client }

    public func verify(endpoint input: String, token: String) async throws -> VerifiedConnection {
        let endpoint = try EndpointValidator.tailnetHTTPS(input)
        guard !token.isEmpty, token.utf8.count <= 4096,
              !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw ConnectionVerificationError.invalidToken
        }
        let url = endpoint.url.appendingPathComponent("v1/capabilities")
        for bearer in [nil, "tether-invalid-\(UUID().uuidString)"] as [String?] {
            let response = try await client.get(url, bearer: bearer)
            guard response.status == 401 || response.status == 403 else {
                throw ConnectionVerificationError.failed("The VM must reject missing and incorrect API tokens.")
            }
        }
        let response = try await client.get(url, bearer: token)
        guard response.status == 200 else {
            throw ConnectionVerificationError.failed("The VM rejected the API token or is unavailable.")
        }
        try Self.validateCapabilities(response.data)
        let models = try await client.get(endpoint.url.appendingPathComponent("v1/models"), bearer: token)
        guard models.status == 200,
              let root = try? JSONSerialization.jsonObject(with: models.data) as? [String: Any],
              let values = root["data"] as? [[String: Any]],
              values.contains(where: { ($0["id"] as? String)?.isEmpty == false }) else {
            throw ConnectionVerificationError.failed("Hermes did not advertise an available model. Complete model setup in the guest.")
        }
        return VerifiedConnection(endpoint: endpoint, verifiedAt: Date())
    }

    public static func validateCapabilities(_ data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["platform"] as? String == "hermes-agent",
              let auth = root["auth"] as? [String: Any], auth["type"] as? String == "bearer", auth["required"] as? Bool == true,
              let features = root["features"] as? [String: Any],
              ["run_submission", "run_status", "run_events_sse", "run_stop"].allSatisfy({ features[$0] as? Bool == true }),
              let idempotency = features["runs_idempotency"] as? [String: Any],
              idempotency["supported"] as? Bool == true, idempotency["durable"] as? Bool == true,
              let retention = idempotency["retention_seconds"] as? Double, retention > 0 else {
            throw ConnectionVerificationError.failed("This Hermes server lacks the authenticated durable-run features required by Tether iOS.")
        }
    }
}
