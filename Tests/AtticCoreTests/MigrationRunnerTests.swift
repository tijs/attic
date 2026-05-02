@testable import AtticCore
import Foundation
import LadderKit
import Testing

@Suite("MigrationRunner")
struct MigrationRunnerTests {
    private actor MockResolver: CloudIdentityResolving {
        private var mappings: [String: CloudMappingResult]
        private(set) var calls: Int = 0

        init(_ mappings: [String: CloudMappingResult]) {
            self.mappings = mappings
        }

        nonisolated func resolve(localIdentifiers: [String]) async -> [String: CloudMappingResult] {
            await tick()
            return await read(localIdentifiers)
        }

        private func tick() { calls += 1 }
        private func read(_ ids: [String]) -> [String: CloudMappingResult] {
            var out: [String: CloudMappingResult] = [:]
            for id in ids { out[id] = mappings[id] ?? .notFound }
            return out
        }
    }

    private final class InMemoryRetryStore: RetryQueueProviding, @unchecked Sendable {
        var queue: RetryQueue?
        func load() -> RetryQueue? { queue }
        func save(_ q: RetryQueue) throws { queue = q }
        func clear() throws { queue = nil }
    }

    private final class InMemoryUnavailableStore: UnavailableAssetStoring, @unchecked Sendable {
        var assets: UnavailableAssets = .init()
        func load() -> UnavailableAssets { assets }
        func save(_ a: UnavailableAssets) throws { assets = a }
    }

    private func v1ManifestData(entries: [(uuid: String, key: String)]) throws -> Data {
        var dict: [String: ManifestEntry] = [:]
        for e in entries {
            dict[e.uuid] = ManifestEntry(
                uuid: e.uuid,
                s3Key: e.key,
                checksum: "sha256:\(e.uuid)",
                backedUpAt: "2024-01-01T00:00:00Z",
            )
        }
        let manifest = Manifest(version: 1, entries: dict)
        return try manifest.encoded()
    }

    private func metadataJSON(uuid: String, s3Key: String) -> Data {
        let json = """
        {
            "uuid": "\(uuid)",
            "originalFilename": "IMG.HEIC",
            "width": 1, "height": 1,
            "favorite": false, "hasEdit": false,
            "albums": [], "keywords": [], "people": [],
            "s3Key": "\(s3Key)",
            "checksum": "sha256:\(uuid)",
            "backedUpAt": "2024-01-01T00:00:00Z"
        }
        """
        return Data(json.utf8)
    }

    private func makeRunner(
        s3: MockS3Provider,
        resolver: MockResolver,
        library: [(bareUUID: String, fullLocalIdentifier: String)],
        retryStore: InMemoryRetryStore = InMemoryRetryStore(),
        unavailableStore: InMemoryUnavailableStore = InMemoryUnavailableStore(),
    ) -> MigrationRunner {
        MigrationRunner(
            s3: s3,
            manifestStore: S3ManifestStore(s3: s3),
            resolver: resolver,
            assetIdentifierProvider: { library },
            retryStore: retryStore,
            unavailableStore: unavailableStore,
        )
    }

