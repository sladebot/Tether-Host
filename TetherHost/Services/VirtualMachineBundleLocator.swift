import Foundation

/// Resolves an inventory UUID to a local VM bundle. Names are never used because
/// UTM can register multiple VMs with the same display name.
public struct VirtualMachineBundleLocator: Sendable {
    public let nativeRoot: URL
    public let utmRoots: [URL]

    public init(nativeRoot: URL, utmRoots: [URL]) {
        self.nativeRoot = nativeRoot.standardizedFileURL
        self.utmRoots = utmRoots.map(\.standardizedFileURL)
    }

    public func locate(_ id: VirtualMachineID, provider: VMProvider) -> URL? {
        switch provider {
        case .builtIn: locateNative(id)
        case .utm: locateUTM(id)
        }
    }

    private func locateNative(_ id: VirtualMachineID) -> URL? {
        let bundle = nativeRoot.appendingPathComponent(id.description, isDirectory: true)
        guard isPlainDirectory(bundle) else { return nil }
        let manifestURL = bundle.appendingPathComponent(NativeVirtualMachineStore.manifestFilename)
        guard isPlainFile(manifestURL),
              let data = try? Data(contentsOf: manifestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(NativeVirtualMachineManifest.self, from: data),
              manifest.id == id else { return nil }
        return bundle
    }

    private func locateUTM(_ id: VirtualMachineID) -> URL? {
        var matches: [URL] = []
        for root in utmRoots where isPlainDirectory(root) {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for bundle in children where bundle.pathExtension.lowercased() == "utm" && isPlainDirectory(bundle) {
                let config = bundle.appendingPathComponent("config.plist")
                guard isPlainFile(config),
                      let data = try? Data(contentsOf: config),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let information = plist["Information"] as? [String: Any],
                      let uuid = information["UUID"] as? String,
                      VirtualMachineID(uuid) == id else { continue }
                matches.append(bundle)
            }
        }
        // A moved or duplicate registration must not reveal a guessed bundle.
        return matches.count == 1 ? matches[0] : nil
    }

    private func isPlainDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func isPlainFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
