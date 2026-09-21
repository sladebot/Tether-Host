import Foundation

public struct TailscaleServeRoute: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let path: String
    public let proxyTarget: URL
    public let funnelEnabled: Bool

    public init(host: String, port: Int, path: String, proxyTarget: URL, funnelEnabled: Bool) {
        self.host = host
        self.port = port
        self.path = path
        self.proxyTarget = proxyTarget
        self.funnelEnabled = funnelEnabled
    }
}

public struct TailscaleServeConfiguration: Codable, Equatable, Sendable {
    public let routes: [TailscaleServeRoute]

    public init(routes: [TailscaleServeRoute]) {
        self.routes = routes
    }

    public var isSecureHermesOnly: Bool {
        guard routes.count == 1, let route = routes.first else { return false }
        return route.port == 443
            && route.path == "/"
            && route.proxyTarget.scheme?.lowercased() == "http"
            && ["127.0.0.1", "localhost", "::1"].contains(route.proxyTarget.host?.lowercased() ?? "")
            && route.proxyTarget.port == 8642
            && !route.funnelEnabled
    }
}
