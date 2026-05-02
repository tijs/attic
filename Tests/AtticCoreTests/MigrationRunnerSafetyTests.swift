@testable import AtticCore
import Foundation
import LadderKit
import Testing

private typealias Support = MigrationRunnerTestSupport

@Suite("MigrationRunner — safety guards + collisions + lock")
struct MigrationRunnerSafetyTests {
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
            body: v1.encoded(),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/A.json",
            body: Support.metadataJSON(uuid: "A", s3Key: "originals/2024/01/A.heic"),
        )
        try await s3.putObject(
            key: "metadata/assets/B.json",
            body: Support.metadataJSON(uuid: "B", s3Key: "originals/2024/02/B.heic"),
        )

        let resolver = Support.MockResolver([
            "A/L0/001": .cloud("CLOUD-X"),
            "B/L0/001": .cloud("CLOUD-X"),
        ])
        let runner = Support.makeRunner(
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

        let aExists = try await s3.headObject(key: "metadata/assets/A.json") != nil
        #expect(!aExists)

        let cloudData = try await s3.getObject(key: "metadata/assets/CLOUD-X.json")
        let parsed = try JSONDecoder().decode(AssetMetadata.self, from: cloudData)
        #expect(parsed.uuid == "CLOUD-X")
        #expect(parsed.legacyLocalIdentifier == "B")
        #expect(parsed.s3Key == "originals/2024/02/B.heic")
        #expect(parsed.checksum == "sha256:B")
    }

    @Test func rewriteMetadataPayloadPreservesUnknownKeys() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: Support.v1ManifestData(entries: [("A", "originals/2024/01/A.heic")]),
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

        let resolver = Support.MockResolver(["A/L0/001": .cloud("CLOUD-A")])
        let runner = Support.makeRunner(
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
        #expect(json["deno-extra"] as? String == "lives-on")
        #expect(json["future-counter"] as? Int == 42)
    }

    @Test func collisionsAreAcceptedByEntryCountValidator() async throws {
        // Re-key collision drops one entry; v2.entries.count == v1 - collisions.
        // Validator must accept this loss (regression guard).
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: Support.v1ManifestData(entries: [
                ("A", "originals/2024/01/A.heic"),
                ("B", "originals/2024/01/B.heic"),
            ]),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/A.json",
            body: Support.metadataJSON(uuid: "A", s3Key: "originals/2024/01/A.heic"),
        )
        try await s3.putObject(
            key: "metadata/assets/B.json",
            body: Support.metadataJSON(uuid: "B", s3Key: "originals/2024/01/B.heic"),
        )

        let resolver = Support.MockResolver([
            "A/L0/001": .cloud("CLOUD-X"),
            "B/L0/001": .cloud("CLOUD-X"),
        ])
        let runner = Support.makeRunner(
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
            body: Support.v1ManifestData(entries: [
                ("A", "originals/2024/01/A.heic"),
                ("B", "originals/2024/01/B.heic"),
            ]),
            contentType: "application/json",
        )
        let resolver = Support.MockResolver([
            "A/L0/001": .error("not authorized"),
            "B/L0/001": .error("not authorized"),
        ])
        let runner = Support.makeRunner(
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

        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.isV1)
    }

    @Test func forceFlagBypassesAnomalyGuard() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: Support.v1ManifestData(entries: [("A", "originals/2024/01/A.heic")]),
            contentType: "application/json",
        )
        let resolver = Support.MockResolver(["A/L0/001": .error("transient")])
        let runner = Support.makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")],
        )

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
            body: Support.v1ManifestData(entries: [("A", "originals/2024/01/A.heic")]),
            contentType: "application/json",
        )
        let foreignBody = MigrationLockBody(
            machineId: "other-mac",
            startedAt: ISO8601DateFormatter().string(from: Date()),
            ttlSeconds: 1800,
        )
        try await s3.putObject(
            key: migrationLockS3Key,
            body: JSONEncoder().encode(foreignBody),
            contentType: "application/json",
        )

        let resolver = Support.MockResolver(["A/L0/001": .cloud("CLOUD-A")])
        let runner = Support.makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")],
        )

        do {
            _ = try await runner.run()
            Issue.record("expected MigrationLockError.heldElsewhere")
        } catch let error as MigrationLockError {
            if case let .heldElsewhere(body) = error {
                #expect(body.machineId == "other-mac")
            }
        }

        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.isV1)
    }

    @Test func staleLockIsReclaimable() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: Support.v1ManifestData(entries: [("A", "originals/2024/01/A.heic")]),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/A.json",
            body: Support.metadataJSON(uuid: "A", s3Key: "originals/2024/01/A.heic"),
        )
        let staleBody = MigrationLockBody(
            machineId: "crashed-mac",
            startedAt: "2024-01-01T00:00:00Z",
            ttlSeconds: 60,
        )
        try await s3.putObject(
            key: migrationLockS3Key,
            body: JSONEncoder().encode(staleBody),
            contentType: "application/json",
        )

        let resolver = Support.MockResolver(["A/L0/001": .cloud("CLOUD-A")])
        let runner = Support.makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")],
        )
        let report = try await runner.run()
        #expect(report.cloudMigrated == 1)
    }
}
