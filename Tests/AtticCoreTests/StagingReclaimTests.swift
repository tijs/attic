import Foundation
import LadderKit
import Testing

@testable import AtticCore

@Suite struct StagingReclaimTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-reclaim-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFile(_ dir: URL, name: String, content: String = "test data") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func emptyDirReturnsAllAsRemaining() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = reclaimStagedFiles(uuids: ["uuid-1", "uuid-2"], stagingDir: dir)
        #expect(result.reclaimed.isEmpty)
        #expect(result.remaining == ["uuid-1", "uuid-2"])
    }

    @Test func reclaimsExistingFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try writeFile(dir, name: "uuid-1_IMG_0001.HEIC", content: "photo data")

        let result = reclaimStagedFiles(uuids: ["uuid-1"], stagingDir: dir)
        #expect(result.reclaimed.count == 1)
        #expect(result.reclaimed[0].uuid == "uuid-1")
        #expect(result.reclaimed[0].size > 0)
        #expect(!result.reclaimed[0].sha256.isEmpty)
        #expect(result.remaining.isEmpty)
    }

    @Test func mixOfReclaimedAndRemaining() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try writeFile(dir, name: "uuid-1_IMG_0001.HEIC")
        // uuid-2 has no file

        let result = reclaimStagedFiles(uuids: ["uuid-1", "uuid-2"], stagingDir: dir)
        #expect(result.reclaimed.count == 1)
        #expect(result.reclaimed[0].uuid == "uuid-1")
        #expect(result.remaining == ["uuid-2"])
    }

    @Test func deduplicatesMultipleFilesPerUUID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Simulate PhotoKit + AppleScript both producing files
        _ = try writeFile(dir, name: "uuid-1_IMG_2383.MOV", content: "photokit version")
        _ = try writeFile(dir, name: "uuid-1_L0_001_IMG_2383.MOV", content: "applescript version")

        let result = reclaimStagedFiles(uuids: ["uuid-1"], stagingDir: dir)
        #expect(result.reclaimed.count == 1)
        #expect(result.remaining.isEmpty)

        // Only one file should remain in the dir
        let remaining = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )
        #expect(remaining.count == 1)
    }

    @Test func ignoresFilesNotMatchingRequestedUUIDs() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try writeFile(dir, name: "other-uuid_IMG_0001.HEIC")
        _ = try writeFile(dir, name: "uuid-1_IMG_0002.HEIC")

        let result = reclaimStagedFiles(uuids: ["uuid-1"], stagingDir: dir)
        #expect(result.reclaimed.count == 1)
        #expect(result.reclaimed[0].uuid == "uuid-1")

        // The other-uuid file should still exist (untouched)
        let allFiles = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )
        #expect(allFiles.count == 2)
    }

    @Test func recomputesSHA256Correctly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let content = "known content for hashing"
        let url = try writeFile(dir, name: "uuid-1_test.txt", content: content)

        // Compute expected hash
        let expectedHash = try FileHasher.sha256(fileAt: url)

        let result = reclaimStagedFiles(uuids: ["uuid-1"], stagingDir: dir)
        #expect(result.reclaimed[0].sha256 == expectedHash)
    }

    @Test func handlesNonexistentStagingDir() {
        let bogus = URL(fileURLWithPath: "/tmp/nonexistent-staging-\(UUID().uuidString)")
        let result = reclaimStagedFiles(uuids: ["uuid-1"], stagingDir: bogus)
        #expect(result.reclaimed.isEmpty)
        #expect(result.remaining == ["uuid-1"])
    }
}
