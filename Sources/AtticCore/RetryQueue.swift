import Foundation

/// UUIDs that failed in the most recent backup run, persisted for retry-first priority.
public struct RetryQueue: Codable, Sendable {
    public var failedUUIDs: [String]
    public var updatedAt: String

    public init(failedUUIDs: [String], updatedAt: String) {
        self.failedUUIDs = failedUUIDs
        self.updatedAt = updatedAt
    }
}

/// Persistence for the retry queue.
public protocol RetryQueueProviding: Sendable {
    func load() -> RetryQueue?
    func save(_ queue: RetryQueue) throws
    func clear() throws
}

/// File-backed retry queue at `~/.attic/retry-queue.json`.
public struct FileRetryQueueStore: RetryQueueProviding {
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? FileConfigProvider.defaultDirectory
        fileURL = dir.appendingPathComponent("retry-queue.json")
    }

    public func load() -> RetryQueue? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(RetryQueue.self, from: data)
    }

    public func save(_ queue: RetryQueue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(queue)

        // Ensure directory exists
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try data.write(to: fileURL, options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
