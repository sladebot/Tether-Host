import Foundation

/// A saved receipt describes credentials; only a recent API check establishes health.
public enum ConnectionVerificationFreshness {
    public static let lifetime: TimeInterval = 60
    public static let retryInterval: TimeInterval = 30

    public static func isFresh(_ verifiedAt: Date?, now: Date = Date()) -> Bool {
        guard let verifiedAt else { return false }
        let age = now.timeIntervalSince(verifiedAt)
        return age >= 0 && age < lifetime
    }

    public static func shouldAttempt(after lastAttempt: Date?, now: Date = Date()) -> Bool {
        guard let lastAttempt else { return true }
        let age = now.timeIntervalSince(lastAttempt)
        return age < 0 || age >= retryInterval
    }
}
