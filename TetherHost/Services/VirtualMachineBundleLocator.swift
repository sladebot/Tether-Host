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
        let registry = NativeVMStorageRegistry(defaultRootURL: nativeRoot)
        let bundle = registry.location(of: id) ?? nativeRoot.appendingPathComponent(id.description, isDirectory: true)
        // A known external VM must never resolve to a newly created local
        // directory when its original volume is disconnected.
        if registry.lastKnownLocation(of: id) != nil && registry.location(of: id) == nil { return nil }
        guard isPlainDirectory(bundle) else { return nil }
        let manifestURL = bundle.appendingPathComponent(NativeVirtualMachineStore.manifestFilename)
        guard isPlainFile(manifestURL),
              let data = try? Data(contentsOf: manifestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(NativeVirtualMachineManifest.self, from: data),
              manifest.id == id,
              manifest.schemaVersion == NativeVirtualMachineManifest.currentSchemaVersion else { return nil }
        return bundle
    }

    private func locateUTM(_ id: VirtualMachineID) -> URL? {
        var matches: [URL] = []
        let registry = NativeVMStorageRegistry(defaultRootURL: nativeRoot)
        if registry.lastKnownLocation(of: id, provider: .utm) != nil {
            guard let registered = registry.location(of: id, provider: .utm),
                  isUTMBundle(registered, id: id) else { return nil }
            return registered
        }
        for root in utmRoots where isPlainDirectory(root) {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for bundle in children where bundle.pathExtension.lowercased() == "utm" {
                if isUTMBundle(bundle, id: id), !matches.contains(bundle) { matches.append(bundle) }
            }
        }
        // A moved or duplicate registration must not reveal a guessed bundle.
        return matches.count == 1 ? matches[0] : nil
    }

    private func isUTMBundle(_ bundle: URL, id: VirtualMachineID) -> Bool {
        guard isPlainDirectory(bundle) else { return false }
        let config = bundle.appendingPathComponent("config.plist")
        guard isPlainFile(config),
              let data = try? Data(contentsOf: config),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let information = plist["Information"] as? [String: Any],
              let uuid = information["UUID"] as? String else { return false }
        return VirtualMachineID(uuid) == id
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
