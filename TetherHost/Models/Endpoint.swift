import Foundation

public struct ValidatedEndpoint: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case tailnetHTTPS
        case guestLoopbackHermes
    }

    public let url: URL
    public let kind: Kind

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }
}

public enum EndpointValidationError: Error, Equatable, LocalizedError, Sendable {
    case malformed
    case credentialsForbidden
    case queryOrFragmentForbidden
    case insecureTransport
    case publicEndpointForbidden
    case unexpectedPort
    case unexpectedPath

    public var errorDescription: String? {
        switch self {
        case .malformed: "The endpoint is not a valid absolute URL."
        case .credentialsForbidden: "Credentials are forbidden in endpoint URLs."
        case .queryOrFragmentForbidden: "Queries and fragments are forbidden in endpoint URLs."
        case .insecureTransport: "The endpoint must use the required secure transport."
        case .publicEndpointForbidden: "The endpoint is not a private tailnet or guest-loopback endpoint."
        case .unexpectedPort: "The endpoint uses an unexpected port."
        case .unexpectedPath: "The endpoint must not include a path."
        }
    }
}
