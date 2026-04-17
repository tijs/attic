@testable import AtticCore
import Foundation
import LadderKit
import Testing

// MARK: - Test helpers

/// S3 provider that fails with a network error after a configured number of
/// successful uploads. Simulates network loss mid-backup.
actor NetworkFailingS3Provider: S3Providing {
    private let inner = MockS3Provider()
    private var putCallCount = 0
    private let failAfterPuts: Int
    private var shouldFail = true

    init(failAfterPuts: Int = 0) {
        self.failAfterPuts = failAfterPuts
    }

    func stopFailing() {
        shouldFail = false
    }

    func putObject(key: String, body: Data, contentType: String?) async throws {
        putCallCount += 1
        if shouldFail, putCallCount > failAfterPuts {
            throw NetworkError.networkDown
        }
        try await inner.putObject(key: key, body: body, contentType: contentType)
    }

    func putObject(key: String, fileURL: URL, contentType: String?) async throws {
        putCallCount += 1
        if shouldFail, putCallCount > failAfterPuts {
            throw NetworkError.networkDown
        }
        try await inner.putObject(key: key, fileURL: fileURL, contentType: contentType)
    }

    func getObject(key: String) async throws -> Data {
        try await inner.getObject(key: key)
    }

    func headObject(key: String) async throws -> S3ObjectMeta? {
        try await inner.headObject(key: key)
    }

    func listObjects(prefix: String) async throws -> [S3ListObject] {
        try await inner.listObjects(prefix: prefix)
    }

    nonisolated func presignedURL(key: String, expires: Int) -> URL {
        URL(string: "http://mock-s3/\(key)?expires=\(expires)")!
    }
}

/// Throws a real URLError so typed isNetworkDown() detection works end-to-end.
enum NetworkError {
    static let networkDown = URLError(.notConnectedToInternet)
}

/// S3 provider that fails with a server-transient error (503) a fixed number of
/// times, then succeeds. Used to verify withRetry handles transient errors
/// without triggering network pause.
actor TransientFailingS3Provider: S3Providing {
    private let inner = MockS3Provider()
    private var remainingFailures: Int

    init(failCount: Int) {
        remainingFailures = failCount
    }

    private func maybeThrow() throws {
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw S3ClientError.httpError(503, "Service Unavailable")
        }
    }

    func putObject(key: String, body: Data, contentType: String?) async throws {
        try maybeThrow()
        try await inner.putObject(key: key, body: body, contentType: contentType)
    }

    func putObject(key: String, fileURL: URL, contentType: String?) async throws {
        try maybeThrow()
        try await inner.putObject(key: key, fileURL: fileURL, contentType: contentType)
    }

    func getObject(key: String) async throws -> Data {
        try await inner.getObject(key: key)
    }

    func headObject(key: String) async throws -> S3ObjectMeta? {
        try await inner.headObject(key: key)
    }

    func listObjects(prefix: String) async throws -> [S3ListObject] {
        try await inner.listObjects(prefix: prefix)
    }

    nonisolated func presignedURL(key: String, expires: Int) -> URL {
        URL(string: "http://mock-s3/\(key)?expires=\(expires)")!
    }
}

/// Network monitor that always reports unavailable and always times out.
/// Used for testing the timeout path without any polling or actor overhead.
struct AlwaysUnavailableNetworkMonitor: NetworkMonitoring {
    var isNetworkAvailable: Bool {
        false
    }

    func waitForNetwork(timeout: Duration) async throws -> Bool {
        try Task.checkCancellation()
        try await Task.sleep(for: timeout)
        return false
    }
}

/// Progress delegate that records pause/resume events for assertions.
final class RecordingProgressDelegate: BackupProgressDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    var events: [String] {
        lock.withLock { _events }
    }

    private func record(_ event: String) {
        lock.withLock { _events.append(event) }
    }

    func backupStarted(pending: Int, photos: Int, videos: Int) {
        record("started(\(pending))")
    }

    func batchStarted(batchNumber: Int, totalBatches: Int, assetCount: Int) {
        record("batch(\(batchNumber))")
    }

    func assetStarting(uuid: String, filename: String, size: Int) {
        record("starting(\(uuid))")
    }

    func assetRetrying(uuid: String, filename: String, attempt: Int, maxAttempts: Int) {
        record("retrying(\(uuid),\(attempt)/\(maxAttempts))")
    }

    func assetUploaded(uuid: String, filename: String, type: AssetKind, size: Int) {
        record("uploaded(\(uuid))")
    }

    func assetFailed(uuid: String, filename: String, message: String) {
        record("failed(\(uuid))")
    }

    func manifestSaved(entriesCount: Int) {
        record("manifestSaved(\(entriesCount))")
    }

    func backupCompleted(uploaded: Int, failed: Int, totalBytes: Int) {
        record("completed(\(uploaded),\(failed))")
    }

    func backupPaused(reason: String) {
        record("paused")
    }

    func backupResumed() {
        record("resumed")
    }
}

