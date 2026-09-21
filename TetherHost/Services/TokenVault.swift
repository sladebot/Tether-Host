import Foundation
import Security

public struct SecretValue: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let data: Data

    public init(data: Data) {
        self.data = data
    }

    public var byteCount: Int { data.count }
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }

    public func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
        try data.withUnsafeBytes(body)
    }
}

public enum SecretHandle: Hashable, Sendable {
    case activeHermes(VirtualMachineID)
    case pendingHermes(VirtualMachineID)

    fileprivate var account: String {
        switch self {
        case .activeHermes(let id): "vm.\(id.rawValue.uuidString).hermes.active"
        case .pendingHermes(let id): "vm.\(id.rawValue.uuidString).hermes.pending"
        }
    }
}

public protocol TokenGenerating: Sendable {
    func generate() throws -> SecretValue
}

public enum TokenGenerationError: Error, Equatable, Sendable {
    case randomSourceFailed(Int32)
}

public struct SecureTokenGenerator: TokenGenerating, Sendable {
    public let byteCount: Int

    public init(byteCount: Int = 32) {
        self.byteCount = max(byteCount, 32)
    }

    public func generate() throws -> SecretValue {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw TokenGenerationError.randomSourceFailed(status) }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return SecretValue(data: Data(encoded.utf8))
    }
}

public enum KeychainSecretStoreError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
}

public actor KeychainSecretStore: SecretStoring {
    private let service: String

    public init(service: String = "app.tether.host.hermes") {
        self.service = service
    }

    public func store(_ secret: SecretValue, for handle: SecretHandle) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: handle.account
        ]
        let changes: [String: Any] = [
            kSecValueData as String: secret.data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let update = SecItemUpdate(base as CFDictionary, changes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainSecretStoreError.unexpectedStatus(update) }
        var insertion = base
        changes.forEach { insertion[$0.key] = $0.value }
        let add = SecItemAdd(insertion as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainSecretStoreError.unexpectedStatus(add) }
    }

    public func load(_ handle: SecretHandle) throws -> SecretValue? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: handle.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainSecretStoreError.unexpectedStatus(status)
        }
        return SecretValue(data: data)
    }

    public func remove(_ handle: SecretHandle) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: handle.account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretStoreError.unexpectedStatus(status)
        }
    }
}

public enum TokenRotationError: Error, Equatable, Sendable {
    case noPendingToken
}

public actor TokenRotator {
    private let store: any SecretStoring
    private let generator: any TokenGenerating

    public init(store: any SecretStoring, generator: any TokenGenerating = SecureTokenGenerator()) {
        self.store = store
        self.generator = generator
    }

    /// Creates a pending token. The caller must deliver it over an authenticated channel,
    /// update Hermes, verify the new token, and only then call `commit`.
    public func begin(for id: VirtualMachineID) async throws -> SecretValue {
        let token = try generator.generate()
        try await store.store(token, for: .pendingHermes(id))
        return token
    }

    public func commit(for id: VirtualMachineID) async throws {
        guard let pending = try await store.load(.pendingHermes(id)) else {
            throw TokenRotationError.noPendingToken
        }
        try await store.store(pending, for: .activeHermes(id))
        try await store.remove(.pendingHermes(id))
    }

    public func rollback(for id: VirtualMachineID) async throws {
        try await store.remove(.pendingHermes(id))
    }
}