    @Test func migratesAllMappableEntriesEndToEnd() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: try v1ManifestData(entries: [
                ("A", "originals/2024/01/A.heic"),
                ("B", "originals/2024/01/B.heic"),
            ]),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/A.json",
            body: metadataJSON(uuid: "A", s3Key: "originals/2024/01/A.heic"),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/B.json",
            body: metadataJSON(uuid: "B", s3Key: "originals/2024/01/B.heic"),
            contentType: "application/json",
        )

        let resolver = MockResolver([
            "A/L0/001": .cloud("CLOUD-A"),
            "B/L0/001": .cloud("CLOUD-B"),
        ])
        let runner = makeRunner(
            s3: s3,
            resolver: resolver,
            library: [
                (bareUUID: "A", fullLocalIdentifier: "A/L0/001"),
                (bareUUID: "B", fullLocalIdentifier: "B/L0/001"),
            ],
        )

        let report = try await runner.run()

        #expect(report.alreadyMigrated == false)
        #expect(report.cloudMigrated == 2)
        #expect(report.metadataRewritten == 2)
        #expect(report.totalEntries == 2)

        // Manifest swapped to v2
        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.version == 2)
        #expect(manifest.entries["CLOUD-A"]?.identityKind == .cloud)
        #expect(manifest.entries["CLOUD-A"]?.legacyLocalIdentifier == "A")
        #expect(manifest.entries["A"] == nil)

        // v1 backup persisted
        let backupExists = try await s3.headObject(key: manifestV1BackupS3Key) != nil
        #expect(backupExists)

        // staging key cleaned up
        let stagingExists = try await s3.headObject(key: manifestV2StagingS3Key) != nil
        #expect(!stagingExists)

        // metadata keys re-keyed
        let newMetaA = try await s3.getObject(key: "metadata/assets/CLOUD-A.json")
        let parsedA = try JSONDecoder().decode(AssetMetadata.self, from: newMetaA)
        #expect(parsedA.uuid == "CLOUD-A")
        #expect(parsedA.legacyLocalIdentifier == "A")
        #expect(parsedA.identityKind == .cloud)
        let oldMetaExists = try await s3.headObject(key: "metadata/assets/A.json") != nil
        #expect(!oldMetaExists)
    }

    @Test func noOpOnAlreadyV2Manifest() async throws {
        let s3 = MockS3Provider()
        var v2 = Manifest()
        v2.markBackedUp(
            uuid: "CLOUD-X",
            s3Key: "originals/2024/01/x.heic",
            checksum: "sha256:x",
            backedUpAt: "2024-01-01T00:00:00Z",
            identityKind: .cloud,
        )
        try await s3.putObject(
            key: manifestS3Key,
            body: try v2.encoded(),
            contentType: "application/json",
        )

        let resolver = MockResolver([:])
        let runner = makeRunner(s3: s3, resolver: resolver, library: [])
        let report = try await runner.run()

        #expect(report.alreadyMigrated)
        #expect(report.cloudMigrated == 0)
        #expect(report.totalEntries == 1)
    }

    @Test func dryRunDoesNotMutateS3() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: try v1ManifestData(entries: [("A", "originals/2024/01/A.heic")]),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/A.json",
            body: metadataJSON(uuid: "A", s3Key: "originals/2024/01/A.heic"),
        )

        let resolver = MockResolver(["A/L0/001": .cloud("CLOUD-A")])
        let runner = makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")],
        )

        let report = try await runner.run(dryRun: true)

        #expect(report.cloudMigrated == 1)
        #expect(report.metadataRewritten == 0)

        // Manifest unchanged
        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.isV1)
        #expect(manifest.entries["A"] != nil)

        // No staging or backup written
        let stagingExists = try await s3.headObject(key: manifestV2StagingS3Key) != nil
        let backupExists = try await s3.headObject(key: manifestV1BackupS3Key) != nil
        #expect(!stagingExists)
        #expect(!backupExists)
    }

    @Test func partialMetadataRewriteResumes() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: try v1ManifestData(entries: [
                ("A", "originals/2024/01/A.heic"),
                ("B", "originals/2024/01/B.heic"),
            ]),
            contentType: "application/json",
        )
        // Simulate prior partial run: metadata for A already migrated, B not yet.
        try await s3.putObject(
            key: "metadata/assets/CLOUD-A.json",
            body: metadataJSON(uuid: "CLOUD-A", s3Key: "originals/2024/01/A.heic"),
        )
        try await s3.putObject(
            key: "metadata/assets/B.json",
            body: metadataJSON(uuid: "B", s3Key: "originals/2024/01/B.heic"),
        )

        let resolver = MockResolver([
            "A/L0/001": .cloud("CLOUD-A"),
            "B/L0/001": .cloud("CLOUD-B"),
        ])
        let runner = makeRunner(
            s3: s3,
            resolver: resolver,
            library: [
                (bareUUID: "A", fullLocalIdentifier: "A/L0/001"),
                (bareUUID: "B", fullLocalIdentifier: "B/L0/001"),
            ],
        )

        let report = try await runner.run()

        // Only B's metadata gets newly rewritten this run; A skipped because dest exists.
        #expect(report.metadataRewritten == 1)
        #expect(report.cloudMigrated == 2)

        let bExists = try await s3.headObject(key: "metadata/assets/CLOUD-B.json") != nil
        #expect(bExists)
    }

    @Test func missingMetadataIsSoftSkipped() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: try v1ManifestData(entries: [("A", "originals/2024/01/A.heic")]),
            contentType: "application/json",
        )
        // No metadata JSON uploaded.
        let resolver = MockResolver(["A/L0/001": .cloud("CLOUD-A")])
        let runner = makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")],
        )

        let report = try await runner.run()

        #expect(report.cloudMigrated == 1)
        #expect(report.metadataRewritten == 0)
        #expect(report.metadataMissing == 1)

        // Manifest still swapped to v2
        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(!manifest.isV1)
    }

    @Test func migratesLocalRetryQueueAndUnavailableStore() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: try v1ManifestData(entries: [("A", "originals/2024/01/A.heic")]),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/A.json",
            body: metadataJSON(uuid: "A", s3Key: "originals/2024/01/A.heic"),
        )

        let retryStore = InMemoryRetryStore()
        retryStore.queue = RetryQueue(
            entries: [RetryEntry(
                uuid: "A",
                attempts: 2,
                firstFailedAt: "2024-01-01",
                lastFailedAt: "2024-01-05",
            )],
            updatedAt: "2024-01-05",
        )
        let unavailableStore = InMemoryUnavailableStore()
        unavailableStore.assets.entries["A"] = UnavailableAsset(
            uuid: "A",
            filename: "shared.mov",
            reason: "unreachable",
            firstFailedAt: "2024-01-01",
            lastAttemptedAt: "2024-01-05",
            attempts: 1,
        )

        let resolver = MockResolver(["A/L0/001": .cloud("CLOUD-A")])
        let runner = makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")],
            retryStore: retryStore,
            unavailableStore: unavailableStore,
        )

        _ = try await runner.run()

        #expect(retryStore.queue?.entries.first?.uuid == "CLOUD-A")
        #expect(retryStore.queue?.entries.first?.legacyLocalIdentifier == "A")
        #expect(unavailableStore.assets.entries["CLOUD-A"]?.legacyLocalIdentifier == "A")
        #expect(unavailableStore.assets.entries["A"] == nil)
    }

    @Test func unmappedAssetsRemainAsLocal() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: try v1ManifestData(entries: [
                ("A", "originals/2024/01/A.heic"),
                ("DELETED", "originals/2024/01/DELETED.heic"),
            ]),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/A.json",
            body: metadataJSON(uuid: "A", s3Key: "originals/2024/01/A.heic"),
        )

        let resolver = MockResolver(["A/L0/001": .cloud("CLOUD-A")])
        // DELETED is not in library at all (asset was removed).
        let runner = makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")],
        )

        let report = try await runner.run()

        #expect(report.cloudMigrated == 1)
        #expect(report.unmapped == ["DELETED"])
        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.entries["DELETED"]?.identityKind == .local)
    }
}
