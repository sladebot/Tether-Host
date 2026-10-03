import Foundation

public enum RestoreImagePolicy {
    /// Offer supported macOS release lines, including older guests, without
    /// selecting a guest release newer than the host by default.
    public static func isEligible(_ version: OperatingSystemVersion, for host: OperatingSystemVersion) -> Bool {
        version.majorVersion >= 14 &&
            (version.majorVersion, version.minorVersion, version.patchVersion) <=
                (host.majorVersion, host.minorVersion, host.patchVersion)
    }

    public static func preferredVersion(
        from available: [OperatingSystemVersion], for host: OperatingSystemVersion,
        retaining previousSelection: OperatingSystemVersion? = nil
    ) -> OperatingSystemVersion? {
        let eligible = available.filter { isEligible($0, for: host) }
        if let previousSelection, eligible.contains(where: {
            ($0.majorVersion, $0.minorVersion, $0.patchVersion) ==
                (previousSelection.majorVersion, previousSelection.minorVersion, previousSelection.patchVersion)
        }) {
            return previousSelection
        }
        return eligible.max { left, right in
            (left.majorVersion, left.minorVersion, left.patchVersion) <
                (right.majorVersion, right.minorVersion, right.patchVersion)
        }
    }

    public static func parseVersion(_ text: String) -> OperatingSystemVersion? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), let major = Int(parts[0]), let minor = Int(parts[1]),
              let patch = parts.count == 3 ? Int(parts[2]) : 0,
              major > 0, minor >= 0, patch >= 0 else { return nil }
        return OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    public static func isAppleImageURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.port == nil,
              url.user == nil, url.password == nil, let host = url.host?.lowercased(),
              url.path.lowercased().hasSuffix(".ipsw") else { return false }
        return host == "apple.com" || host.hasSuffix(".apple.com") ||
            host == "cdn-apple.com" || host.hasSuffix(".cdn-apple.com")
    }
}
