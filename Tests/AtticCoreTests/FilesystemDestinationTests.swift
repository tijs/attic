@testable import AtticCLI
@testable import AtticCore
import Foundation
import LadderKit
import Testing

struct FilesystemDestinationTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attic-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    @Test func requiresExistingEmptyRootAndRejectsCopiedIdentity() throws {
        let root = try directory()
        let other = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        #expect(throws: FilesystemError.self) {
            try FilesystemDestination.initialize(at: root.appendingPathComponent("absent"))
        }
        let sentinel = root.appendingPathComponent("unrelated")
        try Data("keep".utf8).write(to: sentinel)
        #expect(throws: FilesystemError.self) { try FilesystemDestination.initialize(at: root) }
        try FileManager.default.removeItem(at: sentinel)
        let destination = try FilesystemDestination.initialize(at: root)
        #expect(try FilesystemDestination.initialize(at: root) == destination)
        let marker = root.appendingPathComponent(".attic-target.json")
        try FileManager.default.copyItem(at: marker, to: other.appendingPathComponent(".attic-target.json"))
        #expect(throws: FilesystemError.self) { try FilesystemDestination.initialize(at: other) }
        var changed = destination
        changed.path = other.path
        #expect(throws: FilesystemError.self) { try FilesystemObjectStore(destination: changed) }
    }

    @Test func independentTargetsAndCaseSensitiveObjectIdentity() async throws {
        let firstRoot = try directory()
        let secondRoot = try directory()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let first = try FilesystemObjectStore(destination: FilesystemDestination.initialize(at: firstRoot))
        let second = try FilesystemObjectStore(destination: FilesystemDestination.initialize(at: secondRoot))
        let keys = ["originals/2024/01/A.heic", "originals/2024/01/a.heic", "originals/2024/01/id%2Fplus%2B.heic"]
        for (index, key) in keys.enumerated() {
            try await first.putObject(key: key, body: Data([UInt8(index)]))
        }
        #expect(try await first.listObjects(prefix: "originals/").map(\.key).sorted() == keys.sorted())
        #expect(try await first.listObjects(prefix: "originals/").count == 3)
        for (index, key) in keys.enumerated() {
            #expect(try await first.getObject(key: key) == Data([UInt8(index)]))
        }
        #expect(try await second.listObjects(prefix: "").isEmpty)
        #expect(try await second.headObject(key: keys[0]) == nil)
        await #expect(throws: FilesystemError.self) { try await first.deleteObject(key: keys[0]) }
    }

    @Test func freshFilesystemManifestIgnoresLegacyLocalState() async throws {
        let root = try directory()
        let legacy = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: legacy)
        }
        let local = Manifest(entries: ["old": ManifestEntry(
            uuid: "old", s3Key: "originals/old.heic", checksum: "sha256:abc", backedUpAt: "2024-01-01",
        )])
        try local.encoded().write(to: legacy.appendingPathComponent("manifest.json"))
        let objectStore = try FilesystemObjectStore(destination: FilesystemDestination.initialize(at: root))
        let store = ObjectManifestStore(s3: objectStore, allowsLegacyLocalMigration: false)
        let loaded = try await Dependencies.loadManifest(store: store, localDirectory: legacy)
        #expect(loaded.entries.isEmpty)
        #expect(loaded.version == 2)
        #expect(loaded.thumbnailsCleanupApplied)
        #expect(try await objectStore.headObject(key: manifestS3Key) == nil)
    }

    @Test func profilesIsolateS3TargetsFilesystemTargetsAndLegacyState() throws {
        let base = try directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let defaultProfile = try AtticProfile(baseDirectory: base)
        let named = try AtticProfile(name: "external", baseDirectory: base)
        let first = AtticConfig(endpoint: "https://example.test", region: "eu", bucket: "first")
        let second = AtticConfig(endpoint: "https://example.test", region: "eu", bucket: "second")
        #expect(try defaultProfile.stateDirectory(config: first) == base)
        #expect(try defaultProfile.stateDirectory(config: second) != base)
        #expect(try defaultProfile.stateDirectory(config: first) == base)
        #expect(try named.stateDirectory(config: first) != named.stateDirectory(config: second))
        let fsRoot = base.appendingPathComponent("fs")
        try FileManager.default.createDirectory(at: fsRoot, withIntermediateDirectories: true)
        let fs = try AtticConfig(filesystem: FilesystemDestination.initialize(at: fsRoot))
        #expect(try named.stateDirectory(config: fs) != named.stateDirectory(config: first))
        let provider = FileConfigProvider(directory: named.directory)
        try provider.write(fs)
        #expect(try provider.require() == fs)
        for name in ["../bad", ".", "", "a/b"] {
            #expect(throws: ConfigError.self) { try AtticProfile(name: name, baseDirectory: base) }
        }
    }

    @Test func filesystemStatusHasOwnJSONSectionAndNoS3Label() throws {
        var data = DashboardData(
            version: "test", library: LibraryStats(photos: 1, videos: 0, favorites: 0, edited: 0),
            backup: BackupStats(backedUp: 1, backedUpBytes: 5, pending: 0, total: 1),
            s3: S3Info(bucket: "/Volumes/Backup/Attic", manifestEntries: 1, lastBackup: nil), types: [],
        )
        data.filesystemPath = "/Volumes/Backup/Attic"
        let parsed = try #require(JSONSerialization.jsonObject(with: formatDashboardJSON(data)) as? [String: Any])
        #expect(parsed["s3"] == nil)
        let filesystem = try #require(parsed["filesystem"] as? [String: Any])
        #expect(filesystem["path"] as? String == "/Volumes/Backup/Attic")
        #expect(filesystem["manifestEntries"] as? Int == 1)
    }

    @Test func oversizedEncodedKeyFailsWithoutPublishing() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FilesystemObjectStore(destination: FilesystemDestination.initialize(at: root))
        await #expect(throws: FilesystemError.self) {
            try await store.putObject(key: "originals/" + String(repeating: "A", count: 100), body: Data("safe".utf8))
        }
        #expect(try await store.listObjects(prefix: "originals/").isEmpty)
    }

    @Test func explicitInitializationCanRebindTheSameVolumeAfterRename() async throws {
        let root = try directory()
        let moved = root.appendingPathExtension("new-mount-name")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
        }
        let original = try FilesystemDestination.initialize(at: root)
        try FileManager.default.moveItem(at: root, to: moved)
        #expect(throws: FilesystemError.self) { try FilesystemObjectStore(destination: original) }
        let rebound = try FilesystemDestination.initialize(at: moved)
        #expect(rebound.targetID == original.targetID)
        #expect(rebound.path == moved.path)
        let store = try FilesystemObjectStore(destination: rebound)
        try await store.putObject(key: "manifest.json", body: Manifest().encoded())
        #expect(try await store.headObject(key: "manifest.json") != nil)
    }

    @Test func rootRemovedAfterOpenCannotRedirectWrites() async throws {
        let root = try directory()
        let removed = root.appendingPathExtension("removed")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: removed)
        }
        let destination = try FilesystemDestination.initialize(at: root)
        let store = try FilesystemObjectStore(destination: destination)
        try FileManager.default.moveItem(at: root, to: removed)
        await #expect(throws: FilesystemError.self) { try await store.putObject(key: "manifest.json", body: Data()) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(throws: FilesystemError.self) { try FilesystemObjectStore(destination: destination) }
    }
}
