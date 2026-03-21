import Foundation
import Security

/// S3 credentials read from macOS Keychain.
public struct S3Credentials: Sendable {
    public let accessKeyId: String
    public let secretAccessKey: String

    public init(accessKeyId: String, secretAccessKey: String) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
    }
}

/// Protocol for reading and writing Keychain credentials.
public protocol KeychainProviding: Sendable {
    func loadCredentials(
        accessKeyService: String,
        secretKeyService: String
    ) throws -> S3Credentials

    func store(service: String, value: String) throws
}

/// Keychain provider using the macOS Security framework directly.
public struct SecurityKeychain: KeychainProviding {
    private static let account = "attic"

    public init() {}

    public func loadCredentials(
        accessKeyService: String = "attic-s3-access-key",
        secretKeyService: String = "attic-s3-secret-key"
    ) throws -> S3Credentials {
        let accessKeyId = try get(service: accessKeyService)
        let secretAccessKey = try get(service: secretKeyService)
        return S3Credentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey
        )
    }

    public func store(service: String, value: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]

        // Delete existing item first (SecItemUpdate doesn't create)
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = value.data(using: .utf8)!
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(
                service: service,
                status: status
            )
        }
    }

    private func get(service: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.readFailed(
                service: service,
                status: status
            )
        }

        return value
    }
}

/// Keychain errors.
public enum KeychainError: Error, CustomStringConvertible {
    case readFailed(service: String, status: OSStatus)
    case storeFailed(service: String, status: OSStatus)

    public var description: String {
        switch self {
        case .readFailed(let service, let status):
            "Failed to read keychain item \"\(service)\" (status: \(status)). "
            + "Store it with: security add-generic-password -s \(service) -a attic -w \"<value>\""
        case .storeFailed(let service, let status):
            "Failed to store credential in Keychain for service \"\(service)\" (status: \(status))"
        }
    }
}