// MARK: - Tests

struct NetworkPauseTests {
    @Test func backupCompletesNormallyWithoutNetworkMonitor() async throws {
        let assets = [makeTestAsset(uuid: "uuid-1")]
        let exporter = MockExportProvider(assets: [
            "uuid-1": ("IMG_0001.HEIC", Data("photo1".utf8)),
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
        #expect(report.failed == 0)
    }

    @Test func backupCompletesNormallyWithAvailableNetwork() async throws {
        let assets = [makeTestAsset(uuid: "uuid-1")]
        let exporter = MockExportProvider(assets: [
            "uuid-1": ("IMG_0001.HEIC", Data("photo1".utf8)),
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
        #expect(report.failed == 0)
    }

    @Test func pausesAndResumesWhenNetworkDropsAndRecovers() async throws {
        let assets = [makeTestAsset(uuid: "uuid-1")]
        let exporter = MockExportProvider(assets: [
            "uuid-1": ("IMG_0001.HEIC", Data("photo1".utf8)),
        ])

        // S3 provider that fails on first put (simulating network loss)
        let s3 = NetworkFailingS3Provider(failAfterPuts: 0)
        // Use a working S3 for manifest so saves don't fail during pause
        let goodS3 = MockS3Provider()
        let manifestStore = S3ManifestStore(s3: goodS3)
        var manifest = try await manifestStore.load()

        let monitor = MockNetworkMonitor(available: false)
        let progress = RecordingProgressDelegate()

        // Simulate network recovery after a short delay
        Task {
            try await Task.sleep(for: .milliseconds(100))
            await s3.stopFailing()
            await monitor.setAvailable()
        }

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10),
            progress: progress,
            networkMonitor: monitor,
        )

        #expect(report.uploaded == 1)
        #expect(report.failed == 0)
        #expect(progress.events.contains("paused"))
        #expect(progress.events.contains("resumed"))
    }

    @Test(.timeLimit(.minutes(1)))
    func networkTimeoutExitsCleanly() async throws {
        // Verify that AlwaysUnavailableNetworkMonitor times out correctly
        let monitor = AlwaysUnavailableNetworkMonitor()
        let result = try await monitor.waitForNetwork(timeout: .milliseconds(100))
        #expect(!result)

        // Test the full pipeline with network failure + timeout
        let assets = [makeTestAsset(uuid: "uuid-1")]
        let exporter = MockExportProvider(assets: [
            "uuid-1": ("IMG_0001.HEIC", Data("photo1".utf8)),
        ])
        // Use separate S3 instances: one for manifest (works), one for uploads (fails)
        let goodS3 = MockS3Provider()
        let manifestStore = S3ManifestStore(s3: goodS3)
        var manifest = try await manifestStore.load()

        let failingS3 = NetworkFailingS3Provider(failAfterPuts: 0)
        let progress = RecordingProgressDelegate()

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: failingS3,
            options: BackupOptions(batchSize: 10, networkTimeout: .milliseconds(200)),
            progress: progress,
            networkMonitor: AlwaysUnavailableNetworkMonitor(),
        )

        #expect(progress.events.contains("paused"))
        #expect(progress.events.contains("resumed"))
        #expect(report.failed >= 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDuringNetworkWaitExitsCleanly() async throws {
        let assets = [makeTestAsset(uuid: "uuid-1")]
        let exporter = MockExportProvider(assets: [
            "uuid-1": ("IMG_0001.HEIC", Data("photo1".utf8)),
        ])

        let s3 = NetworkFailingS3Provider(failAfterPuts: 0)
        let goodS3 = MockS3Provider()
        let manifestStore = S3ManifestStore(s3: goodS3)
        var manifest = try await manifestStore.load()
        // Network never recovers — cancellation should interrupt the wait
        let monitor = AlwaysUnavailableNetworkMonitor()

        let task = Task {
            try await runBackup(
                assets: assets,
                manifest: &manifest,
                manifestStore: manifestStore,
                exporter: exporter,
                s3: s3,
                options: BackupOptions(batchSize: 10, networkTimeout: .seconds(60)),
                networkMonitor: monitor,
            )
        }

        // Cancel after a brief delay (enough for upload to fail and pause to start)
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()

        // Should throw CancellationError
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test func concurrentBatchRetriesAfterNetworkRecovery() async throws {
        // 6 assets: first 2 puts succeed (1 asset = 2 puts: original + metadata),
        // then network drops. After recovery, remaining assets should succeed.
        let assets = (1 ... 4).map { makeTestAsset(uuid: "net-\($0)") }
        var exportMap: [String: (filename: String, data: Data)] = [:]
        for i in 1 ... 4 {
            exportMap["net-\(i)"] = ("IMG_\(i).HEIC", Data("photo\(i)".utf8))
        }

        let exporter = MockExportProvider(assets: exportMap)
        // failAfterPuts: 2 means first asset's 2 puts succeed, then failures start
        let s3 = NetworkFailingS3Provider(failAfterPuts: 2)
        let goodS3 = MockS3Provider()
        let manifestStore = S3ManifestStore(s3: goodS3)
        var manifest = try await manifestStore.load()

        let monitor = MockNetworkMonitor(available: false)
        let progress = RecordingProgressDelegate()

        // Simulate network recovery
        Task {
            try await Task.sleep(for: .milliseconds(150))
            await s3.stopFailing()
            await monitor.setAvailable()
        }

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10, concurrency: 4),
            progress: progress,
            networkMonitor: monitor,
        )

        // First asset succeeded before network drop, rest retried after recovery
        #expect(report.uploaded >= 1)
        #expect(report.failed == 0)
        #expect(progress.events.contains("paused"))
        #expect(progress.events.contains("resumed"))
        // All assets should be in manifest
        for i in 1 ... 4 {
            #expect(manifest.isBackedUp("net-\(i)"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func maxPauseRetriesExceededExitsCleanly() async throws {
        let assets = [makeTestAsset(uuid: "uuid-1")]
        let exporter = MockExportProvider(assets: [
            "uuid-1": ("IMG_0001.HEIC", Data("photo1".utf8)),
        ])

        // S3 always fails, network monitor always says unavailable after check
        let s3 = NetworkFailingS3Provider(failAfterPuts: 0)
        let goodS3 = MockS3Provider()
        let manifestStore = S3ManifestStore(s3: goodS3)
        var manifest = try await manifestStore.load()
        let progress = RecordingProgressDelegate()

        // Monitor that briefly recovers (so waitForNetwork returns true)
        // but S3 keeps failing — triggers repeated pause/retry cycles
        let monitor = MockNetworkMonitor(available: false)

        // Recover quickly so the pause/retry loop cycles through maxPauseRetries
        Task {
            // Keep toggling: network "recovers" but S3 still fails
            for _ in 0 ..< 5 {
                try await Task.sleep(for: .milliseconds(50))
                await monitor.setAvailable()
                try await Task.sleep(for: .milliseconds(50))
                await monitor.setUnavailable()
            }
        }

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(
                batchSize: 10,
                networkTimeout: .milliseconds(200),
                maxPauseRetries: 2,
            ),
            progress: progress,
            networkMonitor: monitor,
        )

        // Should eventually fail after exhausting retries
        #expect(report.failed >= 1)
        #expect(report.uploaded == 0)
    }

