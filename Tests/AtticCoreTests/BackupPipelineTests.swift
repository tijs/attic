@testable import AtticCore
import Foundation
import LadderKit
import Testing

// MARK: - Test helpers

/// Mock exporter that returns pre-configured results from an in-memory map.
struct MockExportProvider: ExportProviding {
    /// Map of UUID → (filename, data). UUIDs not in the map produce errors.
    let availableAssets: [String: (filename: String, data: Data)]
    let stagingDir: URL

    init(
        assets: [String: (filename: String, data: Data)] = [:],
        stagingDir: URL? = nil,
    ) {
        availableAssets = assets
        self.stagingDir = stagingDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-test-staging-\(UUID().uuidString)")
    }

    func exportBatch(uuids: [String]) async throws -> ExportResponse {
        let fm = FileManager.default
        if !fm.fileExists(atPath: stagingDir.path) {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        }

        var results: [ExportResult] = []
        var errors: [LadderKit.ExportError] = []

        for uuid in uuids {
            if let asset = availableAssets[uuid] {
                let filePath = stagingDir.appendingPathComponent(asset.filename)
                try asset.data.write(to: filePath)
                results.append(ExportResult(
                    uuid: uuid,
                    path: filePath.path,
                    size: Int64(asset.data.count),
                    sha256: "fakehash_\(uuid)",
                ))
            } else {
                errors.append(LadderKit.ExportError(
                    uuid: uuid,
                    message: "Asset not found in mock library",
                ))
            }
        }

        return ExportResponse(results: results, errors: errors)
    }

    func checkPermissions() async throws {}
}

/// Mock exporter that throws timeout on batches containing specific UUIDs.
struct TimeoutExportProvider: ExportProviding {
    let inner: MockExportProvider
    let slowUUIDs: Set<String>
    private let retryCounter = RetryCounter()

    actor RetryCounter {
        var counts: [String: Int] = [:]
        func increment(_ uuid: String) -> Int {
            counts[uuid, default: 0] += 1
            return counts[uuid]!
        }
    }

    func exportBatch(uuids: [String]) async throws -> ExportResponse {
        let containsSlow = uuids.contains { slowUUIDs.contains($0) }

        if containsSlow, uuids.count > 1 {
            throw ExportProviderError.timeout(seconds: 300)
        }

        if uuids.count == 1, let uuid = uuids.first, slowUUIDs.contains(uuid) {
            let count = await retryCounter.increment(uuid)
            if count == 1 {
                throw ExportProviderError.timeout(seconds: 300)
            }
        }

        return try await inner.exportBatch(uuids: uuids)
    }

    func checkPermissions() async throws {}
}

func makeTestAsset(
    uuid: String,
    kind: AssetKind = .photo,
    filename: String = "IMG_0001.HEIC",
    uti: String = "public.heic",
) -> AssetInfo {
    AssetInfo(
        identifier: "\(uuid)/L0/001",
        creationDate: ISO8601DateFormatter().date(from: "2024-01-15T12:00:00Z"),
        kind: kind,
        pixelWidth: 4032,
        pixelHeight: 3024,
        latitude: 52.09,
        longitude: 4.34,
        isFavorite: false,
        originalFilename: filename,
        uniformTypeIdentifier: uti,
        hasEdit: false,
    )
}

func createTestContext() async throws -> (MockS3Provider, S3ManifestStore) {
    let s3 = MockS3Provider()
    let store = S3ManifestStore(s3: s3)
    return (s3, store)
}

// MARK: - Tests

