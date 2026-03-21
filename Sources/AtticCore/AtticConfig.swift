import Foundation

/// S3 connection configuration stored at ~/.attic/config.json.
public struct AtticConfig: Codable, Equatable, Sendable {
    public var endpoint: String
    public var region: String
    public var bucket: String
    public var pathStyle: Bool
    public var keychain: KeychainConfig

    public struct KeychainConfig: Codable, Equatable, Sendable {
        public var accessKeyService: String
        public var secretKeyService: String

        public init(
            accessKeyService: String = "attic-s3-access-key",
            secretKeyService: String = "attic-s3-secret-key"
        ) {
            self.accessKeyService = accessKeyService
            self.secretKeyService = secretKeyService
        }
    }

    public init(
        endpoint: String,
        region: String,
        bucket: String,
        pathStyle: Bool = true,
        keychain: KeychainConfig = KeychainConfig()
    ) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.pathStyle = pathStyle
        self.keychain = keychain
    }
}

/// Protocol for loading and writing Attic configuration.
public protocol ConfigProviding: Sendable {
    func load() throws -> AtticConfig?
    func require() throws -> AtticConfig
    func write(_ config: AtticConfig) throws
}

/// File-based config provider reading from ~/.attic/config.json.
public struct FileConfigProvider: ConfigProviding {
    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".attic")
    }

    public func load() throws -> AtticConfig? {
        let path = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        let data = try Data(contentsOf: path)
        let raw = try JSONSerialization.jsonObject(with: data)
        return try AtticConfig.validate(raw)
    }

    public func require() throws -> AtticConfig {
        guard let config = try load() else {
            let path = directory.appendingPathComponent("config.json").path
            throw ConfigError.notFound(path)
        }
        return config
    }

    public func write(_ config: AtticConfig) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(config)
        data.append(contentsOf: "\n".utf8)

        let path = directory.appendingPathComponent("config.json")
        let tempPath = directory.appendingPathComponent("config.json.tmp")
        try data.write(to: tempPath, options: .atomic)
        // Move temp file into place (atomic on same filesystem)
        if fm.fileExists(atPath: path.path) {
            try fm.removeItem(at: path)
        }
        try fm.moveItem(at: tempPath, to: path)
        try fm.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path.path
        )
    }
}

// MARK: - Validation

private nonisolated(unsafe) let bucketPattern = /^[a-z0-9][a-z0-9.\-]{1,61}[a-z0-9]$/

extension AtticConfig {
    /// Validate a raw JSON object into an AtticConfig.
    static func validate(_ raw: Any) throws -> AtticConfig {
        guard let obj = raw as? [String: Any] else {
            throw ConfigError.invalid("Config must be a JSON object")
        }

        guard let endpoint = obj["endpoint"] as? String, !endpoint.isEmpty else {
            throw ConfigError.invalid(
                #"Config: "endpoint" is required (e.g. "https://s3.fr-par.scw.cloud")"#
            )
        }
        guard endpoint.hasPrefix("https://") else {
            throw ConfigError.invalid(
                #"Config: "endpoint" must start with https://"#
            )
        }

        guard let region = obj["region"] as? String, !region.isEmpty else {
            throw ConfigError.invalid(
                #"Config: "region" is required (e.g. "fr-par")"#
            )
        }

        guard let bucket = obj["bucket"] as? String, !bucket.isEmpty else {
            throw ConfigError.invalid(#"Config: "bucket" is required"#)
        }
        guard bucket.wholeMatch(of: bucketPattern) != nil else {
            throw ConfigError.invalid(
                "Config: \"bucket\" name \"\(bucket)\" is invalid. "
                + "Use lowercase letters, numbers, dots, and hyphens (3-63 chars)."
            )
        }

        let pathStyle: Bool
        if let ps = obj["pathStyle"] {
            pathStyle = (ps as? Bool) ?? true
        } else {
            pathStyle = true
        }

        let keychainObj = obj["keychain"] as? [String: Any] ?? [:]
        let accessKeyService = (keychainObj["accessKeyService"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "attic-s3-access-key"
        let secretKeyService = (keychainObj["secretKeyService"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "attic-s3-secret-key"

        return AtticConfig(
            endpoint: endpoint,
            region: region,
            bucket: bucket,
            pathStyle: pathStyle,
            keychain: KeychainConfig(
                accessKeyService: accessKeyService,
                secretKeyService: secretKeyService
            )
        )
    }
}

/// Configuration errors.
public enum ConfigError: Error, CustomStringConvertible {
    case notFound(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .notFound(let path):
            "No config file found at \(path)\n"
            + "Run \"attic init\" to set up your S3 connection, or create the file manually."
        case .invalid(let message):
            message
        }
    }
}
