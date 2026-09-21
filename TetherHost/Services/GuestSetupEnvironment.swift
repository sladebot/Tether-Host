import Foundation
import Darwin

public enum GuestSetupEnvironment {
    public static var isVirtualMac: Bool {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0 else { return false }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return false }
        let modelBytes = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: modelBytes, as: UTF8.self).hasPrefix("VirtualMac")
    }

    public static var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tether Host for Mac/Guest Setup", isDirectory: true)
    }
}
