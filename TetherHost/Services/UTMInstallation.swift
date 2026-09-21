import Foundation

public enum UTMInstallation: Equatable, Sendable {
    public static let applicationURL = URL(fileURLWithPath: "/Applications/UTM.app", isDirectory: true)
    public static let downloadURL = URL(string: "https://mac.getutm.app/")!
    public static let macOSImageURL = URL(string: "https://ipsw.me/product/Mac/")!
    public static let macOSGuideURL = URL(string: "https://docs.getutm.app/guest-support/macos/#installation")!
    public static let supportedVersion = "4.7.x"

    case missing
    case invalidApplication
    case unsupportedVersion(String)
    case missingCommand
    case installed

    public var availability: VMProviderAvailability {
        switch self {
        case .missing:
            .blocked("Install UTM in Applications to continue. Download it below, drag UTM into Applications, then return here.")
        case .invalidApplication:
            .blocked("The app in Applications could not be identified as UTM. Reinstall UTM from the official download.")
        case .unsupportedVersion(let version):
            .blocked("UTM \(version) is installed. This Tether Host build supports UTM \(Self.supportedVersion). Install a compatible version or choose Built-in VM.")
        case .missingCommand:
            .blocked("UTM is installed, but its command tool is unavailable. Reinstall UTM in Applications, then check again.")
        case .installed:
            .ready
        }
    }

    public static func detect(at applicationURL: URL = Self.applicationURL) -> Self {
        let manager = FileManager.default
        guard manager.fileExists(atPath: applicationURL.path) else { return .missing }
        // Read from disk each time: Bundle metadata can stay cached across an installation/update.
        let infoURL = applicationURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.utmapp.UTM" else {
            return .invalidApplication
        }
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "4", parts[1] == "7", Int(parts[2]) != nil else {
            return .unsupportedVersion(version)
        }
        guard manager.isExecutableFile(atPath: applicationURL.appendingPathComponent("Contents/MacOS/utmctl").path) else {
            return .missingCommand
        }
        return .installed
    }
}
