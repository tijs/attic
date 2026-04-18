import Foundation

/// Record of an asset that iCloud cannot currently deliver (e.g. shared-album
/// asset whose derivative has failed server-side). These are excluded from
/// future backup runs to avoid wasting time on retries that will reliably
/// time out at ~5 minutes each.
public struct UnavailableAsset: Codable, Sendable, Equatable {
    public var uuid: String
    public var filename: String?
    public var reason: String
    public var firstFailedAt: String
    public var lastAttemptedAt: String
    public var attempts: Int

    public init(
        uuid: String,
        filename: String?,
        reason: String,
        firstFailedAt: String,
        lastAttemptedAt: String,
        attempts: Int,
    ) {
        self.uuid = uuid
        self.filename = filename
        self.reason = reason
        self.firstFailedAt = firstFailedAt
        self.lastAttemptedAt = lastAttemptedAt
        self.attempts = attempts
    }
}

public struct UnavailableAssets: Codable, Sendable {
    public var entries: [String: UnavailableAsset]

    public init(entries: [String: UnavailableAsset] = [:]) {
        self.entries = entries
    }

    public func contains(_ uuid: String) -> Bool {
        entries[uuid] != nil
    }

    public mutating func record(
        uuid: String,
        filename: String?,
        reason: String,
        now: Date = Date(),
    ) {
        let ts = formatISO8601(now)
        if var existing = entries[uuid] {
            existing.lastAttemptedAt = ts
            existing.attempts += 1
            existing.reason = reason
            if let filename { existing.filename = filename }
            entries[uuid] = existing
        } else {
            entries[uuid] = UnavailableAsset(
                uuid: uuid,
                filename: filename,
                reason: reason,
                firstFailedAt: ts,
                lastAttemptedAt: ts,
                attempts: 1,
            )
        }
    }
}

public protocol UnavailableAssetStoring: Sendable {
    func load() -> UnavailableAssets
    func save(_ assets: UnavailableAssets) throws
}

/// File-backed store at `~/.attic/unavailable-assets.json`.
public struct FileUnavailableAssetStore: UnavailableAssetStoring {
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? FileConfigProvider.defaultDirectory
        fileURL = dir.appendingPathComponent("unavailable-assets.json")
    }

    public func load() -> UnavailableAssets {
        guard let data = try? Data(contentsOf: fileURL) else {
            return UnavailableAssets()
        }
        return (try? JSONDecoder().decode(UnavailableAssets.self, from: data))
            ?? UnavailableAssets()
    }

    public func save(_ assets: UnavailableAssets) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(assets)

        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