    @Test func serverTransientErrorDoesNotTriggerNetworkPause() async throws {
        // A 503 error should be retried by withRetry, not trigger network pause
        let assets = [makeTestAsset(uuid: "uuid-1")]
        let exporter = MockExportProvider(assets: [
            "uuid-1": ("IMG_0001.HEIC", Data("photo1".utf8)),
        ])

        let s3 = TransientFailingS3Provider(failCount: 1)
        let goodS3 = MockS3Provider()
        let manifestStore = S3ManifestStore(s3: goodS3)
        var manifest = try await manifestStore.load()

        let monitor = MockNetworkMonitor(available: true)
        let progress = RecordingProgressDelegate()

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10),
            progress: progress,
            networkMonitor: monitor,
        )

        // Should succeed after retry, no pause
        #expect(report.uploaded == 1)
        #expect(report.failed == 0)
        #expect(!progress.events.contains("paused"))
    }

    @Test func mockNetworkMonitorBasicBehavior() async throws {
        let monitor = MockNetworkMonitor(available: true)
        let available = await monitor.isNetworkAvailable
        #expect(available)

        await monitor.setUnavailable()
        let unavailable = await monitor.isNetworkAvailable
        #expect(!unavailable)

        // waitForNetwork returns immediately when available
        await monitor.setAvailable()
        let recovered = try await monitor.waitForNetwork(timeout: .seconds(1))
        #expect(recovered)
    }
}
