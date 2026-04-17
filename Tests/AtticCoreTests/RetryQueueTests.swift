import Foundation
import Testing

@testable import AtticCore

@Suite struct RetryQueueTests {
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

    @Test func saveAndLoadRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileRetryQueueStore(directory: dir)
        let queue = RetryQueue(
            failedUUIDs: ["uuid-1", "uuid-2", "uuid-3"],
            updatedAt: "2025-01-15T12:00:00Z"
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
        let queue = RetryQueue(failedUUIDs: ["uuid-1"], updatedAt: "2025-01-15T12:00:00Z")
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
        try store.save(RetryQueue(failedUUIDs: ["old"], updatedAt: "2025-01-01T00:00:00Z"))
        try store.save(RetryQueue(failedUUIDs: ["new-1", "new-2"], updatedAt: "2025-01-02T00:00:00Z"))

        let loaded = store.load()
        #expect(loaded?.failedUUIDs == ["new-1", "new-2"])
    }
}
