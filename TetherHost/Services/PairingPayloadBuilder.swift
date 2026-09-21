import Foundation

public enum PairingPayloadBuilder {
    public static func deepLink(for payload: PairingPayload, now: Date = Date()) throws -> URL {
        guard payload.expiresAt > now else { throw PairingPayloadError.expired }
        let fingerprint = payload.hostPublicKeyFingerprint.lowercased()
        let validCharacters = CharacterSet(charactersIn: "0123456789abcdef")
        guard fingerprint.count == 64,
              fingerprint.unicodeScalars.allSatisfy(validCharacters.contains) else {
            throw PairingPayloadError.invalidFingerprint
        }
        var components = URLComponents()
        components.scheme = "tether"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(payload.version)),
            URLQueryItem(name: "pairing_id", value: payload.pairingID.uuidString),
            URLQueryItem(name: "endpoint", value: payload.endpoint.url.absoluteString),
            URLQueryItem(name: "expires_at", value: String(Int(payload.expiresAt.timeIntervalSince1970))),
            URLQueryItem(name: "host_key", value: fingerprint)
        ]
        guard let url = components.url else { throw PairingPayloadError.cannotEncode }
        return url
    }
}
