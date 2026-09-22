import Foundation

public enum GuestConnectionReceiptError: Error, LocalizedError, Sendable {
    case invalid

    public var errorDescription: String? {
        "The VM has not provided valid, private connection details. Complete Verify connection in Tether Guest Installer."
    }
}

/// A bounded, untrusted reply from the guest's private VM socket. Parsing this
/// never marks the backend ready; the host must still verify HTTPS and the API.
public struct GuestConnectionReceipt: Sendable {
    public let endpoint: String
    public let token: String

    public init(json: Data) throws {
        struct Payload: Decodable {
            let endpoint: String
            let token: String
        }
        guard json.count < 16_384,
              let payload = try? JSONDecoder().decode(Payload.self, from: json),
              let validated = try? EndpointValidator.tailnetHTTPS(payload.endpoint),
              payload.token.range(of: #"^[A-Za-z0-9_-]{32,256}$"#, options: .regularExpression) != nil else {
            throw GuestConnectionReceiptError.invalid
        }
        endpoint = validated.url.absoluteString
        token = payload.token
    }
}
