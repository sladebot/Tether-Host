import Foundation

public enum TailscaleServeParseError: Error, Equatable, Sendable {
    case malformedJSON
    case malformedRoute
}

public enum TailscaleServeParser {
    public static func parse(json data: Data) throws -> TailscaleServeConfiguration {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TailscaleServeParseError.malformedJSON
        }
        let web = (root["Web"] ?? root["web"]) as? [String: Any] ?? [:]
        let funnel = (root["AllowFunnel"] ?? root["allowFunnel"]) as? [String: Any] ?? [:]
        var routes: [TailscaleServeRoute] = []

        for hostPort in web.keys.sorted() {
            guard let server = web[hostPort] as? [String: Any],
                  let handlers = (server["Handlers"] ?? server["handlers"]) as? [String: Any],
                  let split = splitHostPort(hostPort) else {
                throw TailscaleServeParseError.malformedRoute
            }
            let funnelEnabled = (funnel[hostPort] as? Bool) ?? false
            for path in handlers.keys.sorted() {
                guard let handler = handlers[path] as? [String: Any],
                      let proxy = (handler["Proxy"] ?? handler["proxy"]) as? String,
                      let proxyURL = URL(string: proxy), proxyURL.host != nil else {
                    throw TailscaleServeParseError.malformedRoute
                }
                routes.append(TailscaleServeRoute(
                    host: split.host,
                    port: split.port,
                    path: path,
                    proxyTarget: proxyURL,
                    funnelEnabled: funnelEnabled
                ))
            }
        }
        return TailscaleServeConfiguration(routes: routes)
    }

    private static func splitHostPort(_ value: String) -> (host: String, port: Int)? {
        guard let separator = value.lastIndex(of: ":"),
              let port = Int(value[value.index(after: separator)...]),
              (1...65_535).contains(port) else { return nil }
        var host = String(value[..<separator]).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        guard !host.isEmpty else { return nil }
        return (host, port)
    }
}
