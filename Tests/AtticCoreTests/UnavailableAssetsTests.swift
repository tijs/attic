@testable import AtticCore
import Foundation
import Testing

struct UnavailableAssetsTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unavailable-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func loadReturnsEmptyWhenNoFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileUnavailableAssetStore(directory: dir)
        #expect(store.load().entries.isEmpty)
    }

    @Test func recordNewEntryCreatesAttemptOne() {
        var assets = UnavailableAssets()
        assets.record(uuid: "u1", filename: "IMG.HEIC", reason: "shared unavailable")

        let entry = assets.entries["u1"]
        #expect(entry?.attempts == 1)
        #expect(entry?.filename == "IMG.HEIC")
        #expect(entry?.firstFailedAt == entry?.lastAttemptedAt)
    }

    @Test func recordSameUUIDIncrementsAttempts() {
        var assets = UnavailableAssets()
        let t1 = Date(timeIntervalSince1970: 1_000_000)
        let t2 = Date(timeIntervalSince1970: 1_000_100)

        assets.record(uuid: "u1", filename: "IMG.HEIC", reason: "first fail", now: t1)
        assets.record(uuid: "u1", filename: nil, reason: "second fail", now: t2)

        let entry = assets.entries["u1"]
        #expect(entry?.attempts == 2)
        #expect(entry?.firstFailedAt != entry?.lastAttemptedAt)
        #expect(entry?.filename == "IMG.HEIC") // nil does not overwrite existing
        #expect(entry?.reason == "second fail")
    }

    @Test func saveAndLoadRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileUnavailableAssetStore(directory: dir)
        var assets = UnavailableAssets()
        assets.record(uuid: "u1", filename: "a.jpg", reason: "r1")
        assets.record(uuid: "u2", filename: nil, reason: "r2")
        try store.save(assets)

        let loaded = store.load()
        #expect(loaded.contains("u1"))
        #expect(loaded.contains("u2"))
        #expect(loaded.entries.count == 2)
    }
}
