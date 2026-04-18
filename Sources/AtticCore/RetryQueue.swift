import Foundation
import LadderKit

/// Per-asset retry bookkeeping. Tracks how long a UUID has been failing so
/// the UI (and future policy like "give up after N runs") can act on it.
public struct RetryEntry: Codable, Sendable, Equatable {
    public var uuid: String
    public var classification: ExportClassification
    public var attempts: Int
    public var firstFailedAt: String
    public var lastFailedAt: String
    public var lastMessage: String?

    public init(
        uuid: String,
        classification: ExportClassification = .other,
        attempts: Int = 1,
        firstFailedAt: String,
        lastFailedAt: String,
        lastMessage: String? = nil,
    ) {
        self.uuid = uuid
        self.classification = classification
        self.attempts = attempts
        self.firstFailedAt = firstFailedAt
        self.lastFailedAt = lastFailedAt
        self.lastMessage = lastMessage
    }

    private enum CodingKeys: String, CodingKey {
        case uuid, classification, attempts, firstFailedAt, lastFailedAt, lastMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(String.self, forKey: .uuid)
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 1
        firstFailedAt = try container.decodeIfPresent(String.self, forKey: .firstFailedAt) ?? ""
        lastFailedAt = try container.decodeIfPresent(String.self, forKey: .lastFailedAt) ?? firstFailedAt
        lastMessage = try container.decodeIfPresent(String.self, forKey: .lastMessage)
        classification = try container.decodeIfPresent(
            ExportClassification.self, forKey: .classification,
        ) ?? .other
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(classification, forKey: .classification)
        try container.encode(attempts, forKey: .attempts)
        try container.encode(firstFailedAt, forKey: .firstFailedAt)
        try container.encode(lastFailedAt, forKey: .lastFailedAt)
        try container.encodeIfPresent(lastMessage, forKey: .lastMessage)
    }
}

/// Assets that failed in recent runs, persisted so the next run retries them
/// first and the UI can surface how long something's been stuck.
public struct RetryQueue: Codable, Sendable, Equatable {
    public var entries: [RetryEntry]
    public var updatedAt: String

    public init(entries: [RetryEntry], updatedAt: String) {
        self.entries = entries
        self.updatedAt = updatedAt
    }

    /// Convenience initializer for call sites that only care about UUIDs
    /// (mainly tests). Each UUID gets a fresh entry with attempts = 1.
    public init(failedUUIDs: [String], updatedAt: String) {
        self.entries = failedUUIDs.map {
            RetryEntry(
                uuid: $0,
                classification: .other,
                attempts: 1,
                firstFailedAt: updatedAt,
                lastFailedAt: updatedAt,
            )
        }
        self.updatedAt = updatedAt
    }

    /// UUIDs in insertion order. Used by the pipeline to partition pending
    /// assets so failed ones are retried first.
    public var failedUUIDs: [String] {
        entries.map(\.uuid)
    }

    private enum CodingKeys: String, CodingKey {
        case entries, failedUUIDs, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedUpdatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""

        let decodedEntries: [RetryEntry]
        if let entries = try container.decodeIfPresent([RetryEntry].self, forKey: .entries) {
            decodedEntries = entries
        } else if let legacy = try container.decodeIfPresent([String].self, forKey: .failedUUIDs) {
            // Migrate from pre-beta.6 schema: `failedUUIDs: [String]`.
            decodedEntries = legacy.map {
                RetryEntry(
                    uuid: $0,
                    classification: .other,
                    attempts: 1,
                    firstFailedAt: decodedUpdatedAt,
                    lastFailedAt: decodedUpdatedAt,
                )
            }
        } else {
            decodedEntries = []
        }

        updatedAt = decodedUpdatedAt
        entries = decodedEntries
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    /// Merge a run's outcome into a previous queue.
    ///
    /// - `attempted` is the set of bare UUIDs actually processed in this run.
    ///   UUIDs in the previous queue that weren't attempted (typically cut
    ///   off by `--limit`) are carried forward unchanged so their
    ///   `attempts` and `firstFailedAt` history survives.
    /// - UUIDs in `attempted` ∩ `failures` are merged: prior `attempts + 1`,
    ///   preserved `firstFailedAt`, refreshed `lastFailedAt`/`lastMessage`.
    /// - UUIDs in `attempted` but not in `failures` are dropped — they
    ///   succeeded this run, or landed in the unavailable store.
    /// - Brand-new failing UUIDs start at `attempts = 1`.
    public static func merged(
        previous: RetryQueue?,
        attempted: Set<String>,
        failures: [FailureRecord],
        now: String,
    ) -> RetryQueue {
        let priorEntries = previous?.entries ?? []
        let priorByUUID = Dictionary(uniqueKeysWithValues: priorEntries.map { ($0.uuid, $0) })

        // Carry forward prior entries we didn't attempt.
        var entries = priorEntries.filter { !attempted.contains($0.uuid) }

        // Merge / create entries for new failures.
        for failure in failures {
            if let prior = priorByUUID[failure.uuid] {
                entries.append(RetryEntry(
                    uuid: failure.uuid,
                    classification: failure.classification,
                    attempts: prior.attempts + 1,
                    firstFailedAt: prior.firstFailedAt,
                    lastFailedAt: now,
                    lastMessage: failure.message,
                ))
            } else {
                entries.append(RetryEntry(
                    uuid: failure.uuid,
                    classification: failure.classification,
                    attempts: 1,
                    firstFailedAt: now,
                    lastFailedAt: now,
                    lastMessage: failure.message,
                ))
            }
        }

        return RetryQueue(entries: entries, updatedAt: now)
    }
}

/// A single failure as seen by the pipeline — richer than `BackupReport.errors`
/// because it carries the classification used by `RetryQueue.merged`.
public struct FailureRecord: Sendable, Equatable {
    public var uuid: String
    public var classification: ExportClassification
    public var message: String

    public init(uuid: String, classification: ExportClassification, message: String) {
        self.uuid = uuid
        self.classification = classification
        self.message = message
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
