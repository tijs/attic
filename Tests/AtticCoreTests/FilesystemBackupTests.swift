@testable import AtticCore
import CryptoKit
import Foundation
import LadderKit
import Testing

private struct FilesystemFixtureExporter: ExportProviding {
    let directory: URL
    var corruptChecksum = false

    func checkPermissions() async throws {}

    func exportBatch(uuids: [String]) async throws -> ExportResponse {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let results = try uuids.map { uuid in
            let data = Data("original bytes for \(uuid)".utf8)
            let file = directory.appendingPathComponent("\(uuid).heic")
            try data.write(to: file)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return ExportResult(
                uuid: uuid, path: file.path, size: Int64(data.count),
                sha256: corruptChecksum ? String(repeating: "0", count: 64) : hash,
            )
        }
        return ExportResponse(results: results, errors: [])
    }
}

struct FilesystemBackupTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attic-backup-fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    @Test func backupRepeatedRunVerifyMetadataRefreshAndRebuildRoundTrip() async throws {
        let root = try directory()
        let staging = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        let destination = try FilesystemDestination.initialize(at: root)
        let objects = try FilesystemObjectStore(destination: destination)
        let store = ObjectManifestStore(s3: objects, allowsLegacyLocalMigration: false)
        var manifest = try await store.load()
        let assets = [
            makeTestAsset(uuid: "A", filename: "same.heic").withResolvedCloudIdentity(.cloud("cloud/id+one=")),
            makeTestAsset(uuid: "B", filename: "same.heic").withResolvedCloudIdentity(.cloud("cloud/id+two=")),
        ]
        let exporter = FilesystemFixtureExporter(directory: staging)
        let report = try await runBackup(
            assets: assets, manifest: &manifest, manifestStore: store,
            exporter: exporter, s3: objects,
        )
        #expect(report.uploaded == 2)
        #expect(report.failed == 0)
        #expect(report.totalBytes == 40)
        #expect(manifest.entries.count == 2)
        #expect(manifest.entries.values.allSatisfy { $0.identityKind == .cloud })
        #expect(manifest.entries["cloud/id+one="]?.legacyLocalIdentifier == "A")
        let repeatReport = try await runBackup(
            assets: assets, manifest: &manifest, manifestStore: store,
            exporter: exporter, s3: objects,
        )
        #expect(repeatReport.uploaded == 0)
        #expect(try await runVerify(manifest: manifest, s3: objects).ok == 2)
        for entry in manifest.entries.values {
            let reader = try #require(try objects.reader(key: entry.s3Key))
            defer { try? reader.close() }
            let digest = try SafeDirectory.digest(reader)
            #expect(entry.checksum == "sha256:\(digest.checksum)")
            #expect(entry.size == Int(digest.size))
        }
        let stats = StatusStats.computeBackupStats(assets: assets, manifest: manifest)
        #expect(stats.backedUp == 2)
        #expect(stats.pending == 0)
        #expect(stats.backedUpBytes == 40)
        let refresh = try await runRefreshMetadata(assets: assets, manifest: manifest, s3: objects)
        #expect(refresh.updated == 2)
        let (rebuilt, rebuiltReport) = try await runRebuildManifest(s3: objects, manifestStore: store)
        #expect(rebuiltReport.recovered == 2)
        #expect(rebuiltReport.errors.isEmpty)
        #expect(rebuilt.entries.values.allSatisfy { $0.identityKind == .cloud })
        #expect(rebuilt.entries.values.allSatisfy { $0.size == 20 })
        #expect(Set(rebuilt.entries.values.map(\.s3Key)).count == 2)
        let metadata = try await JSONDecoder().decode(
            AssetMetadata.self,
            from: objects.getObject(key: S3Paths.metadataKey(uuid: "cloud/id+one=")),
        )
        #expect(metadata.uuid == "cloud/id+one=")
        #expect(metadata.originalFilename == "same.heic")
        #expect(metadata.fileSize == 20)
    }

    @Test func badExportChecksumCannotBecomeDurableManifestEntry() async throws {
        let root = try directory()
        let staging = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        let objects = try FilesystemObjectStore(destination: FilesystemDestination.initialize(at: root))
        let store = ObjectManifestStore(s3: objects, allowsLegacyLocalMigration: false)
        var manifest = try await store.load()
        let report = try await runBackup(
            assets: [makeTestAsset(uuid: "A")], manifest: &manifest, manifestStore: store,
            exporter: FilesystemFixtureExporter(directory: staging, corruptChecksum: true), s3: objects,
        )
        #expect(report.uploaded == 0)
        #expect(report.failed == 1)
        #expect(manifest.entries.isEmpty)
        #expect(try await store.load().entries.isEmpty)
        #expect(try await objects.listObjects(prefix: "originals/").isEmpty)
    }
}
