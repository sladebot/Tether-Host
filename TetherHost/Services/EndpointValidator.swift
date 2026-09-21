import Foundation

public enum EndpointValidator {
    public static func tailnetHTTPS(_ input: String) throws -> ValidatedEndpoint {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            if URLComponents(string: trimmed)?.scheme?.lowercased() == "http" {
                throw EndpointValidationError.insecureTransport
            }
            throw EndpointValidationError.malformed
        }
        guard components.user == nil, components.password == nil else {
            throw EndpointValidationError.credentialsForbidden
        }
        guard components.query == nil, components.fragment == nil else {
            throw EndpointValidationError.queryOrFragmentForbidden
        }
        guard host.hasSuffix(".ts.net"), host.count > ".ts.net".count else {
            throw EndpointValidationError.publicEndpointForbidden
        }
        guard components.port == nil || components.port == 443 else {
            throw EndpointValidationError.unexpectedPort
        }
        guard components.path.isEmpty || components.path == "/" else {
            throw EndpointValidationError.unexpectedPath
        }
        components.scheme = "https"
        components.host = host
        components.port = nil
        components.path = ""
        guard let url = components.url else { throw EndpointValidationError.malformed }
        return ValidatedEndpoint(url: url, kind: .tailnetHTTPS)
    }

    public static func guestLoopbackHermes(_ input: String) throws -> ValidatedEndpoint {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let host = components.host?.lowercased(),
              components.scheme?.lowercased() == "http" else {
            throw EndpointValidationError.malformed
        }
        guard components.user == nil, components.password == nil else {
            throw EndpointValidationError.credentialsForbidden
        }
        guard components.query == nil, components.fragment == nil else {
            throw EndpointValidationError.queryOrFragmentForbidden
        }
        guard ["127.0.0.1", "localhost", "::1"].contains(host) else {
            throw EndpointValidationError.publicEndpointForbidden
        }
        guard components.port == 8642 else { throw EndpointValidationError.unexpectedPort }
        guard components.path.isEmpty || components.path == "/" else {
            throw EndpointValidationError.unexpectedPath
        }
        components.host = host
        components.path = ""
        guard let url = components.url else { throw EndpointValidationError.malformed }
        return ValidatedEndpoint(url: url, kind: .guestLoopbackHermes)
    }
}
