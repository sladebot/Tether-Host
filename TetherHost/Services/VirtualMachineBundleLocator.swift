import Foundation

/// Resolves an inventory UUID to a local VM bundle. Names are never used.
public struct VirtualMachineBundleLocator: Sendable {
    public let nativeRoot: URL

    public init(nativeRoot: URL) {
        self.nativeRoot = nativeRoot.standardizedFileURL
    }

    public func locate(_ id: VirtualMachineID) -> URL? {
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

    private func isPlainDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func isPlainFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
