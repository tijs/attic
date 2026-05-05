@testable import AtticCore
import Foundation
import LadderKit
import Testing

private typealias Support = MigrationRunnerTestSupport

/// Manifest store that throws on save — exercises the atomicity invariant
/// where the cleanup phase deletes succeed but the manifest save fails. The
/// flag must remain `false` so the next run resumes correctly.
private actor ManifestStoreSaveFails: ManifestStoring {
    private let backing: S3ManifestStore
    private var failNextSaves: Int

    init(s3: any S3Providing, failNextSaves: Int) {
        backing = S3ManifestStore(s3: s3)
        self.failNextSaves = failNextSaves
    }

    func load() async throws -> Manifest {
        try await backing.load()
    }

    func save(_ manifest: Manifest) async throws {
        if failNextSaves > 0 {
            failNextSaves -= 1
            throw NSError(domain: "TestSaveFailure", code: 1)
        }
        try await backing.save(manifest)
    }
}

/// `S3Providing` wrapper that injects a one-shot delete failure for a
/// configured key, then delegates back to the backing store.
private actor FlakyS3: S3Providing {
    private let backing: MockS3Provider
    private var failOnce: Set<String>

    init(backing: MockS3Provider, failOnce: Set<String>) {
        self.backing = backing
        self.failOnce = failOnce
    }

    func putObject(key: String, body: Data, contentType: String?) async throws {
        try await backing.putObject(key: key, body: body, contentType: contentType)
    }

    func putObject(key: String, fileURL: URL, contentType: String?) async throws {
        try await backing.putObject(key: key, fileURL: fileURL, contentType: contentType)
    }

    func getObject(key: String) async throws -> Data {
        try await backing.getObject(key: key)
    }

    func headObject(key: String) async throws -> S3ObjectMeta? {
        try await backing.headObject(key: key)
    }

    func listObjects(prefix: String) async throws -> [S3ListObject] {
        try await backing.listObjects(prefix: prefix)
    }

    nonisolated func presignedURL(key: String, expires: Int) -> URL {
        backing.presignedURL(key: key, expires: expires)
    }

    func deleteObject(key: String) async throws {
        if failOnce.remove(key) != nil {
            throw NSError(domain: "TestFlake", code: 1, userInfo: [NSLocalizedDescriptionKey: "flake on \(key)"])
        }
        try await backing.deleteObject(key: key)
    }
}

private actor PromptCounter {
    private(set) var calls: Int = 0
    func tick() { calls += 1 }
}

@Suite("MigrationRunner — thumbnail cleanup phase")
struct ThumbnailCleanupRunnerIntegrationTests {
    private func seedV2Manifest(_ s3: MockS3Provider, applied: Bool) async throws {
        let manifest = Manifest(
            version: 2,
            entries: [
                "CLOUD-A": ManifestEntry(
                    uuid: "CLOUD-A",
                    s3Key: "originals/2024/01/A.heic",
                    checksum: "sha256:a",
                    backedUpAt: "2024-01-01T00:00:00Z",
                    legacyLocalIdentifier: "A",
                    identityKind: .cloud,
                ),
            ],
            thumbnailsCleanupApplied: applied,
        )
        try await s3.putObject(
            key: manifestS3Key,
            body: manifest.encoded(),
            contentType: "application/json",
        )
    }

    private func seedThumbnails(_ s3: MockS3Provider, count: Int, bytesEach: Int) async throws {
        for i in 0 ..< count {
            try await s3.putObject(
                key: "thumbnails/asset-\(i).jpg",
                body: Data(repeating: 0x42, count: bytesEach),
                contentType: "image/jpeg",
            )
        }
    }

    private func makeV2Runner(s3: MockS3Provider, store: (any ManifestStoring)? = nil) -> MigrationRunner {
        MigrationRunner(
            s3: s3,
            manifestStore: store ?? S3ManifestStore(s3: s3),
            resolver: Support.MockResolver([:]),
            assetIdentifierProvider: { [] },
            retryStore: Support.InMemoryRetryStore(),
            unavailableStore: Support.InMemoryUnavailableStore(),
        )
    }