struct BackupPipelineTests {
    @Test func uploadsPendingAssetsAndUpdatesManifest() async throws {
        let assets = [makeTestAsset(uuid: "uuid-1"), makeTestAsset(uuid: "uuid-2")]

        let exporter = MockExportProvider(assets: [
            "uuid-1": ("IMG_0001.HEIC", Data("photo1".utf8)),
            "uuid-2": ("IMG_0002.HEIC", Data("photo2".utf8)),
        ])
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10),
        )

        #expect(report.uploaded == 2)
        #expect(report.failed == 0)
        #expect(report.errors.isEmpty)
        #expect(manifest.isBackedUp("uuid-1"))
        #expect(manifest.isBackedUp("uuid-2"))

        // S3 should have originals + metadata + manifest
        let manifestExists = try await s3.headObject(key: "manifest.json")
        #expect(manifestExists != nil)
    }

    @Test func skipsAlreadyBackedUpAssets() async throws {
        let assets = [makeTestAsset(uuid: "uuid-1"), makeTestAsset(uuid: "uuid-2")]

        let exporter = MockExportProvider(assets: [
            "uuid-2": ("IMG_0002.HEIC", Data("photo2".utf8)),
        ])
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        // Pre-mark uuid-1 as backed up
        manifest.markBackedUp(
            uuid: "uuid-1",
            s3Key: "originals/2024/01/uuid-1.heic",
            checksum: "sha256:abc",
            backedUpAt: "2024-01-15T00:00:00Z",
        )

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10),
        )

        #expect(report.uploaded == 1)
        #expect(report.failed == 0)
    }

    @Test func respectsLimitFlag() async throws {
        let assets = [
            makeTestAsset(uuid: "uuid-1"),
            makeTestAsset(uuid: "uuid-2"),
            makeTestAsset(uuid: "uuid-3"),
        ]

        let exporter = MockExportProvider(assets: [
            "uuid-1": ("IMG_0001.HEIC", Data("p1".utf8)),
        ])
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10, limit: 1),
        )

        #expect(report.uploaded == 1)
    }

    @Test func dryRunSkipsUploads() async throws {
        let assets = [makeTestAsset(uuid: "uuid-1")]

        let exporter = MockExportProvider()
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(dryRun: true),
        )

        #expect(report.uploaded == 0)
        #expect(report.skipped == 1)
        let objects = try await s3.listObjects(prefix: "")
        #expect(objects.isEmpty)
        #expect(!manifest.isBackedUp("uuid-1"))
    }

    @Test func handlesExportErrorsGracefully() async throws {
        let assets = [
            makeTestAsset(uuid: "uuid-1"),
            makeTestAsset(uuid: "uuid-missing"),
        ]

        let exporter = MockExportProvider(assets: [
            "uuid-1": ("IMG_0001.HEIC", Data("data".utf8)),
        ])
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10),
        )

        #expect(report.uploaded == 1)
        #expect(report.failed == 1)
        #expect(report.errors.count == 1)
        #expect(report.errors[0].uuid == "uuid-missing")
    }

    @Test func filtersByType() async throws {
        let assets = [
            makeTestAsset(uuid: "photo-1", kind: .photo),
            makeTestAsset(
                uuid: "video-1",
                kind: .video,
                filename: "VID.MOV",
                uti: "com.apple.quicktime-movie",
            ),
        ]

        let exporter = MockExportProvider(assets: [
            "video-1": ("VID.MOV", Data("video".utf8)),
        ])
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10, type: .video),
        )

        #expect(report.uploaded == 1)
        #expect(manifest.isBackedUp("video-1"))
        #expect(!manifest.isBackedUp("photo-1"))
    }

    @Test func defersTimedOutAssetsAndRetriesAfterBatches() async throws {
        let assets = [
            makeTestAsset(uuid: "fast-1"),
            makeTestAsset(uuid: "slow-1"),
            makeTestAsset(uuid: "fast-2"),
        ]

        let inner = MockExportProvider(assets: [
            "fast-1": ("IMG_0001.HEIC", Data("f1".utf8)),
            "slow-1": ("BIG_VIDEO.MOV", Data("s1".utf8)),
            "fast-2": ("IMG_0003.HEIC", Data("f2".utf8)),
        ])
        let exporter = TimeoutExportProvider(
            inner: inner,
            slowUUIDs: ["slow-1"],
        )
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 3),
        )

        #expect(report.uploaded == 3)
        #expect(report.failed == 0)
        #expect(manifest.isBackedUp("fast-1"))
        #expect(manifest.isBackedUp("fast-2"))
        #expect(manifest.isBackedUp("slow-1"))
    }

    @Test func concurrentUploadsAllAppearInManifest() async throws {
        // Create enough assets to exercise concurrency (more than default 6)
        let count = 12
        var assets: [AssetInfo] = []
        var exportMap: [String: (filename: String, data: Data)] = [:]
        for i in 1 ... count {
            let uuid = "concurrent-\(i)"
            assets.append(makeTestAsset(uuid: uuid))
            exportMap[uuid] = ("IMG_\(i).HEIC", Data("photo\(i)".utf8))
        }

        let exporter = MockExportProvider(assets: exportMap)
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 12, concurrency: 4),
        )

        #expect(report.uploaded == count)
        #expect(report.failed == 0)
        for i in 1 ... count {
            #expect(manifest.isBackedUp("concurrent-\(i)"))
        }
    }

    @Test func concurrentMixedSuccessAndFailure() async throws {
        let assets = [
            makeTestAsset(uuid: "ok-1"),
            makeTestAsset(uuid: "ok-2"),
            makeTestAsset(uuid: "missing-1"),
            makeTestAsset(uuid: "ok-3"),
            makeTestAsset(uuid: "missing-2"),
        ]

        let exporter = MockExportProvider(assets: [
            "ok-1": ("IMG_1.HEIC", Data("p1".utf8)),
            "ok-2": ("IMG_2.HEIC", Data("p2".utf8)),
            "ok-3": ("IMG_3.HEIC", Data("p3".utf8)),
        ])
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10, concurrency: 3),
        )

        #expect(report.uploaded == 3)
        #expect(report.failed == 2)
        #expect(manifest.isBackedUp("ok-1"))
        #expect(manifest.isBackedUp("ok-2"))
        #expect(manifest.isBackedUp("ok-3"))
        #expect(!manifest.isBackedUp("missing-1"))
        #expect(!manifest.isBackedUp("missing-2"))
    }

    @Test func concurrencyOneWorksLikeSequential() async throws {
        let assets = [
            makeTestAsset(uuid: "seq-1"),
            makeTestAsset(uuid: "seq-2"),
            makeTestAsset(uuid: "seq-3"),
        ]

        let exporter = MockExportProvider(assets: [
            "seq-1": ("IMG_1.HEIC", Data("p1".utf8)),
            "seq-2": ("IMG_2.HEIC", Data("p2".utf8)),
            "seq-3": ("IMG_3.HEIC", Data("p3".utf8)),
        ])
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10, concurrency: 1),
        )

        #expect(report.uploaded == 3)
        #expect(report.failed == 0)
        #expect(manifest.isBackedUp("seq-1"))
        #expect(manifest.isBackedUp("seq-2"))
        #expect(manifest.isBackedUp("seq-3"))
    }

    @Test func savesManifestToS3() async throws {
        let assets = [makeTestAsset(uuid: "uuid-1")]

        let exporter = MockExportProvider(assets: [
            "uuid-1": ("IMG_0001.HEIC", Data("data".utf8)),
        ])
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        _ = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10),
        )

        // Load from S3 — should persist
        let loaded = try await manifestStore.load()
        #expect(loaded.isBackedUp("uuid-1"))
    }

    @Test func recordsUnavailableErrorsAndSkipsThemNextRun() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unavailable-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let exporter = UnavailableMarkingExporter(
            unavailableUUIDs: ["shared-1"],
            availableAssets: ["ok-1": ("a.jpg", Data("a".utf8))],
        )
        let store = FileUnavailableAssetStore(directory: tempDir)
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        let assets = [makeTestAsset(uuid: "shared-1"), makeTestAsset(uuid: "ok-1")]
        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10),
            unavailableStore: store,
        )

        #expect(report.uploaded == 1)
        #expect(report.failed == 1)
        #expect(store.load().contains("shared-1"))

        // Second run with the same assets should not re-attempt the unavailable one.
        let report2 = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10),
            unavailableStore: store,
        )
        #expect(report2.uploaded == 0)
        #expect(report2.failed == 0)
    }
}

