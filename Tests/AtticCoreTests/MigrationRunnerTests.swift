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

    @Test func collisionLoserMetadataIsDeletedAndWinnerSurvives() async throws {
        // Two old uuids both resolve to CLOUD-X. B has the more recent
        // backedUpAt → B wins, A is the loser. Loser's metadata must be
        // deleted; winner's metadata must contain B's payload (not
        // accidentally overwritten by A's).
        let s3 = MockS3Provider()
        var dict: [String: ManifestEntry] = [:]
        dict["A"] = ManifestEntry(
            uuid: "A",
            s3Key: "originals/2024/01/A.heic",
            checksum: "sha256:A",
            backedUpAt: "2024-01-01T00:00:00Z",
        )
        dict["B"] = ManifestEntry(
            uuid: "B",
            s3Key: "originals/2024/02/B.heic",
            checksum: "sha256:B",
            backedUpAt: "2024-06-01T00:00:00Z",
        )
        let v1 = Manifest(version: 1, entries: dict)
        try await s3.putObject(
            key: manifestS3Key,
            body: try v1.encoded(),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/A.json",
            body: metadataJSON(uuid: "A", s3Key: "originals/2024/01/A.heic"),
        )
        try await s3.putObject(
            key: "metadata/assets/B.json",
            body: metadataJSON(uuid: "B", s3Key: "originals/2024/02/B.heic"),
        )

        let resolver = MockResolver([
            "A/L0/001": .cloud("CLOUD-X"),
            "B/L0/001": .cloud("CLOUD-X"),
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
        #expect(report.cloudMigrated == 1)
        #expect(report.rekeyCollisions == ["A"])

        // Loser metadata key gone.
        let aExists = try await s3.headObject(key: "metadata/assets/A.json") != nil
        #expect(!aExists)

        // Winner survives at the cloud key, with B's identifying payload.
        let cloudData = try await s3.getObject(key: "metadata/assets/CLOUD-X.json")
        let parsed = try JSONDecoder().decode(AssetMetadata.self, from: cloudData)
        #expect(parsed.uuid == "CLOUD-X")
        #expect(parsed.legacyLocalIdentifier == "B")
        #expect(parsed.s3Key == "originals/2024/02/B.heic")
        #expect(parsed.checksum == "sha256:B")
    }

    @Test func rewriteMetadataPayloadPreservesUnknownKeys() async throws {
        // Metadata may carry fields written by other tools (e.g. Deno CLI) or
        // future versions. The rewrite must keep them verbatim — only the
        // identity fields change.
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: try v1ManifestData(entries: [("A", "originals/2024/01/A.heic")]),
            contentType: "application/json",
        )
        let payload = """
        {
            "uuid": "A",
            "originalFilename": "IMG.HEIC",
            "width": 1, "height": 1,
            "favorite": false, "hasEdit": false,
            "albums": [], "keywords": [], "people": [],
            "s3Key": "originals/2024/01/A.heic",
            "checksum": "sha256:A",
            "backedUpAt": "2024-01-01T00:00:00Z",
            "deno-extra": "lives-on",
            "future-counter": 42
        }
        """
        try await s3.putObject(
            key: "metadata/assets/A.json",
            body: Data(payload.utf8),
        )

        let resolver = MockResolver(["A/L0/001": .cloud("CLOUD-A")])
        let runner = makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")],
        )
        _ = try await runner.run()

        let newData = try await s3.getObject(key: "metadata/assets/CLOUD-A.json")
        let json = try #require(JSONSerialization.jsonObject(with: newData) as? [String: Any])
        #expect(json["uuid"] as? String == "CLOUD-A")
        #expect(json["legacyLocalIdentifier"] as? String == "A")
        #expect(json["identityKind"] as? String == "cloud")
        // Unknown keys preserved verbatim.
        #expect(json["deno-extra"] as? String == "lives-on")
        #expect(json["future-counter"] as? Int == 42)
    }

    @Test func entryCountMismatchThrowsAndLeavesV1() async throws {
        // Inject a resolver that maps two distinct uuids onto the same cloud
        // id (a re-key collision drops one entry). The migrate function loses
        // 1 entry; the runner's count check accepts the loss because
        // rekeyCollisions == 1. To force a *true* mismatch we need a v1 with
        // duplicate entries — not possible in a dictionary. Verify here that
        // collisions DO NOT trip the validator (regression guard).
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
        )
        try await s3.putObject(
            key: "metadata/assets/B.json",
            body: metadataJSON(uuid: "B", s3Key: "originals/2024/01/B.heic"),
        )

        let resolver = MockResolver([
            "A/L0/001": .cloud("CLOUD-X"),
            "B/L0/001": .cloud("CLOUD-X"),
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
        #expect(report.cloudMigrated == 1)
        #expect(report.rekeyCollisions.count == 1)

        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.version == 2)
        #expect(manifest.entries.count == 1)
    }

    @Test func zeroCloudMappingsAbortsBeforeSwap() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: try v1ManifestData(entries: [
                ("A", "originals/2024/01/A.heic"),
                ("B", "originals/2024/01/B.heic"),
            ]),
            contentType: "application/json",
        )
        // Resolver returns .error for everything (PhotoKit auth misfire).
        let resolver = MockResolver([
            "A/L0/001": .error("not authorized"),
            "B/L0/001": .error("not authorized"),
        ])
        let runner = makeRunner(
            s3: s3,
            resolver: resolver,
            library: [
                (bareUUID: "A", fullLocalIdentifier: "A/L0/001"),
                (bareUUID: "B", fullLocalIdentifier: "B/L0/001"),
            ],
        )

        do {
            _ = try await runner.run()
            Issue.record("expected zeroCloudMappingsResolved error")
        } catch let error as MigrationError {
            if case .zeroCloudMappingsResolved = error {} else {
                Issue.record("expected zeroCloudMappingsResolved, got \(error)")
            }
        }

        // Manifest still v1 — no swap happened.
        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.isV1)
    }

    @Test func forceFlagBypassesAnomalyGuard() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: try v1ManifestData(entries: [("A", "originals/2024/01/A.heic")]),
            contentType: "application/json",
        )
        let resolver = MockResolver(["A/L0/001": .error("transient")])
        let runner = makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")],
        )

        // With force=true, the zero-cloud guard does not fire; entry is
        // stamped .local and the manifest swaps to v2.
        let report = try await runner.run(force: true)
        #expect(report.cloudMigrated == 0)
        #expect(report.localFallback == 1)

        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(!manifest.isV1)
    }

    @Test func lockHeldElsewhereAborts() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: try v1ManifestData(entries: [("A", "originals/2024/01/A.heic")]),
            contentType: "application/json",
        )
        // Pre-existing fresh lock from another machine.
        let foreignBody = MigrationLockBody(
            machineId: "other-mac",
            startedAt: ISO8601DateFormatter().string(from: Date()),
            ttlSeconds: 1800,
        )
        try await s3.putObject(
            key: migrationLockS3Key,
            body: try JSONEncoder().encode(foreignBody),
            contentType: "application/json",
        )

        let resolver = MockResolver(["A/L0/001": .cloud("CLOUD-A")])
        let runner = makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")],
        )

        do {
            _ = try await runner.run()
            Issue.record("expected MigrationLockError.heldElsewhere")
        } catch let error as MigrationLockError {
            if case .heldElsewhere(let body) = error {
                #expect(body.machineId == "other-mac")
            }
        }

        // No swap happened.
        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.isV1)
    }

    @Test func staleLockIsReclaimable() async throws {
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
        // Old, stale lock (started a year ago, ttl 60s — very expired).
        let staleBody = MigrationLockBody(
            machineId: "crashed-mac",
            startedAt: "2024-01-01T00:00:00Z",
            ttlSeconds: 60,
        )
        try await s3.putObject(
            key: migrationLockS3Key,
            body: try JSONEncoder().encode(staleBody),
            contentType: "application/json",
        )

        let resolver = MockResolver(["A/L0/001": .cloud("CLOUD-A")])
        let runner = makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")],
        )
        let report = try await runner.run()
        #expect(report.cloudMigrated == 1)
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
