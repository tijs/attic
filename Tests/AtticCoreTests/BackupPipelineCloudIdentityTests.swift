@testable import AtticCore
import Foundation
import LadderKit
import Testing

/// Post-migration regression suite: `AssetInfo.uuid` resolves to a
/// `PHCloudIdentifier` once the v1→v2 migration has run, but PhotoKit and
/// the AppleScript fallback can only fetch by the device-local UUID
/// prefix. The pipeline must feed local UUIDs to the exporter and translate
/// every `ExportResult` / `ExportError` back to the cloud UUID before it
/// reaches the manifest, retry queue, or error report.
@Suite("BackupPipeline — cloud identity")
struct BackupPipelineCloudIdentityTests {
    private static func cloudAsset(
        local: String,
        cloud: String?,
        file: String,
    ) -> AssetInfo {
        AssetInfo(
            identifier: "\(local)/L0/001",
            cloudIdentifier: cloud,
            creationDate: ISO8601DateFormatter().date(from: "2024-01-15T12:00:00Z"),
            kind: .photo,
            pixelWidth: 4032,
            pixelHeight: 3024,
            latitude: nil,
            longitude: nil,
            isFavorite: false,
            originalFilename: file,
            uniformTypeIdentifier: "public.heic",
        )
    }

    @Test func exportsByLocalUUIDAndManifestsByCloudUUID() async throws {
        let cloudA = "BD3A2240-E5E5-4F8C-8472-EEA07B7D1384:001:ATmPkw4w"
        let cloudB = "46D1C84B-C5D9-4F15-9705-54A83F90685C:001:AYB5xtyCkdkw2fwEZO7RXKieNT"
        let localA = "BD3A2240-E5E5-4F8C-8472-EEA07B7D1384"
        let localB = "46D1C84B-C5D9-4F15-9705-54A83F90685C"

        let assetA = Self.cloudAsset(local: localA, cloud: cloudA, file: "IMG_A.HEIC")
        let assetB = Self.cloudAsset(local: localB, cloud: cloudB, file: "IMG_B.HEIC")

        // MockExportProvider only knows the LOCAL UUIDs — proves the pipeline
        // is feeding the exporter local UUIDs, not cloud IDs.
        let exporter = MockExportProvider(assets: [
            localA: ("IMG_A.HEIC", Data("photoA".utf8)),
            localB: ("IMG_B.HEIC", Data("photoB".utf8)),
        ])
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        let report = try await runBackup(
            assets: [assetA, assetB],
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10),
        )

        #expect(report.uploaded == 2)
        #expect(report.failed == 0)
        #expect(report.errors.isEmpty)
        #expect(manifest.isBackedUp(cloudA))
        #expect(manifest.isBackedUp(cloudB))
        #expect(!manifest.isBackedUp(localA))
        #expect(!manifest.isBackedUp(localB))
    }

    @Test func deferredRetryPreservesCloudUUID() async throws {
        // The deferred-retry loop translates cloud → local for the exporter
        // and back to cloud for the manifest. A timeout-then-success flow
        // forces one asset through the batch-fallback per-asset retry,
        // marking it `deferred` (cloud-keyed), then re-runs it after all
        // batches.
        let cloudA = "BD3A2240-E5E5-4F8C-8472-EEA07B7D1384:001:ATmPkw4w"
        let cloudB = "46D1C84B-C5D9-4F15-9705-54A83F90685C:001:AYB5xtyCkdkw2fwEZO7RXKieNT"
        let localA = "BD3A2240-E5E5-4F8C-8472-EEA07B7D1384"
        let localB = "46D1C84B-C5D9-4F15-9705-54A83F90685C"

        let inner = MockExportProvider(assets: [
            localA: ("IMG_A.HEIC", Data("a".utf8)),
            localB: ("IMG_B.HEIC", Data("b".utf8)),
        ])
        // TimeoutExportProvider keys slowUUIDs by what the pipeline passes
        // to the exporter — that's the LOCAL uuid post-fix.
        let exporter = TimeoutExportProvider(inner: inner, slowUUIDs: [localA])

        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        let report = try await runBackup(
            assets: [
                Self.cloudAsset(local: localA, cloud: cloudA, file: "IMG_A.HEIC"),
                Self.cloudAsset(local: localB, cloud: cloudB, file: "IMG_B.HEIC"),
            ],
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10),
        )

        #expect(report.uploaded == 2)
        #expect(report.failed == 0)
        #expect(manifest.isBackedUp(cloudA))
        #expect(manifest.isBackedUp(cloudB))
        #expect(!manifest.isBackedUp(localA))
        #expect(!manifest.isBackedUp(localB))
    }

    @Test func mixedCloudAndLocalFallbackBatch() async throws {
        // Pre/post-migration coexistence: one asset has resolved a cloud
        // identifier, the other has not (PhotoKit returned no mapping).
        // Both export by their local UUID, but the cloud-keyed one writes
        // to manifest under the cloud UUID and the local-fallback one
        // writes under the local UUID prefix.
        let cloudA = "BD3A2240-E5E5-4F8C-8472-EEA07B7D1384:001:ATmPkw4w"
        let localA = "BD3A2240-E5E5-4F8C-8472-EEA07B7D1384"
        let bareLocal = "00000000-0000-4000-8000-000000000001"

        let cloudAsset = Self.cloudAsset(local: localA, cloud: cloudA, file: "IMG_A.HEIC")
        let localOnlyAsset = Self.cloudAsset(local: bareLocal, cloud: nil, file: "IMG_B.HEIC")

        let exporter = MockExportProvider(assets: [
            localA: ("IMG_A.HEIC", Data("a".utf8)),
            bareLocal: ("IMG_B.HEIC", Data("b".utf8)),
        ])
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        let report = try await runBackup(
            assets: [cloudAsset, localOnlyAsset],
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10),
        )

        #expect(report.uploaded == 2)
        #expect(manifest.isBackedUp(cloudA))
        #expect(manifest.isBackedUp(bareLocal))
        #expect(!manifest.isBackedUp(localA))
    }

    @Test func surfacesExportErrorByCloudUUID() async throws {
        // When the exporter fails for an asset, the error reported back to
        // the user (and persisted to the retry queue) must use the cloud
        // UUID, not the PhotoKit local UUID the exporter was actually
        // invoked with.
        let cloudA = "BD3A2240-E5E5-4F8C-8472-EEA07B7D1384:001:ATmPkw4w"
        let localA = "BD3A2240-E5E5-4F8C-8472-EEA07B7D1384"
        let asset = Self.cloudAsset(local: localA, cloud: cloudA, file: "IMG_A.HEIC")

        // Empty asset map → exporter returns an ExportError keyed by
        // whatever UUID the pipeline passes in. We expect the pipeline to
        // translate that local UUID back to the cloud UUID.
        let exporter = MockExportProvider(assets: [:])
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        let report = try await runBackup(
            assets: [asset],
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10),
        )

        #expect(report.uploaded == 0)
        #expect(report.failed == 1)
        #expect(report.errors.count == 1)
        #expect(report.errors.first?.uuid == cloudA)
    }
}
