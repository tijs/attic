import ArgumentParser
@testable import AtticCLI
@testable import AtticCore
import Foundation
import LadderKit
import Testing

private typealias Support = MigrationRunnerTestSupport

/// Collects emitted output under a lock so `@Sendable` sinks can append
/// from the guard's closures.
private final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ s: String) {
        lock.lock()
        buffer += s
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// Coverage of `MigrationGuard` — the injectable migration gate behind
/// `Dependencies.ensureManifestMigrated` — with mock S3, resolver, and
/// output sinks in place of the real terminal.
struct MigrationGuardTests {
    private func seedV1Bucket() async throws -> MockS3Provider {
        let s3 = MockS3Provider()
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
        return s3
    }

    private func makeGuard(
        s3: MockS3Provider,
        prompts: OutputSink,
        status: OutputSink,
        isTTY: Bool = true,
        answer: String? = "y",
    ) -> MigrationGuard {
        MigrationGuard(
            loadManifest: { try await S3ManifestStore(s3: s3).load() },
            makeRunner: { progress in
                MigrationRunner(
                    s3: s3,
                    manifestStore: S3ManifestStore(s3: s3),
                    resolver: Support.MockResolver(["A/L0/001": .cloud("CLOUD-A")]),
                    assetIdentifierProvider: { [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")] },
                    retryStore: Support.InMemoryRetryStore(),
                    unavailableStore: Support.InMemoryUnavailableStore(),
                    progress: progress,
                )
            },
            isTTY: isTTY,
            readAnswer: { answer },
            emitPrompt: { prompts.append($0) },
            emitStatus: { status.append($0 + "\n") },
        )
    }

    @Test func migrationNeededStatusJSONKeepsStdoutParseable() async throws {
        // Simulate `attic status --json` against a v1 bucket: the guard
        // runs the migration with progress routed to the status sink
        // (stderr in JSON mode), and stdout receives only the JSON
        // document. This is the regression test for human text polluting
        // stdout ahead of the JSON object.
        let s3 = try await seedV1Bucket()
        let prompts = OutputSink()
        let status = OutputSink()
        let stdout = OutputSink()

        let migrationGuard = makeGuard(s3: s3, prompts: prompts, status: status)
        let data = try await StatusCommand.buildDashboard(
            ensureMigrated: { try await migrationGuard.ensureMigrated() },
            loadAssets: { [makeTestAsset(uuid: "A")] },
            loadLocalAvailability: { nil },
            loadRetryQueue: { nil },
            loadBackupContext: { try await ("bucket", S3ManifestStore(s3: s3).load()) },
        )
        let document = try #require(String(data: formatDashboardJSON(data), encoding: .utf8))
        stdout.append(document + "\n")

        // Migration actually ran, and its human output stayed off stdout.
        #expect(status.text.contains("Migration complete: 1 cloud, 0 local fallback."))
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(stdout.text.utf8)) as? [String: Any],
        )
        #expect((parsed["s3"] as? [String: Any])?["manifestEntries"] as? Int == 1)

        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.version == 2)
    }

    @Test func backupJSONMigratesThenBacksUpWithoutHumanTextOnStdout() async throws {
        let s3 = try await seedV1Bucket()
        let stderr = OutputSink()
        let stdout = OutputSink()
        let progress = BackupJSONProgressDelegate(output: { stdout.append($0 + "\n") })
        let migrationGuard = makeGuard(s3: s3, prompts: stderr, status: stderr)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }

        try await BackupCommand.performBackup(
            dryRun: false,
            jsonProgress: progress,
            execute: {
                try await migrationGuard.ensureMigrated()
                let store = S3ManifestStore(s3: s3)
                var manifest = try await store.load()
                return try await runBackup(
                    assets: [makeTestAsset(uuid: "B")],
                    manifest: &manifest,
                    manifestStore: store,
                    exporter: MockExportProvider(
                        assets: ["B": (filename: "private.heic", data: Data("original".utf8))],
                        stagingDir: staging,
                    ),
                    s3: s3,
                    progress: progress,
                )
            },
            successHook: { _ in stderr.append("success hook\n") },
            failureHook: { _ in stderr.append("failure hook\n") },
        )

        let events = try stdout.text.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(events.filter { $0["event"] as? String == "completed" }.count == 1)
        let final = try #require(events.last)
        let counts = try #require(final["counts"] as? [String: Any])
        #expect(counts["uploaded"] as? Int == 1)
        #expect(counts["failed"] as? Int == 0)
        #expect((final["bytes"] as? [String: Any])?["uploaded"] as? Int == 8)
        #expect((final["final"] as? [String: Any])?["exit_classification"] as? String == "success")
        #expect(!stdout.text.contains("\u{1B}"))
        #expect(!stdout.text.contains("Migration"))
        #expect(!stdout.text.contains("private.heic"))
        #expect(stderr.text.contains("Migration complete: 1 cloud, 0 local fallback."))
        #expect(stderr.text.contains("success hook"))
        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.version == 2)
        #expect(manifest.entries["CLOUD-A"] != nil)
        #expect(manifest.entries["B"] != nil)
    }

    @Test func backupJSONNonInteractiveMigrationEmitsOneFatalEventAndPreservesV1() async throws {
        let s3 = try await seedV1Bucket()
        let stderr = OutputSink()
        let stdout = OutputSink()
        let progress = BackupJSONProgressDelegate(output: { stdout.append($0 + "\n") })
        let migrationGuard = makeGuard(s3: s3, prompts: stderr, status: stderr, isTTY: false)
        await #expect(throws: CLIError.self) {
            try await BackupCommand.performBackup(
                dryRun: false,
                jsonProgress: progress,
                execute: {
                    try await migrationGuard.ensureMigrated()
                    return BackupReport()
                },
                successHook: { _ in stderr.append("unexpected success") },
                failureHook: { _ in stderr.append("failure hook") },
            )
        }
        let lines = stdout.text.split(separator: "\n")
        #expect(lines.count == 1)
        let event = try #require(JSONSerialization.jsonObject(with: Data(stdout.text.utf8)) as? [String: Any])
        #expect(event["event"] as? String == "completed")
        #expect((event["final"] as? [String: Any])?["exit_classification"] as? String == "fatal_failure")
        #expect(stderr.text.contains(MigrationPrompt.nonInteractiveHint))
        #expect(stderr.text.contains("failure hook"))
        #expect(try await S3ManifestStore(s3: s3).load().version == 1)
    }

    @Test func alreadyMigratedBucketEmitsNothing() async throws {
        let s3 = MockS3Provider()
        let manifest = Manifest(version: 2, entries: [:], thumbnailsCleanupApplied: true)
        try await s3.putObject(
            key: manifestS3Key,
            body: manifest.encoded(),
            contentType: "application/json",
        )
        let prompts = OutputSink()
        let status = OutputSink()

        try await makeGuard(s3: s3, prompts: prompts, status: status).ensureMigrated()

        #expect(prompts.text.isEmpty)
        #expect(status.text.isEmpty)
    }

    @Test func nonInteractiveV1BucketFailsWithHint() async throws {
        let s3 = try await seedV1Bucket()
        let prompts = OutputSink()
        let status = OutputSink()

        await #expect(throws: CLIError.self) {
            try await makeGuard(s3: s3, prompts: prompts, status: status, isTTY: false, answer: nil)
                .ensureMigrated()
        }
        #expect(prompts.text.contains(MigrationPrompt.nonInteractiveHint))
        #expect(status.text.isEmpty)
    }
}
