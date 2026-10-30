import CryptoKit
import Foundation

/// Named configurations keep backup targets and local retry/export state independent.
/// No profile preserves the existing ~/.attic S3 installation.
public struct AtticProfile: Sendable {
    public let directory: URL
    private let isDefault: Bool

    public init(name: String? = nil, baseDirectory: URL = FileConfigProvider.defaultDirectory) throws {
        isDefault = name == nil
        if let name {
            guard !name.isEmpty, name.count <= 64, name != ".", name != "..",
                  name.unicodeScalars.allSatisfy({
                      CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
                          .contains($0)
                  })
            else { throw ConfigError.invalid("Profile must contain 1-64 letters, digits, hyphens or underscores") }
            directory = baseDirectory.appendingPathComponent("profiles").appendingPathComponent(name)
        } else {
            directory = baseDirectory
        }
    }

    public func stateDirectory(config: AtticConfig) throws -> URL {
        if let target = config.filesystem {
            return directory.appendingPathComponent("targets").appendingPathComponent(target.targetID)
        } else {
            let identity = try JSONEncoder().encode([
                config.endpoint,
                config.region,
                config.bucket,
                String(config.pathStyle),
            ])
            let fingerprint = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            if isDefault {
                // Bind pre-profile local state once to preserve existing installations.
                // Subsequent endpoint/bucket changes get their own state directory.
                let binding = directory.appendingPathComponent("legacy-state-target")
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700],
                )
                do {
                    try Data(fingerprint.utf8).write(to: binding, options: .withoutOverwriting)
                } catch CocoaError.fileWriteFileExists {
                    // Another call already bound the existing state.
                }
                if try String(contentsOf: binding, encoding: .utf8) == fingerprint { return directory }
            }
            return directory.appendingPathComponent("targets").appendingPathComponent(fingerprint)
        }
    }
}
