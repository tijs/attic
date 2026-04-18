@testable import AtticCore
import Foundation
import LadderKit
import Testing

struct RetryQueueTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry-queue-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func loadReturnsNilWhenNoFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileRetryQueueStore(directory: dir)
        #expect(store.load() == nil)
    }

    private func makeEntry(_ uuid: String, at timestamp: String = "2025-01-15T12:00:00Z") -> RetryEntry {
        RetryEntry(uuid: uuid, firstFailedAt: timestamp, lastFailedAt: timestamp)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileRetryQueueStore(directory: dir)
        let queue = RetryQueue(
            entries: ["uuid-1", "uuid-2", "uuid-3"].map { makeEntry($0) },
            updatedAt: "2025-01-15T12:00:00Z",
        )
        try store.save(queue)

        let loaded = store.load()
        #expect(loaded != nil)
        #expect(loaded?.failedUUIDs == ["uuid-1", "uuid-2", "uuid-3"])
        #expect(loaded?.updatedAt == "2025-01-15T12:00:00Z")
    }

    @Test func clearRemovesFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileRetryQueueStore(directory: dir)
        let queue = RetryQueue(entries: [makeEntry("uuid-1")], updatedAt: "2025-01-15T12:00:00Z")
        try store.save(queue)
        #expect(store.load() != nil)

        try store.clear()
        #expect(store.load() == nil)
    }

    @Test func clearNoOpWhenNoFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileRetryQueueStore(directory: dir)
        try store.clear() // should not throw
    }

    @Test func saveOverwritesPrevious() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileRetryQueueStore(directory: dir)
        try store.save(RetryQueue(entries: [makeEntry("old")], updatedAt: "2025-01-01T00:00:00Z"))
        try store.save(RetryQueue(
            entries: [makeEntry("new-1"), makeEntry("new-2")],
            updatedAt: "2025-01-02T00:00:00Z",
        ))

        let loaded = store.load()
        #expect(loaded?.failedUUIDs == ["new-1", "new-2"])
    }

    @Test("New schema roundtrips with classification, attempts, and timestamps")
    func roundtripsNewSchema() throws {
        let entry = RetryEntry(
            uuid: "uuid-1",
            classification: .transientCloud,
            attempts: 3,
            firstFailedAt: "2025-01-01T00:00:00Z",
            lastFailedAt: "2025-01-03T00:00:00Z",
            lastMessage: "throttled",
        )
        let queue = RetryQueue(entries: [entry], updatedAt: "2025-01-03T00:00:00Z")

        let data = try JSONEncoder().encode(queue)
        let decoded = try JSONDecoder().decode(RetryQueue.self, from: data)

        #expect(decoded.entries == [entry])
        #expect(decoded.updatedAt == "2025-01-03T00:00:00Z")
    }

    @Test("`merged` preserves firstFailedAt and increments attempts across runs")
    func mergedIncrementsAttempts() {
        let previous = RetryQueue(
            entries: [
                RetryEntry(
                    uuid: "uuid-1",
                    classification: .transientCloud,
                    attempts: 2,
                    firstFailedAt: "2025-01-01T00:00:00Z",
                    lastFailedAt: "2025-01-02T00:00:00Z",
                    lastMessage: "throttled",
                ),
            ],
            updatedAt: "2025-01-02T00:00:00Z",
        )
        let failures = [
            FailureRecord(uuid: "uuid-1", classification: .transientCloud, message: "still throttled"),
            FailureRecord(uuid: "uuid-2", classification: .other, message: "upload failed"),
        ]

        let merged = RetryQueue.merged(
            previous: previous,
            attempted: ["uuid-1", "uuid-2"],
            failures: failures,
            now: "2025-01-03T00:00:00Z",
        )

        let byUUID = Dictionary(uniqueKeysWithValues: merged.entries.map { ($0.uuid, $0) })
        #expect(byUUID["uuid-1"]?.attempts == 3)
        #expect(byUUID["uuid-1"]?.firstFailedAt == "2025-01-01T00:00:00Z")
        #expect(byUUID["uuid-1"]?.lastFailedAt == "2025-01-03T00:00:00Z")
        #expect(byUUID["uuid-1"]?.lastMessage == "still throttled")

        #expect(byUUID["uuid-2"]?.attempts == 1)
        #expect(byUUID["uuid-2"]?.firstFailedAt == "2025-01-03T00:00:00Z")
    }

    @Test("`merged` drops attempted UUIDs that succeeded this run")
    func mergedDropsResolvedUUIDs() {
        let previous = RetryQueue(
            entries: [makeEntry("uuid-1", at: "2025-01-01T00:00:00Z"), makeEntry("uuid-2", at: "2025-01-01T00:00:00Z")],
            updatedAt: "2025-01-01T00:00:00Z",
        )

        let merged = RetryQueue.merged(
            previous: previous,
            attempted: ["uuid-1", "uuid-2"],
            failures: [FailureRecord(uuid: "uuid-2", classification: .other, message: "still failing")],
            now: "2025-01-02T00:00:00Z",
        )

        #expect(merged.failedUUIDs == ["uuid-2"])
    }

    @Test("`merged` preserves prior entries that weren't attempted this run")
    func mergedPreservesUnattemptedEntries() {
        let previous = RetryQueue(
            entries: [
                RetryEntry(
                    uuid: "not-attempted",
                    classification: .transientCloud,
                    attempts: 5,
                    firstFailedAt: "2025-01-01T00:00:00Z",
                    lastFailedAt: "2025-01-04T00:00:00Z",
                    lastMessage: "still throttled",
                ),
                RetryEntry(
                    uuid: "succeeded",
                    classification: .other,
                    attempts: 2,
                    firstFailedAt: "2025-01-02T00:00:00Z",
                    lastFailedAt: "2025-01-04T00:00:00Z",
                ),
            ],
            updatedAt: "2025-01-04T00:00:00Z",
        )

        let merged = RetryQueue.merged(
            previous: previous,
            attempted: ["succeeded"],
            failures: [],
            now: "2025-01-05T00:00:00Z",
        )

        #expect(merged.entries.count == 1)
        #expect(merged.entries[0].uuid == "not-attempted")
        #expect(merged.entries[0].attempts == 5)
        #expect(merged.entries[0].firstFailedAt == "2025-01-01T00:00:00Z")
    }

    @Test("`merged` with nil previous starts everything at attempts = 1")
    func mergedFromNothing() {
        let merged = RetryQueue.merged(
            previous: nil,
            attempted: ["uuid-1"],
            failures: [
                FailureRecord(uuid: "uuid-1", classification: .transientCloud, message: "boom"),
            ],
            now: "2025-02-01T00:00:00Z",
        )

        #expect(merged.entries.count == 1)
        #expect(merged.entries[0].attempts == 1)
        #expect(merged.entries[0].firstFailedAt == "2025-02-01T00:00:00Z")
        #expect(merged.entries[0].classification == .transientCloud)
    }
}
