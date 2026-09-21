import Foundation

public enum GuestDependencyState: String, Codable, Sendable {
    case installed
    case missing
    case needsConfiguration
}

public struct GuestDependencyStatus: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let state: GuestDependencyState
    public let detail: String

    public init(id: String, title: String, state: GuestDependencyState, detail: String) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
    }
}

/// Reads only guest-local paths. Callers must establish that the app is running
/// inside a supported VM before presenting these results as guest evidence.
public enum GuestDependencyScanner {
    public static func scan(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    ) -> [GuestDependencyStatus] {
        let manager = FileManager.default
        let hermesRoot = homeDirectory.appendingPathComponent(".hermes/hermes-agent", isDirectory: true)
        let hermes = hermesRoot.appendingPathComponent("venv/bin/hermes")
        let python = hermesRoot.appendingPathComponent("venv/bin/python")
        let tailscale = applicationsDirectory.appendingPathComponent("Tailscale.app/Contents/MacOS/Tailscale")
        let tailscaleStatus = homeDirectory.appendingPathComponent(
            "Library/Application Support/Tether Host for Mac/Guest Setup/tailscale-status.json"
        )
        let environment = homeDirectory.appendingPathComponent(".hermes/.env")
        let receipt = homeDirectory.appendingPathComponent(
            "Library/Application Support/Tether Host for Mac/Guest Setup/connection.json"
        )

        let hermesInstalled = manager.isExecutableFile(atPath: hermes.path)
            && manager.isExecutableFile(atPath: python.path)
        let tailscaleInstalled = manager.isExecutableFile(atPath: tailscale.path)
        let tailscaleReady = tailscaleInstalled && validTailnetStatus(at: tailscaleStatus)
        let apiReady = hasValidAPIConfiguration(at: environment)
        let receiptReady = isPrivateRegularFile(receipt, manager: manager)

        return [
            GuestDependencyStatus(
                id: "tailscale",
                title: "Tailscale",
                state: tailscaleReady ? .installed : (tailscaleInstalled ? .needsConfiguration : .missing),
                detail: tailscaleReady
                    ? "The last guest setup check found Tailscale connected inside this VM."
                    : (tailscaleInstalled
                       ? "Installed in this VM; sign-in or connection still needs attention."
                       : "Missing from this VM; setup will install it and request Apple approval.")
            ),
            GuestDependencyStatus(
                id: "hermes",
                title: "Hermes",
                state: hermesInstalled ? (apiReady ? .installed : .needsConfiguration) : .missing,
                detail: hermesInstalled
                    ? (apiReady
                       ? "Installed and configured for Tether in this VM; the token value remains hidden."
                       : "Installed in this VM; API and model configuration still need attention.")
                    : "Missing from this VM; setup will install the pinned runtime."
            ),
            GuestDependencyStatus(
                id: "verification",
                title: "Verified Tether connection",
                state: receiptReady ? .installed : .needsConfiguration,
                detail: receiptReady ? "A private verified connection receipt exists." : "Created only after API, Tailscale, CUA, and model checks pass."
            )
        ]
    }

    private static func validTailnetStatus(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) < 1_048_576,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["BackendState"] as? String == "Running",
              let host = (object["Self"] as? [String: Any])?["DNSName"] as? String else { return false }
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return normalized.hasSuffix(".ts.net") && normalized.split(separator: ".").count >= 4
    }

    private static func hasValidAPIConfiguration(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) < 1_048_576,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return false }
        let values = Dictionary(uniqueKeysWithValues: text.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else { return nil }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return (key, value)
        })
        guard values["API_SERVER_ENABLED"]?.lowercased() == "true",
              values["API_SERVER_HOST"] == "127.0.0.1",
              values["API_SERVER_PORT"] == "8642",
              let token = values["API_SERVER_KEY"],
              (32...256).contains(token.count) else { return false }
        return token.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }

    private static func isPrivateRegularFile(_ url: URL, manager: FileManager) -> Bool {
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { return false }
        return true
    }
}