/// Exporter that marks configured UUIDs as `unavailable` errors.
struct UnavailableMarkingExporter: ExportProviding {
    let unavailableUUIDs: Set<String>
    let availableAssets: [String: (filename: String, data: Data)]
    let stagingDir: URL

    init(
        unavailableUUIDs: Set<String>,
        availableAssets: [String: (filename: String, data: Data)],
    ) {
        self.unavailableUUIDs = unavailableUUIDs
        self.availableAssets = availableAssets
        stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unav-exporter-\(UUID().uuidString)")
    }

    func exportBatch(uuids: [String]) async throws -> ExportResponse {
        let fm = FileManager.default
        if !fm.fileExists(atPath: stagingDir.path) {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        }
        var results: [ExportResult] = []
        var errors: [LadderKit.ExportError] = []
        for uuid in uuids {
            if unavailableUUIDs.contains(uuid) {
                errors.append(LadderKit.ExportError(
                    uuid: uuid,
                    message: "Shared-album asset unavailable",
                    unavailable: true,
                ))
            } else if let asset = availableAssets[uuid] {
                let path = stagingDir.appendingPathComponent(asset.filename)
                try asset.data.write(to: path)
                results.append(ExportResult(
                    uuid: uuid, path: path.path,
                    size: Int64(asset.data.count), sha256: "fake_\(uuid)",
                ))
            } else {
                errors.append(LadderKit.ExportError(uuid: uuid, message: "missing"))
            }
        }
        return ExportResponse(results: results, errors: errors)
    }

    func checkPermissions() async throws {}
}