    @Test func deletesAndFlipsFlagOnHappyPath() async throws {
        let s3 = MockS3Provider()
        try await seedV2Manifest(s3, applied: false)
        try await seedThumbnails(s3, count: 3, bytesEach: 100)

        let runner = makeV2Runner(s3: s3)
        let report = try await runner.run(confirmCleanup: { _, _ in .proceed })

        #expect(report.thumbnailsDeleted == 3)
        #expect(report.thumbnailsBytes == 300)

        let remaining = try await s3.listObjects(prefix: "thumbnails/")
        #expect(remaining.isEmpty)

        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.thumbnailsCleanupApplied == true)
    }

    @Test func emptyPrefixSilentlyFlipsFlag() async throws {
        let s3 = MockS3Provider()
        try await seedV2Manifest(s3, applied: false)
        // No thumbnails seeded.

        let promptCalls = PromptCounter()
        let confirm: MigrationRunner.CleanupConfirmHandler = { _, _ in
            await promptCalls.tick()
            return .proceed
        }

        let runner = makeV2Runner(s3: s3)
        let report = try await runner.run(confirmCleanup: confirm)

        #expect(await promptCalls.calls == 0)
        #expect(report.thumbnailsDeleted == 0)

        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.thumbnailsCleanupApplied == true)
    }

    @Test func alreadyAppliedShortCircuitsToAlreadyMigrated() async throws {
        let s3 = MockS3Provider()
        try await seedV2Manifest(s3, applied: true)
        // Even if thumbnails exist, the runner shouldn't touch them when the
        // flag is set — the gate's fast-path normally prevents this case
        // from reaching the runner, but the runner is the safety net.
        try await seedThumbnails(s3, count: 2, bytesEach: 10)

        let runner = makeV2Runner(s3: s3)
        let report = try await runner.run(confirmCleanup: { _, _ in
            Issue.record("confirmCleanup must not be called when flag is true")
            return .abort
        })

        #expect(report.alreadyMigrated == true)
        #expect(report.thumbnailsDeleted == 0)

        let remaining = try await s3.listObjects(prefix: "thumbnails/")
        #expect(remaining.count == 2)
    }

    @Test func dryRunReportsWithoutDeletingOrFlippingFlag() async throws {
        let s3 = MockS3Provider()
        try await seedV2Manifest(s3, applied: false)
        try await seedThumbnails(s3, count: 3, bytesEach: 50)

        let runner = makeV2Runner(s3: s3)
        let report = try await runner.run(dryRun: true, confirmCleanup: { _, _ in .proceed })

        #expect(report.thumbnailsDeleted == 3)
        #expect(report.thumbnailsBytes == 150)

        let remaining = try await s3.listObjects(prefix: "thumbnails/")
        #expect(remaining.count == 3)

        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.thumbnailsCleanupApplied == false)
    }

    @Test func partialFailureLeavesFlagFalseAndThrows() async throws {
        let backing = MockS3Provider()
        try await seedV2Manifest(backing, applied: false)
        try await seedThumbnails(backing, count: 5, bytesEach: 10)
        let flaky = FlakyS3(backing: backing, failOnce: ["thumbnails/asset-2.jpg"])

        let runner = MigrationRunner(
            s3: flaky,
            manifestStore: S3ManifestStore(s3: flaky),
            resolver: Support.MockResolver([:]),
            assetIdentifierProvider: { [] },
            retryStore: Support.InMemoryRetryStore(),
            unavailableStore: Support.InMemoryUnavailableStore(),
        )

        await #expect(throws: MigrationRunnerError.self) {
            _ = try await runner.run(confirmCleanup: { _, _ in .proceed })
        }

        let manifest = try await S3ManifestStore(s3: backing).load()
        #expect(manifest.thumbnailsCleanupApplied == false)

        let remaining = try await backing.listObjects(prefix: "thumbnails/")
        #expect(remaining.map(\.key) == ["thumbnails/asset-2.jpg"])
    }

    @Test func reRunAfterPartialFailureCompletes() async throws {
        let backing = MockS3Provider()
        try await seedV2Manifest(backing, applied: false)
        try await seedThumbnails(backing, count: 3, bytesEach: 10)
        let flaky = FlakyS3(backing: backing, failOnce: ["thumbnails/asset-1.jpg"])

        let firstRunner = MigrationRunner(
            s3: flaky,
            manifestStore: S3ManifestStore(s3: flaky),
            resolver: Support.MockResolver([:]),
            assetIdentifierProvider: { [] },
            retryStore: Support.InMemoryRetryStore(),
            unavailableStore: Support.InMemoryUnavailableStore(),
        )
        await #expect(throws: MigrationRunnerError.self) {
            _ = try await firstRunner.run(confirmCleanup: { _, _ in .proceed })
        }

        // The runner releases its lock via an unstructured `defer { Task { ... } }`,
        // so the release may not have committed by the time the second run
        // tries to acquire. Drop the lock object directly to keep the test
        // deterministic — production code's TTL handles the equivalent case.
        try? await backing.deleteObject(key: migrationLockS3Key)

        // Second run goes straight at the backing — flake already drained.
        let secondRunner = makeV2Runner(s3: backing)
        let report = try await secondRunner.run(confirmCleanup: { _, _ in .proceed })

        #expect(report.thumbnailsDeleted == 1)

        let manifest = try await S3ManifestStore(s3: backing).load()
        #expect(manifest.thumbnailsCleanupApplied == true)
    }

    @Test func declinedThrowsAndLeavesFlagFalse() async throws {
        let s3 = MockS3Provider()
        try await seedV2Manifest(s3, applied: false)
        try await seedThumbnails(s3, count: 2, bytesEach: 5)

        let runner = makeV2Runner(s3: s3)
        do {
            _ = try await runner.run(confirmCleanup: { _, _ in .abort })
            Issue.record("expected throw")
        } catch MigrationRunnerError.thumbnailCleanupDeclined {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.thumbnailsCleanupApplied == false)
        let remaining = try await s3.listObjects(prefix: "thumbnails/")
        #expect(remaining.count == 2)
    }

    @Test func nonInteractiveSurfacesStructuredError() async throws {
        let s3 = MockS3Provider()
        try await seedV2Manifest(s3, applied: false)
        try await seedThumbnails(s3, count: 2, bytesEach: 5)

        let runner = makeV2Runner(s3: s3)
        do {
            _ = try await runner.run(confirmCleanup: { _, _ in .nonInteractive })
            Issue.record("expected throw")
        } catch let MigrationRunnerError.thumbnailCleanupNonInteractive(count, bytes) {
            #expect(count == 2)
            #expect(bytes == 10)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func atomicityFlagStaysFalseWhenSaveFails() async throws {
        let s3 = MockS3Provider()
        try await seedV2Manifest(s3, applied: false)
        try await seedThumbnails(s3, count: 3, bytesEach: 10)
        // Fail the post-cleanup save (the second save the runner performs:
        // load → set flag → save). The cleanup phase doesn't save during
        // listing/deleting, only at the end.
        let flakyStore = ManifestStoreSaveFails(s3: s3, failNextSaves: 1)
        let runner = MigrationRunner(
            s3: s3,
            manifestStore: flakyStore,
            resolver: Support.MockResolver([:]),
            assetIdentifierProvider: { [] },
            retryStore: Support.InMemoryRetryStore(),
            unavailableStore: Support.InMemoryUnavailableStore(),
        )
        await #expect(throws: NSError.self) {
            _ = try await runner.run(confirmCleanup: { _, _ in .proceed })
        }
        // Manifest on S3 still has flag false; deletes succeeded.
        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.thumbnailsCleanupApplied == false)
        let remaining = try await s3.listObjects(prefix: "thumbnails/")
        #expect(remaining.isEmpty)
    }

    @Test func v1ToV2ChainsIntoCleanupInOneInvocation() async throws {
        let s3 = MockS3Provider()
        // v1 manifest with one entry.
        try await s3.putObject(
            key: manifestS3Key,
            body: Support.v1ManifestData(entries: [("A", "originals/2024/01/A.heic")]),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/A.json",
            body: Support.metadataJSON(uuid: "A", s3Key: "originals/2024/01/A.heic"),
            contentType: "application/json",
        )
        // Plus a leftover thumbnail.
        try await s3.putObject(
            key: "thumbnails/asset-A.jpg",
            body: Data(repeating: 0x42, count: 50),
            contentType: "image/jpeg",
        )

        let resolver = Support.MockResolver(["A/L0/001": .cloud("CLOUD-A")])
        let runner = Support.makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")],
        )

        let report = try await runner.run(confirmCleanup: { _, _ in .proceed })

        #expect(report.cloudMigrated == 1)
        #expect(report.thumbnailsDeleted == 1)
        #expect(report.thumbnailsBytes == 50)

        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.version == 2)
        #expect(manifest.thumbnailsCleanupApplied == true)
        let thumbs = try await s3.listObjects(prefix: "thumbnails/")
        #expect(thumbs.isEmpty)
    }

    @Test func probeManifestSurfacesCleanupFlag() async throws {
        let s3 = MockS3Provider()
        try await seedV2Manifest(s3, applied: false)
        let runnerNotApplied = makeV2Runner(s3: s3)
        let probeNot = try await runnerNotApplied.probeManifest()
        #expect(probeNot.isV1 == false)
        #expect(probeNot.thumbnailsCleanupApplied == false)

        try await seedV2Manifest(s3, applied: true)
        let probeYes = try await runnerNotApplied.probeManifest()
        #expect(probeYes.thumbnailsCleanupApplied == true)
    }
}
